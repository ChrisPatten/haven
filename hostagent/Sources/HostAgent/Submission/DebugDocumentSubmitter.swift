import Foundation
import CryptoKit
import HavenCore

/// Debug document submitter that writes JSON representations to a file instead of submitting to gateway
/// Uses DebugFileWriter for all file I/O operations
public actor DebugDocumentSubmitter: DocumentSubmitter {
    private let fileWriter: DebugFileWriter
    private let logger = HavenLogger(category: "debug-document-submitter")
    private let encoder: JSONEncoder
    private var submittedCount: Int = 0
    private var errorCount: Int = 0
    
    public init(outputPath: String) {
        // Create shared debug file writer
        self.fileWriter = DebugFileWriter(outputPath: outputPath)
        
        // Configure encoder for JSON output (compact format for JSONL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]  // No pretty printing for JSONL format
        self.encoder = encoder
        
        logger.info("Debug document submitter initialized", metadata: ["output_path": outputPath])
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
        
        // Convert EnrichedDocument to EmailDocumentPayload for JSON serialization
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
        
        let conversionErrorCount = documents.count - payloads.count
        errorCount += conversionErrorCount
        
        guard !payloads.isEmpty else {
            return documents.map { _ in
                SubmissionResult.failure(error: "Failed to convert document to payload")
            }
        }
        
        // Write each payload as a JSON line (JSONL format) using shared file writer
        do {
            var writtenCount = 0
            var writeErrors = 0
            for payload in payloads {
                do {
                    try await fileWriter.writeJSONLine(payload)
                    writtenCount += 1
                } catch {
                    writeErrors += 1
                    logger.warning("Failed to write document to debug file", metadata: [
                        "source_id": payload.sourceId,
                        "error": error.localizedDescription
                    ])
                }
            }
            
            submittedCount += writtenCount
            errorCount += writeErrors
            
            logger.info("Wrote \(writtenCount) documents to debug file", metadata: [
                "written": String(writtenCount),
                "total": String(payloads.count),
                "errors": String(writeErrors)
            ])
            
            // Return success results for successfully written documents, failures for errors
            var results: [SubmissionResult] = []
            for (index, payload) in payloads.enumerated() {
                if index < writtenCount {
                    // Create a mock submission response for successfully written documents
                    let mockSubmission = GatewaySubmissionResponse(
                        submissionId: UUID().uuidString,
                        docId: UUID().uuidString,
                        externalId: payload.sourceId,
                        status: "accepted",
                        threadId: nil,
                        duplicate: false,
                        totalChunks: 0
                    )
                    results.append(SubmissionResult.success(submission: mockSubmission))
                } else {
                    results.append(SubmissionResult.failure(error: "Failed to write to debug file"))
                }
            }
            return results
        } catch {
            // All failed to write
            errorCount += payloads.count
            logger.error("Failed to write documents to debug file", metadata: [
                "error": error.localizedDescription
            ])
            return payloads.map { _ in
                SubmissionResult.failure(error: "Failed to write to debug file: \(error.localizedDescription)")
            }
        }
    }
    
    public func flush() async throws -> SubmissionStats {
        // No buffering; nothing to do
        return SubmissionStats(submittedCount: submittedCount, errorCount: errorCount)
    }
    
    public func finish() async throws -> SubmissionStats {
        // No buffering; nothing to do
        return SubmissionStats(submittedCount: submittedCount, errorCount: errorCount)
    }
    
    /// Get current submission statistics without flushing
    public func getStats() async -> SubmissionStats {
        return SubmissionStats(submittedCount: submittedCount, errorCount: errorCount)
    }
    
    /// Reset submission statistics for a new run
    public func reset() async {
        submittedCount = 0
        errorCount = 0
        logger.debug("Reset submitter statistics")
    }
    
    /// Convert EnrichedDocument to EmailDocumentPayload
    /// This matches the conversion logic from BatchDocumentSubmitter
    private func convertToEmailDocumentPayload(_ document: EnrichedDocument) throws -> EmailDocumentPayload {
        let base = document.base
        
        // Build content
        let content = EmailDocumentContent(
            mimeType: base.metadata.mimeType,
            data: base.content,
            encoding: nil
        )
        
        // Extract image captions from enrichment
        let imageCaptions = extractImageCaptions(from: document)
        
        // Build metadata with enrichment data
        var headers: [String: String] = [:]
        
        // Store entity information in headers
        if let entities = document.documentEnrichment?.entities, !entities.isEmpty {
            let entityData = entities.map { "\($0.type.rawValue):\($0.text)" }.joined(separator: ",")
            headers["x-enrichment-entities"] = entityData
        }
        
        // Store OCR, face detection, and caption info in headers
        for (index, imageEnrichment) in document.imageEnrichments.enumerated() {
            if let ocr = imageEnrichment.ocr, !ocr.ocrText.isEmpty {
                headers["x-image-\(index)-ocr"] = ocr.ocrText.prefix(200).description
            }
            if let faces = imageEnrichment.faces, !faces.faces.isEmpty {
                headers["x-image-\(index)-faces"] = "\(faces.faces.count)"
            }
            if let caption = imageEnrichment.caption, !caption.isEmpty {
                headers["x-image-\(index)-caption"] = caption.prefix(200).description
            }
        }
        
        let metadata = EmailDocumentMetadata(
            messageId: nil,
            subject: base.title,
            snippet: String(base.content.prefix(200)),
            listUnsubscribe: nil,
            headers: headers,
            hasAttachments: !base.images.isEmpty,
            attachmentCount: base.images.count,
            contentHash: base.metadata.contentHash,
            references: [],
            inReplyTo: nil,
            intent: nil,
            relevanceScore: nil,
            imageCaptions: imageCaptions.isEmpty ? nil : imageCaptions,
            bodyProcessed: true
        )
        
        return EmailDocumentPayload(
            sourceType: base.sourceType,
            sourceId: base.externalId,
            title: base.title,
            canonicalUri: base.canonicalUri,
            content: content,
            metadata: metadata,
            contentTimestamp: base.metadata.timestamp,
            contentTimestampType: base.metadata.timestampType ?? "modified",
            people: [],
            threadId: nil,
            thread: nil,
            intent: nil,
            relevanceScore: nil
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
}
