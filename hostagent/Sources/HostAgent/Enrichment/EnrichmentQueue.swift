import Foundation
import HavenCore

/// Queue for asynchronous enrichment of collector documents.
/// All documents pass through this queue so that enrichment order is preserved
/// and concurrency is controlled centrally.
/// Supports two worker types:
/// - Normal workers: Can process any document (with or without attachments)
/// - No-attachment worker: Only processes documents without attachments
public actor EnrichmentQueue {
    private let orchestrator: EnrichmentOrchestrator
    private let logger = HavenLogger(category: "enrichment-queue")
    private var enrichmentTasks: [String: Task<EnrichedDocument?, Error>] = [:]
    private var workerTypes: [String: WorkerType] = [:] // Track which worker type is processing each document
    private var maxNormalEnrichments: Int
    private var activeNormalEnrichmentCount: Int = 0
    private var activeNoAttachmentEnrichmentCount: Int = 0
    private var hasNoAttachmentWorker: Bool
    private var waitingQueue: [(documentId: String, document: CollectorDocument, onComplete: EnrichmentCompletion)] = []
    
    /// Worker type for tracking which pool processes a document
    private enum WorkerType {
        case normal
        case noAttachment
    }
    
    /// Callback type for when enrichment completes
    public typealias EnrichmentCompletion = (String, EnrichedDocument?) -> Void
    
    public init(orchestrator: EnrichmentOrchestrator, maxNormalEnrichments: Int = 1, enableNoAttachmentWorker: Bool = true) {
        self.orchestrator = orchestrator
        self.maxNormalEnrichments = maxNormalEnrichments
        self.hasNoAttachmentWorker = enableNoAttachmentWorker
    }
    
    /// Queue a document for enrichment
    /// - Parameters:
    ///   - document: The document to enrich
    ///   - documentId: Unique identifier for this document
    ///   - onComplete: Callback invoked when enrichment completes (may be called from any context)
    /// - Returns: True if queued, false if already queued
    @discardableResult
    public func queueForEnrichment(
        document: CollectorDocument,
        documentId: String,
        onComplete: @escaping EnrichmentCompletion
    ) -> Bool {
        // Check if already queued or waiting
        guard enrichmentTasks[documentId] == nil,
              !waitingQueue.contains(where: { $0.documentId == documentId }) else {
            logger.debug("Document already queued for enrichment", metadata: ["document_id": documentId])
            return false
        }
        
        let hasAttachments = !document.images.isEmpty
        
        // Try to assign to appropriate worker pool
        if hasAttachments {
            // Documents with attachments can only use normal workers
            if activeNormalEnrichmentCount < maxNormalEnrichments {
                return startEnrichment(document: document, documentId: documentId, workerType: .normal, onComplete: onComplete)
            }
        } else {
            // Documents without attachments can use either worker type
            // Prefer no-attachment worker if available, otherwise use normal worker
            if hasNoAttachmentWorker && activeNoAttachmentEnrichmentCount < 1 {
                return startEnrichment(document: document, documentId: documentId, workerType: .noAttachment, onComplete: onComplete)
            } else if activeNormalEnrichmentCount < maxNormalEnrichments {
                return startEnrichment(document: document, documentId: documentId, workerType: .normal, onComplete: onComplete)
            }
        }
        
        // No capacity available, add to waiting queue
        waitingQueue.append((documentId: documentId, document: document, onComplete: onComplete))
        logger.debug("Queued document for later enrichment (at capacity)", metadata: [
            "document_id": documentId,
            "image_count": String(document.images.count),
            "has_attachments": String(hasAttachments),
            "active_normal_count": String(activeNormalEnrichmentCount),
            "active_no_attachment_count": String(activeNoAttachmentEnrichmentCount),
            "waiting_count": String(waitingQueue.count)
        ])
        return true
    }
    
    /// Start enrichment for a document
    private func startEnrichment(
        document: CollectorDocument,
        documentId: String,
        workerType: WorkerType,
        onComplete: @escaping EnrichmentCompletion
    ) -> Bool {
        // Create enrichment task
        let task = Task<EnrichedDocument?, Error> {
            do {
                let enriched = try await self.orchestrator.enrich(document)
                return enriched
            } catch {
                logger.warning("Enrichment failed", metadata: [
                    "document_id": documentId,
                    "worker_type": workerType == .normal ? "normal" : "no_attachment",
                    "error": error.localizedDescription
                ])
                throw error
            }
        }
        
        enrichmentTasks[documentId] = task
        workerTypes[documentId] = workerType
        
        // Update appropriate counter
        switch workerType {
        case .normal:
            activeNormalEnrichmentCount += 1
        case .noAttachment:
            activeNoAttachmentEnrichmentCount += 1
        }
        
        logger.debug("Started document enrichment", metadata: [
            "document_id": documentId,
            "image_count": String(document.images.count),
            "worker_type": workerType == .normal ? "normal" : "no_attachment",
            "active_normal_count": String(activeNormalEnrichmentCount),
            "active_no_attachment_count": String(activeNoAttachmentEnrichmentCount)
        ])
        
        // Process enrichment asynchronously
        Task {
            do {
                let enriched = try await task.value
                // Remove from active tasks
                await self.completeEnrichment(documentId: documentId, result: enriched)
                // Call completion callback
                onComplete(documentId, enriched)
            } catch {
                // Remove from active tasks
                await self.completeEnrichment(documentId: documentId, result: nil)
                // Call completion with nil to indicate failure
                onComplete(documentId, nil)
            }
        }
        
        return true
    }
    
    /// Mark enrichment as complete and process next waiting item
    private func completeEnrichment(documentId: String, result: EnrichedDocument?) {
        // Get the worker type that was processing this document
        let workerType = workerTypes[documentId]
        removeTask(documentId: documentId)
        workerTypes.removeValue(forKey: documentId)
        
        // Decrement appropriate counter
        if let workerType = workerType {
            switch workerType {
            case .normal:
                activeNormalEnrichmentCount -= 1
            case .noAttachment:
                activeNoAttachmentEnrichmentCount -= 1
            }
        }
        
        // Process next waiting item(s) if available
        // First, try to fill the worker that just became available
        if let workerType = workerType {
            processWaitingQueue(for: workerType)
        }
        
        // Also check if other workers can process waiting documents
        // This ensures we utilize all available capacity
        if activeNormalEnrichmentCount < maxNormalEnrichments {
            processWaitingQueue(for: .normal)
        }
        if hasNoAttachmentWorker && activeNoAttachmentEnrichmentCount < 1 {
            processWaitingQueue(for: .noAttachment)
        }
    }
    
    /// Process waiting queue for a specific worker type
    private func processWaitingQueue(for workerType: WorkerType) {
        switch workerType {
        case .normal:
            // Normal workers can process any document
            if let index = waitingQueue.firstIndex(where: { _ in true }) {
                let next = waitingQueue.remove(at: index)
                logger.debug("Processing next document from waiting queue (normal worker)", metadata: [
                    "document_id": next.documentId,
                    "remaining_in_queue": String(waitingQueue.count)
                ])
                _ = startEnrichment(document: next.document, documentId: next.documentId, workerType: .normal, onComplete: next.onComplete)
            }
        case .noAttachment:
            // No-attachment worker only processes documents without attachments
            if let index = waitingQueue.firstIndex(where: { $0.document.images.isEmpty }) {
                let next = waitingQueue.remove(at: index)
                logger.debug("Processing next document from waiting queue (no-attachment worker)", metadata: [
                    "document_id": next.documentId,
                    "remaining_in_queue": String(waitingQueue.count)
                ])
                _ = startEnrichment(document: next.document, documentId: next.documentId, workerType: .noAttachment, onComplete: next.onComplete)
            }
        }
    }
    
    /// Wait for enrichment to complete (for testing or synchronous scenarios)
    public func waitForEnrichment(documentId: String) async throws -> EnrichedDocument? {
        guard let task = enrichmentTasks[documentId] else {
            return nil
        }
        return try await task.value
    }

    /// Queue a document and suspend until enrichment completes
    public func enqueueAndWait(document: CollectorDocument, documentId: String) async -> EnrichedDocument? {
        await withCheckedContinuation { continuation in
            let queued = queueForEnrichment(document: document, documentId: documentId) { _, enriched in
                continuation.resume(returning: enriched)
            }
            if !queued {
                continuation.resume(returning: nil)
            }
        }
    }
    
    /// Cancel enrichment for a document
    public func cancelEnrichment(documentId: String) {
        enrichmentTasks[documentId]?.cancel()
        enrichmentTasks.removeValue(forKey: documentId)
        workerTypes.removeValue(forKey: documentId)
    }
    
    /// Cancel all pending enrichments
    public func cancelAll() {
        for (_, task) in enrichmentTasks {
            task.cancel()
        }
        enrichmentTasks.removeAll()
        workerTypes.removeAll()
        activeNormalEnrichmentCount = 0
        activeNoAttachmentEnrichmentCount = 0
    }
    
    /// Get count of pending enrichments
    public func pendingCount() -> Int {
        return enrichmentTasks.count
    }
    
    private func removeTask(documentId: String) {
        enrichmentTasks.removeValue(forKey: documentId)
    }
}
