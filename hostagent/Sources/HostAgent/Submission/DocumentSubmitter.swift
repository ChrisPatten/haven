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
    
    /// Flush any buffered documents immediately
    /// Returns submission statistics (submitted count, error count)
    func flush() async throws -> SubmissionStats
    
    /// Finish: flush remaining buffered documents and finalize
    /// Returns submission statistics (submitted count, error count)
    func finish() async throws -> SubmissionStats
    
    /// Get current submission statistics without flushing
    func getStats() async -> SubmissionStats
    
    /// Reset submission statistics for a new run
    func reset() async
}

/// Batch document submitter that handles batching and retry logic
public actor BatchDocumentSubmitter: DocumentSubmitter {
    private let gatewayClient: GatewaySubmissionClient
    private let logger = HavenLogger(category: "document-submitter")
    private let batchSize: Int
    private var buffer: [EnrichedDocument] = []
    private var submittedCount: Int = 0
    private var errorCount: Int = 0
    
    public init(gatewayClient: GatewaySubmissionClient, batchSize: Int = 200) {
        self.gatewayClient = gatewayClient
        self.batchSize = max(1, batchSize)
    }
    
    public func submit(_ document: EnrichedDocument) async throws -> SubmissionResult {
        buffer.append(document)
        try await flushIfNeeded()
        // Return a placeholder success; concrete results are logged during flush
        return SubmissionResult(success: true, statusCode: 202, submission: nil, error: nil, retryable: false)
    }
    
    public func submitBatch(_ documents: [EnrichedDocument]) async throws -> [SubmissionResult] {
        guard !documents.isEmpty else {
            return []
        }
        buffer.append(contentsOf: documents)
        try await flushIfNeeded()
        return documents.map { _ in SubmissionResult(success: true, statusCode: 202, submission: nil, error: nil, retryable: false) }
    }
    
    /// Flush buffered documents in chunks up to batchSize
    public func flush() async throws -> SubmissionStats {
        try await flushAllBuffered()
        let stats = SubmissionStats(submittedCount: submittedCount, errorCount: errorCount)
        return stats
    }
    
    /// Finish: flush any remaining buffered documents
    public func finish() async throws -> SubmissionStats {
        try await flushAllBuffered()
        let stats = SubmissionStats(submittedCount: submittedCount, errorCount: errorCount)
        return stats
    }
    
    /// Get current submission statistics without flushing
    public func getStats() async -> SubmissionStats {
        return SubmissionStats(submittedCount: submittedCount, errorCount: errorCount)
    }
    
    /// Reset submission statistics for a new run
    public func reset() async {
        submittedCount = 0
        errorCount = 0
        buffer.removeAll()
        logger.debug("Reset submitter statistics")
    }
    
    // MARK: - Internal helpers
    private func flushIfNeeded() async throws {
        while buffer.count >= batchSize {
            let chunk = Array(buffer.prefix(batchSize))
            try await submitChunk(chunk)
            buffer.removeFirst(min(batchSize, buffer.count))
        }
    }
    
    private func flushAllBuffered() async throws {
        while !buffer.isEmpty {
            let take = min(batchSize, buffer.count)
            let chunk = Array(buffer.prefix(take))
            try await submitChunk(chunk)
            buffer.removeFirst(take)
        }
    }
    
    private func submitChunk(_ documents: [EnrichedDocument]) async throws {
        var payloads: [EmailDocumentPayload] = []
        var conversionErrors = 0
        for document in documents {
            do {
                let payload = try convertToEmailDocumentPayload(document)
                payloads.append(payload)
            } catch {
                conversionErrors += 1
                errorCount += 1
                logger.error("Failed to convert document to payload", metadata: [
                    "source_type": document.base.sourceType,
                    "source_id": document.base.externalId,
                    "error": error.localizedDescription
                ])
            }
        }
        guard !payloads.isEmpty else {
            // All documents failed conversion - count as errors
            errorCount += documents.count - conversionErrors
            return
        }
        
        do {
            if let batchResults = try await gatewayClient.submitDocumentsBatch(payloads: payloads) {
                // Count successful and failed submissions from batch results
                var chunkSubmitted = 0
                var chunkErrors = 0
                var errorDetails: [String: Int] = [:]  // Track error codes
                
                for result in batchResults {
                    if result.submission != nil {
                        chunkSubmitted += 1
                    } else {
                        chunkErrors += 1
                        // Log error details for debugging
                        let errorCode = result.errorCode ?? "UNKNOWN"
                        errorDetails[errorCode, default: 0] += 1
                        if let errorMessage = result.errorMessage {
                            logger.debug("document_submission_failed", metadata: [
                                "error_code": errorCode,
                                "error_message": errorMessage,
                                "retryable": String(result.retryable)
                            ])
                        }
                    }
                }
                submittedCount += chunkSubmitted
                errorCount += chunkErrors + conversionErrors
                
                var logMetadata: [String: String] = [
                    "batch_size": String(payloads.count),
                    "posted_to_gateway": String(chunkSubmitted),
                    "errors": String(chunkErrors)
                ]
                
                // Include error breakdown if there are errors
                if !errorDetails.isEmpty {
                    let errorBreakdown = errorDetails.map { "\($0.key):\($0.value)" }.joined(separator: ",")
                    logMetadata["error_breakdown"] = errorBreakdown
                }
                
                logger.info("gateway_batch_flush", metadata: logMetadata)
            } else {
                logger.debug("batch_endpoint_unavailable_fallback", metadata: [
                    "request_count": "\(payloads.count)"
                ])
                // Fallback to individual submissions
                var chunkSubmitted = 0
                var chunkErrors = 0
                for payload in payloads {
                    do {
                        let textHash = payload.metadata.contentHash
                        let idempotencyKey = makeDocumentIdempotencyKey(
                            sourceType: payload.sourceType,
                            externalId: payload.sourceId,
                            textHash: textHash
                        )
                        _ = try await gatewayClient.submitDocument(payload: payload, idempotencyKey: idempotencyKey)
                        chunkSubmitted += 1
                    } catch {
                        chunkErrors += 1
                        logger.error("single_submission_failed", metadata: ["error": error.localizedDescription])
                    }
                }
                submittedCount += chunkSubmitted
                errorCount += chunkErrors + conversionErrors
            }
        } catch {
            // Entire batch failed - count all as errors
            errorCount += payloads.count + conversionErrors
            logger.error("batch_submission_failed", metadata: [
                "error": error.localizedDescription,
                "batch_size": String(payloads.count)
            ])
            // Re-throw the error so callers can handle it
            throw error
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
        
        // Try to preserve original metadata structure if available (for iMessage, etc.)
        // Store it in headers so gateway can extract and use it
        var enhancedHeaders = headers
        if let originalMetadataJson = base.metadata.additionalMetadata["original_metadata"],
           let jsonData = originalMetadataJson.data(using: .utf8),
           let originalMetadata = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            // Preserve original metadata structure - merge enrichment into it
            var preservedMetadata = originalMetadata
            
            // Merge enrichment data into original metadata if present
            if let enrichment = mergedMetadataDict["enrichment"] as? [String: Any] {
                preservedMetadata["enrichment"] = enrichment
            }
            
            // Add image captions if present
            if !imageCaptions.isEmpty {
                if var enrichment = preservedMetadata["enrichment"] as? [String: Any] {
                    enrichment["captions"] = imageCaptions
                    preservedMetadata["enrichment"] = enrichment
                } else {
                    preservedMetadata["enrichment"] = ["captions": imageCaptions]
                }
            }
            
            // Store the full preserved metadata in headers so gateway can extract it
            if let preservedMetadataJson = try? JSONSerialization.data(withJSONObject: preservedMetadata, options: []),
               let preservedMetadataString = String(data: preservedMetadataJson, encoding: .utf8) {
                enhancedHeaders["_original_metadata"] = preservedMetadataString
            }
        }
        
        let finalMetadata = EmailDocumentMetadata(
            messageId: nil,  // Would come from collector-specific logic
            subject: base.title,
            snippet: String(base.content.prefix(200)),  // Generate snippet from content
            listUnsubscribe: nil,
            headers: enhancedHeaders,
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
        
        // Extract thread payload from additionalMetadata if present
        var threadId: UUID? = nil
        var threadPayload: EmailThreadPayload? = nil
        if let threadPayloadJson = base.metadata.additionalMetadata["thread_payload"],
           let jsonData = threadPayloadJson.data(using: .utf8),
           let threadDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            // Convert iMessage thread format to EmailThreadPayload format
            let externalId = threadDict["external_id"] as? String ?? ""
            
            // Generate deterministic UUID from external_id for threadId
            if !externalId.isEmpty {
                // Use SHA256 hash of external_id to generate deterministic UUID (same as EmailCollector)
                let data = Data(externalId.utf8)
                let digest = SHA256.hash(data: data)
                var bytes = Array(digest.prefix(16))
                if bytes.count < 16 {
                    bytes += Array(repeating: 0, count: 16 - bytes.count)
                }
                bytes[6] = (bytes[6] & 0x0F) | 0x50 // Version 5
                bytes[8] = (bytes[8] & 0x3F) | 0x80 // Variant RFC4122
                threadId = bytes.withUnsafeBytes { ptr -> UUID in
                    let rawPtr = ptr.bindMemory(to: UInt8.self)
                    return UUID(uuid: uuid_t(rawPtr[0], rawPtr[1], rawPtr[2], rawPtr[3],
                                             rawPtr[4], rawPtr[5], rawPtr[6], rawPtr[7],
                                             rawPtr[8], rawPtr[9], rawPtr[10], rawPtr[11],
                                             rawPtr[12], rawPtr[13], rawPtr[14], rawPtr[15]))
                }
            }
            
            // Convert participants from iMessage format to EmailDocumentPerson format
            var participants: [EmailDocumentPerson] = []
            if let participantsArray = threadDict["participants"] as? [[String: Any]] {
                for participantDict in participantsArray {
                    let identifier = participantDict["identifier"] as? String ?? ""
                    let identifierType = participantDict["identifier_type"] as? String ?? "imessage"
                    participants.append(EmailDocumentPerson(
                        identifier: identifier,
                        identifierType: identifierType,
                        role: participantDict["role"] as? String ?? "participant"
                    ))
                }
            }
            
            // Convert metadata from iMessage format (dict) to EmailThreadPayload format (dict of strings)
            var threadMetadata: [String: String]? = nil
            if let metadataDict = threadDict["metadata"] as? [String: Any] {
                threadMetadata = [:]
                for (key, value) in metadataDict {
                    threadMetadata?[key] = "\(value)"
                }
            }
            
            threadPayload = EmailThreadPayload(
                externalId: externalId,
                sourceType: threadDict["source_type"] as? String,
                sourceProvider: threadDict["source_provider"] as? String,
                sourceAccountId: threadDict["source_account_id"] as? String,
                title: threadDict["title"] as? String,
                participants: participants,
                metadata: threadMetadata
            )
        }
        
        // Extract people data from additionalMetadata if present
        var people: [EmailDocumentPerson] = []
        if let peoplePayloadJson = base.metadata.additionalMetadata["people_payload"],
           let jsonData = peoplePayloadJson.data(using: .utf8),
           let peopleArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            for personDict in peopleArray {
                let identifier = personDict["identifier"] as? String ?? ""
                let identifierType = personDict["identifier_type"] as? String
                let role = personDict["role"] as? String
                let displayName = personDict["display_name"] as? String
                
                // Convert metadata if present
                var personMetadata: [String: String]? = nil
                if let metadataDict = personDict["metadata"] as? [String: Any] {
                    personMetadata = [:]
                    for (key, value) in metadataDict {
                        personMetadata?[key] = "\(value)"
                    }
                }
                
                people.append(EmailDocumentPerson(
                    identifier: identifier,
                    identifierType: identifierType,
                    role: role,
                    displayName: displayName,
                    metadata: personMetadata
                ))
            }
        }
        
        return EmailDocumentPayload(
            sourceType: base.sourceType,
            sourceId: base.externalId,
            title: base.title,
            canonicalUri: base.canonicalUri,
            content: content,
            metadata: finalMetadata,
            contentTimestamp: base.metadata.timestamp,
            contentTimestampType: base.metadata.timestampType ?? "modified",
            people: people,
            threadId: threadId,
            thread: threadPayload,
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
