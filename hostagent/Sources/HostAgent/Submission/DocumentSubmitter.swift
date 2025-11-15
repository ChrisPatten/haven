import Foundation
import CryptoKit
import HavenCore
import Entity

/// Protocol for document submission
public protocol DocumentSubmitter: Sendable {
    /// Submit a single document
    func submit(_ document: EnrichedDocument) async throws -> SubmissionResult
    
    /// Submit multiple documents (accepts whatever batch size is passed in)
    func submitBatch(_ documents: [EnrichedDocument]) async throws -> [SubmissionResult]
}

/// Batch document submitter that handles batching and retry logic
public actor BatchDocumentSubmitter: DocumentSubmitter {
    private let gatewayClient: GatewaySubmissionClient
    private let logger = HavenLogger(category: "document-submitter")
    
    public init(gatewayClient: GatewaySubmissionClient) {
        self.gatewayClient = gatewayClient
    }
    
    public func submit(_ document: EnrichedDocument) async throws -> SubmissionResult {
        // Single document submission - wrap in array and submit
        let results = try await submitBatch([document])
        return results.first ?? SubmissionResult.failure(error: "No result")
    }
    
    public func submitBatch(_ documents: [EnrichedDocument]) async throws -> [SubmissionResult] {
        guard !documents.isEmpty else {
            return []
        }
        
        // Convert EnrichedDocument to EmailDocumentPayload for submission
        // Note: This is a temporary conversion layer - in the future, we may want
        // a more generic payload format that supports all document types
        var payloads: [EmailDocumentPayload] = []
        
        for document in documents {
            do {
                let payload = try convertToEmailDocumentPayload(document)
                payloads.append(payload)
            } catch {
                logger.error("Failed to convert document to payload", metadata: [
                    "source_type": document.base.sourceType,
                    "source_id": document.base.externalId,
                    "error": error.localizedDescription
                ])
                // Continue with other documents even if one fails conversion
            }
        }
        
        guard !payloads.isEmpty else {
            return documents.map { _ in
                SubmissionResult.failure(error: "Failed to convert document to payload")
            }
        }
        
        // Submit batch to gateway
        do {
            if let batchResults = try await gatewayClient.submitDocumentsBatch(payloads: payloads) {
                // Convert GatewayBatchSubmissionResult to SubmissionResult
                return batchResults.map { batchResult in
                    if let submission = batchResult.submission {
                        return SubmissionResult.success(submission: submission)
                    } else {
                        return SubmissionResult.failure(
                            error: batchResult.errorMessage ?? "Unknown error",
                            statusCode: batchResult.statusCode,
                            retryable: batchResult.retryable
                        )
                    }
                }
            } else {
                // Batch endpoint unavailable, fall back to individual submissions
                logger.debug("Gateway batch endpoint unavailable; falling back to single submissions", metadata: [
                    "request_count": "\(payloads.count)"
                ])
                
                var results: [SubmissionResult] = []
                for payload in payloads {
                    do {
                        let textHash = payload.metadata.contentHash
                        let idempotencyKey = makeDocumentIdempotencyKey(
                            sourceType: payload.sourceType,
                            externalId: payload.sourceId,
                            textHash: textHash
                        )
                        let submission = try await gatewayClient.submitDocument(payload: payload, idempotencyKey: idempotencyKey)
                        results.append(SubmissionResult.success(submission: submission))
                    } catch {
                        results.append(SubmissionResult.failure(error: error.localizedDescription))
                    }
                }
                return results
            }
        } catch {
            logger.error("Batch submission failed", metadata: [
                "error": error.localizedDescription
            ])
            // Return failure for all documents
            return documents.map { _ in
                SubmissionResult.failure(error: error.localizedDescription)
            }
        }
    }
    
    /// Convert EnrichedDocument to EmailDocumentPayload
    /// This is a conversion layer - in the future, we may want a more generic payload format
    private func convertToEmailDocumentPayload(_ document: EnrichedDocument) throws -> EmailDocumentPayload {
        let base = document.base
        
        // First, merge enrichment data into the document content
        // This applies the unified enrichment strategy: image placeholders + enrichment metadata
        var documentDict: [String: Any] = [
            "text": base.content,
            "metadata": [:]
        ]
        
        // Extract image attachments from base.images for EnrichmentMerger
        let imageAttachments = base.images.map { image in
            ["filename": image.filename ?? "image"] as [String: Any]
        }
        
        let mergedDoc = EnrichmentMerger.mergeEnrichmentIntoDocument(documentDict, document, imageAttachments: imageAttachments.isEmpty ? nil : imageAttachments)
        let mergedContent = mergedDoc["text"] as? String ?? base.content
        let mergedMetadataDict = mergedDoc["metadata"] as? [String: Any] ?? [:]
        
        // Build content with enriched text (includes image placeholders)
        let content = EmailDocumentContent(
            mimeType: base.metadata.mimeType,
            data: mergedContent,
            encoding: nil
        )
        
        // Extract image captions from enrichment
        let imageCaptions = extractImageCaptions(from: document)
        
        // Build metadata with enrichment data from merged document
        // The mergedMetadataDict contains the unified enrichment structure
        var headers: [String: String] = [:]
        
        // Preserve all additionalMetadata from the base document (includes reminder metadata)
        for (key, value) in base.metadata.additionalMetadata {
            headers[key] = value
        }
        
        // Extract enrichment data that was merged in
        var enrichmentEntities: [String: Any]? = nil
        if let enrichment = mergedMetadataDict["enrichment"] as? [String: Any],
           let entities = enrichment["entities"] as? [[String: Any]], !entities.isEmpty {
            // Format entities as EntitySet JSONB structure
            var entitySet: [String: Any] = [
                "detected_languages": [] as [String],
                "people": [] as [[String: Any]],
                "organizations": [] as [[String: Any]],
                "places": [] as [[String: Any]],
                "dates": [] as [[String: Any]],
                "times": [] as [[String: Any]],
                "addresses": [] as [[String: Any]],
                "ner_version": "1.0",
                "ner_framework": "NaturalLanguage",
                "processing_timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            
            // Map entity types to EntitySet arrays
            let typeMapping: [String: String] = [
                "person": "people",
                "organization": "organizations",
                "place": "places",
                "date": "dates",
                "time": "times",
                "address": "addresses"
            ]
            
            for entity in entities {
                guard let typeStr = entity["type"] as? String,
                      let targetKey = typeMapping[typeStr] else { continue }
                
                // Use entity data as-is (it already has text, range, confidence)
                if var entityArray = entitySet[targetKey] as? [[String: Any]] {
                    entityArray.append(entity)
                    entitySet[targetKey] = entityArray
                }
            }
            
            // Only include if we have entities
            let peopleArray = entitySet["people"] as? [[String: Any]] ?? []
            let orgsArray = entitySet["organizations"] as? [[String: Any]] ?? []
            let placesArray = entitySet["places"] as? [[String: Any]] ?? []
            let datesArray = entitySet["dates"] as? [[String: Any]] ?? []
            let timesArray = entitySet["times"] as? [[String: Any]] ?? []
            let addressesArray = entitySet["addresses"] as? [[String: Any]] ?? []
            
            let hasEntities = !peopleArray.isEmpty || !orgsArray.isEmpty || !placesArray.isEmpty ||
                             !datesArray.isEmpty || !timesArray.isEmpty || !addressesArray.isEmpty
            
            if hasEntities {
                enrichmentEntities = entitySet
            }
        }
        
        let metadata = EmailDocumentMetadata(
            messageId: nil,  // Would come from collector-specific logic
            subject: base.title,
            snippet: String(base.content.prefix(200)),  // Generate snippet from content
            listUnsubscribe: nil,
            headers: headers,
            hasAttachments: !base.images.isEmpty,
            attachmentCount: base.images.count,
            contentHash: base.metadata.contentHash,
            references: [],
            inReplyTo: nil,
            intent: nil,  // Intent would come from collector-specific logic
            relevanceScore: nil,
            imageCaptions: imageCaptions.isEmpty ? nil : imageCaptions,
            bodyProcessed: true,
            enrichmentEntities: enrichmentEntities
        )
        
        // Extract reminder-specific fields from additionalMetadata if present
        var hasDueDate: Bool? = nil
        var dueDate: Date? = nil
        var isCompleted: Bool? = nil
        var completedAt: Date? = nil
        
        if let hasDueDateStr = base.metadata.additionalMetadata["has_due_date"] {
            hasDueDate = hasDueDateStr.lowercased() == "true"
        }
        if let dueDateStr = base.metadata.additionalMetadata["due_date"] {
            let formatter = ISO8601DateFormatter()
            dueDate = formatter.date(from: dueDateStr)
        }
        if let isCompletedStr = base.metadata.additionalMetadata["is_completed"] {
            isCompleted = isCompletedStr.lowercased() == "true"
        }
        if let completedAtStr = base.metadata.additionalMetadata["completed_at"] {
            let formatter = ISO8601DateFormatter()
            completedAt = formatter.date(from: completedAtStr)
        }
        
        return EmailDocumentPayload(
            sourceType: base.sourceType,
            sourceId: base.externalId,
            title: base.title,
            canonicalUri: base.canonicalUri,
            content: content,
            metadata: metadata,
            contentTimestamp: base.metadata.timestamp,
            contentTimestampType: base.metadata.timestampType ?? "modified",
            people: [],  // People data would come from collector-specific logic
            threadId: nil,  // Thread data would come from collector-specific logic
            thread: nil,
            intent: nil,  // Intent would come from collector-specific logic
            relevanceScore: nil,
            hasDueDate: hasDueDate,
            dueDate: dueDate,
            isCompleted: isCompleted,
            completedAt: completedAt
        )
    }
    
    /// Extract image captions from enriched document
    private func extractImageCaptions(from document: EnrichedDocument) -> [String] {
        var captions: [String] = []
        for imageEnrichment in document.imageEnrichments {
            if let caption = imageEnrichment.caption, !caption.isEmpty {
                captions.append(caption)
            }
        }
        return captions
    }
    
    /// Make document idempotency key
    private func makeDocumentIdempotencyKey(sourceType: String, externalId: String, textHash: String) -> String {
        let combined = "\(sourceType):\(externalId):\(textHash)"
        return sha256Hex(of: combined.data(using: .utf8)!)
    }
    
    /// Compute SHA-256 hash
    private func sha256Hex(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
