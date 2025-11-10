import Foundation
import HavenCore

/// Queue for asynchronous attachment enrichment
/// Processes documents with attachments in the background while allowing
/// non-attachment documents to proceed immediately with NER and batch submission
public actor EnrichmentQueue {
    private let orchestrator: EnrichmentOrchestrator
    private let logger = HavenLogger(category: "enrichment-queue")
    private var enrichmentTasks: [String: Task<EnrichedDocument?, Error>] = [:]
    private var maxConcurrentEnrichments: Int
    
    /// Callback type for when enrichment completes
    public typealias EnrichmentCompletion = (String, EnrichedDocument?) -> Void
    
    public init(orchestrator: EnrichmentOrchestrator, maxConcurrentEnrichments: Int = 3) {
        self.orchestrator = orchestrator
        self.maxConcurrentEnrichments = maxConcurrentEnrichments
    }
    
    /// Queue a document for enrichment
    /// - Parameters:
    ///   - document: The document to enrich
    ///   - documentId: Unique identifier for this document
    ///   - onComplete: Callback invoked when enrichment completes (may be called from any context)
    /// - Returns: True if queued, false if already queued or no attachments
    @discardableResult
    public func queueForEnrichment(
        document: CollectorDocument,
        documentId: String,
        onComplete: @escaping EnrichmentCompletion
    ) -> Bool {
        // Check if document has images that need enrichment
        guard !document.images.isEmpty else {
            // No images, don't queue
            return false
        }
        
        // Check if already queued
        guard enrichmentTasks[documentId] == nil else {
            logger.debug("Document already queued for enrichment", metadata: ["document_id": documentId])
            return false
        }
        
        // Create enrichment task
        let task = Task<EnrichedDocument?, Error> {
            do {
                let enriched = try await orchestrator.enrich(document)
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
        
        // Process enrichment asynchronously
        Task {
            do {
                let enriched = try await task.value
                // Remove from active tasks
                self.removeTask(documentId: documentId)
                // Call completion callback
                onComplete(documentId, enriched)
            } catch {
                // Remove from active tasks
                self.removeTask(documentId: documentId)
                // Call completion with nil to indicate failure
                onComplete(documentId, nil)
            }
        }
        
        logger.debug("Queued document for enrichment", metadata: [
            "document_id": documentId,
            "image_count": String(document.images.count)
        ])
        
        return true
    }
    
    /// Wait for enrichment to complete (for testing or synchronous scenarios)
    public func waitForEnrichment(documentId: String) async throws -> EnrichedDocument? {
        guard let task = enrichmentTasks[documentId] else {
            return nil
        }
        return try await task.value
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

