import Foundation
import HavenCore

/// Queue for asynchronous enrichment of collector documents.
/// All documents pass through this queue so that enrichment order is preserved
/// and concurrency is controlled centrally.
public actor EnrichmentQueue {
    private let orchestrator: EnrichmentOrchestrator
    private let logger = HavenLogger(category: "enrichment-queue")
    private var enrichmentTasks: [String: Task<EnrichedDocument?, Error>] = [:]
    private var maxConcurrentEnrichments: Int
    private var activeEnrichmentCount: Int = 0
    private var waitingQueue: [(documentId: String, document: CollectorDocument, onComplete: EnrichmentCompletion)] = []
    
    /// Callback type for when enrichment completes
    public typealias EnrichmentCompletion = (String, EnrichedDocument?) -> Void
    
    public init(orchestrator: EnrichmentOrchestrator, maxConcurrentEnrichments: Int = 1) {
        self.orchestrator = orchestrator
        self.maxConcurrentEnrichments = maxConcurrentEnrichments
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
        
        // If we have capacity, process immediately; otherwise, add to waiting queue
        if activeEnrichmentCount < maxConcurrentEnrichments {
            return startEnrichment(document: document, documentId: documentId, onComplete: onComplete)
        } else {
            // Queue for later processing
            waitingQueue.append((documentId: documentId, document: document, onComplete: onComplete))
            logger.debug("Queued document for later enrichment (at capacity)", metadata: [
                "document_id": documentId,
                "image_count": String(document.images.count),
                "active_count": String(activeEnrichmentCount),
                "waiting_count": String(waitingQueue.count)
            ])
            return true
        }
    }
    
    /// Start enrichment for a document
    private func startEnrichment(
        document: CollectorDocument,
        documentId: String,
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
                    "error": error.localizedDescription
                ])
                throw error
            }
        }
        
        enrichmentTasks[documentId] = task
        activeEnrichmentCount += 1
        
        logger.debug("Started document enrichment", metadata: [
            "document_id": documentId,
            "image_count": String(document.images.count),
            "active_count": String(activeEnrichmentCount)
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
        removeTask(documentId: documentId)
        activeEnrichmentCount -= 1
        
        // Process next waiting item if available
        if !waitingQueue.isEmpty {
            let next = waitingQueue.removeFirst()
            logger.debug("Processing next document from waiting queue", metadata: [
                "document_id": next.documentId,
                "remaining_in_queue": String(waitingQueue.count)
            ])
            _ = startEnrichment(document: next.document, documentId: next.documentId, onComplete: next.onComplete)
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
    }
    
    /// Cancel all pending enrichments
    public func cancelAll() {
        for (_, task) in enrichmentTasks {
            task.cancel()
        }
        enrichmentTasks.removeAll()
    }
    
    /// Get count of pending enrichments
    public func pendingCount() -> Int {
        return enrichmentTasks.count
    }
    
    private func removeTask(documentId: String) {
        enrichmentTasks.removeValue(forKey: documentId)
    }
}
