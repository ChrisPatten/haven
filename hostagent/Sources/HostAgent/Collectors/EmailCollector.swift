import Foundation
import CryptoKit
import HavenCore
import Email
import OCR
import Entity
import Face
import Caption

public protocol EmailCollecting: Sendable {
    func buildDocumentPayload(
        email: EmailMessage,
        intent: IntentClassification?,
        relevance: Double?,
        sourceType: String?,
        sourceIdPrefix: String?
    ) async throws -> EmailDocumentPayload

    func submitEmailDocument(_ payload: EmailDocumentPayload) async throws -> GatewaySubmissionResponse
    func submitEmailDocuments(_ payloads: [EmailDocumentPayload], preferBatch: Bool) async throws -> [EmailCollectorSubmissionResult]

    func submitEmailAttachment(
        fileURL: URL,
        attachment: EmailAttachment,
        messageId: String?,
        intent: IntentClassification?,
        relevance: Double?,
        enrichment: EmailAttachmentEnrichment?,
        sourceType: String?,
        sourceIdPrefix: String?
    ) async throws -> GatewayFileSubmissionResponse
}

public struct EmailCollectorSubmissionResult: Sendable {
    public let statusCode: Int
    public let submission: GatewaySubmissionResponse?
    public let errorCode: String?
    public let errorMessage: String?
    public let retryable: Bool

    public init(
        statusCode: Int,
        submission: GatewaySubmissionResponse?,
        errorCode: String?,
        errorMessage: String?,
        retryable: Bool
    ) {
        self.statusCode = statusCode
        self.submission = submission
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.retryable = retryable
    }
}

public extension EmailCollecting {
    func buildDocumentPayload(
        email: EmailMessage,
        intent: IntentClassification? = nil,
        relevance: Double? = nil
    ) async throws -> EmailDocumentPayload {
        try await buildDocumentPayload(
            email: email,
            intent: intent,
            relevance: relevance,
            sourceType: nil,
            sourceIdPrefix: nil
        )
    }
    
    func submitEmailAttachment(
        fileURL: URL,
        attachment: EmailAttachment,
        messageId: String?,
        intent: IntentClassification? = nil,
        relevance: Double? = nil,
        enrichment: EmailAttachmentEnrichment? = nil
    ) async throws -> GatewayFileSubmissionResponse {
        try await submitEmailAttachment(
            fileURL: fileURL,
            attachment: attachment,
            messageId: messageId,
        intent: intent,
        relevance: relevance,
        enrichment: enrichment,
        sourceType: nil,
        sourceIdPrefix: nil
    )
    }

    func submitEmailDocuments(
        _ payloads: [EmailDocumentPayload],
        preferBatch: Bool = false
    ) async throws -> [EmailCollectorSubmissionResult] {
        var results: [EmailCollectorSubmissionResult] = []
        results.reserveCapacity(payloads.count)

        for payload in payloads {
            do {
                let submission = try await submitEmailDocument(payload)
                results.append(
                    EmailCollectorSubmissionResult(
                        statusCode: 202,
                        submission: submission,
                        errorCode: nil,
                        errorMessage: nil,
                        retryable: false
                    )
                )
            } catch {
                results.append(
                    EmailCollectorSubmissionResult(
                        statusCode: 500,
                        submission: nil,
                        errorCode: "INGEST.EMAIL_ERROR",
                        errorMessage: error.localizedDescription,
                        retryable: false
                    )
                )
            }
        }

        return results
    }
}

public enum EmailCollectorError: Error, LocalizedError {
    case emptyContent
    case attachmentFileNotFound(URL)
    case attachmentReadFailed(URL, String)
    case gatewayInvalidResponse
    case gatewayHTTPError(Int, String)
    
    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Email body content was empty after normalization"
        case .attachmentFileNotFound(let url):
            return "Attachment not found at path: \(url.path)"
        case .attachmentReadFailed(let url, let reason):
            return "Failed to read attachment at \(url.path): \(reason)"
        case .gatewayInvalidResponse:
            return "Gateway returned an invalid response"
        case .gatewayHTTPError(let code, let body):
            return "Gateway HTTP error \(code): \(body)"
        }
    }
}

extension EmailCollector: EmailCollecting {}

public struct EmailDocumentContent: Codable, Equatable {
    public var mimeType: String
    public var data: String
    public var encoding: String?
    
    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
        case encoding
    }
}

public struct EmailIntentPayload: Codable, Equatable {
    public var primaryIntent: String
    public var confidence: Double
    public var secondaryIntents: [String]
    public var extractedEntities: [String: String]
    
    enum CodingKeys: String, CodingKey {
        case primaryIntent = "primary_intent"
        case confidence
        case secondaryIntents = "secondary_intents"
        case extractedEntities = "extracted_entities"
    }
}

public struct EmailDocumentMetadata: Codable, Equatable {
    public var messageId: String?
    public var subject: String?
    public var snippet: String?
    public var listUnsubscribe: String?
    public var headers: [String: String]
    public var hasAttachments: Bool
    public var attachmentCount: Int
    public var contentHash: String
    public var references: [String]
    public var inReplyTo: String?
    public var intent: EmailIntentPayload?
    public var relevanceScore: Double?
    public var imageCaptions: [String]?
    public var bodyProcessed: Bool?
    public var enrichmentEntities: [String: Any]?
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case subject
        case snippet
        case listUnsubscribe = "list_unsubscribe"
        case headers
        case hasAttachments = "has_attachments"
        case attachmentCount = "attachment_count"
        case contentHash = "content_hash"
        case references
        case inReplyTo = "in_reply_to"
        case intent
        case relevanceScore = "relevance_score"
        case imageCaptions = "image_captions"
        case bodyProcessed = "body_processed"
        case enrichmentEntities = "enrichment_entities"
    }
    
    public init(
        messageId: String? = nil,
        subject: String? = nil,
        snippet: String? = nil,
        listUnsubscribe: String? = nil,
        headers: [String: String],
        hasAttachments: Bool,
        attachmentCount: Int,
        contentHash: String,
        references: [String],
        inReplyTo: String? = nil,
        intent: EmailIntentPayload? = nil,
        relevanceScore: Double? = nil,
        imageCaptions: [String]? = nil,
        bodyProcessed: Bool? = nil,
        enrichmentEntities: [String: Any]? = nil
    ) {
        self.messageId = messageId
        self.subject = subject
        self.snippet = snippet
        self.listUnsubscribe = listUnsubscribe
        self.headers = headers
        self.hasAttachments = hasAttachments
        self.attachmentCount = attachmentCount
        self.contentHash = contentHash
        self.references = references
        self.inReplyTo = inReplyTo
        self.intent = intent
        self.relevanceScore = relevanceScore
        self.imageCaptions = imageCaptions
        self.bodyProcessed = bodyProcessed
        self.enrichmentEntities = enrichmentEntities
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet)
        listUnsubscribe = try container.decodeIfPresent(String.self, forKey: .listUnsubscribe)
        headers = try container.decode([String: String].self, forKey: .headers)
        hasAttachments = try container.decode(Bool.self, forKey: .hasAttachments)
        attachmentCount = try container.decode(Int.self, forKey: .attachmentCount)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        references = try container.decode([String].self, forKey: .references)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        intent = try container.decodeIfPresent(EmailIntentPayload.self, forKey: .intent)
        relevanceScore = try container.decodeIfPresent(Double.self, forKey: .relevanceScore)
        imageCaptions = try container.decodeIfPresent([String].self, forKey: .imageCaptions)
        bodyProcessed = try container.decodeIfPresent(Bool.self, forKey: .bodyProcessed)
        
        // Decode enrichmentEntities using AnyCodable wrapper
        if let codableDict = try? container.decodeIfPresent([String: HavenCore.AnyCodable].self, forKey: .enrichmentEntities) {
            enrichmentEntities = codableDict.mapValues { $0.value }
        } else {
            enrichmentEntities = nil
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encodeIfPresent(snippet, forKey: .snippet)
        try container.encodeIfPresent(listUnsubscribe, forKey: .listUnsubscribe)
        try container.encode(headers, forKey: .headers)
        try container.encode(hasAttachments, forKey: .hasAttachments)
        try container.encode(attachmentCount, forKey: .attachmentCount)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(references, forKey: .references)
        try container.encodeIfPresent(inReplyTo, forKey: .inReplyTo)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encodeIfPresent(relevanceScore, forKey: .relevanceScore)
        try container.encodeIfPresent(imageCaptions, forKey: .imageCaptions)
        try container.encodeIfPresent(bodyProcessed, forKey: .bodyProcessed)
        
        // Encode enrichmentEntities using AnyCodable wrapper
        if let entities = enrichmentEntities {
            let codableDict = entities.mapValues { HavenCore.AnyCodable($0) }
            try container.encodeIfPresent(codableDict, forKey: .enrichmentEntities)
        }
    }
    
    public static func == (lhs: EmailDocumentMetadata, rhs: EmailDocumentMetadata) -> Bool {
        // Compare all fields except enrichmentEntities (which is [String: Any] and can't be compared directly)
        return lhs.messageId == rhs.messageId &&
               lhs.subject == rhs.subject &&
               lhs.snippet == rhs.snippet &&
               lhs.listUnsubscribe == rhs.listUnsubscribe &&
               lhs.headers == rhs.headers &&
               lhs.hasAttachments == rhs.hasAttachments &&
               lhs.attachmentCount == rhs.attachmentCount &&
               lhs.contentHash == rhs.contentHash &&
               lhs.references == rhs.references &&
               lhs.inReplyTo == rhs.inReplyTo &&
               lhs.intent == rhs.intent &&
               lhs.relevanceScore == rhs.relevanceScore &&
               lhs.imageCaptions == rhs.imageCaptions &&
               lhs.bodyProcessed == rhs.bodyProcessed
        // enrichmentEntities comparison skipped - would need custom comparison
    }
}

public struct EmailDocumentPerson: Codable, Equatable {
    public var identifier: String
    public var identifierType: String?
    public var role: String?
    public var displayName: String?
    public var metadata: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case identifier
        case identifierType = "identifier_type"
        case role
        case displayName = "display_name"
        case metadata
    }
}

public struct EmailThreadPayload: Codable, Equatable {
    public var externalId: String
    public var sourceType: String?
    public var sourceProvider: String?
    public var sourceAccountId: String?
    public var title: String?
    public var participants: [EmailDocumentPerson]
    public var metadata: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case sourceType = "source_type"
        case sourceProvider = "source_provider"
        case sourceAccountId = "source_account_id"
        case title
        case participants
        case metadata
    }
}

public struct EmailDocumentPayload: Codable, Equatable {
    public var sourceType: String
    public var sourceId: String
    public var sourceProvider: String?
    public var sourceAccountId: String?
    public var title: String?
    public var canonicalUri: String?
    public var content: EmailDocumentContent
    public var metadata: EmailDocumentMetadata
    public var contentTimestamp: Date?
    public var contentTimestampType: String?
    public var people: [EmailDocumentPerson]
    public var threadId: UUID?
    public var thread: EmailThreadPayload?
    public var intent: EmailIntentPayload?
    public var relevanceScore: Double?
    // Reminder-specific fields
    public var hasDueDate: Bool?
    public var dueDate: Date?
    public var isCompleted: Bool?
    public var completedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case sourceId = "source_id"
        case sourceProvider = "source_provider"
        case sourceAccountId = "source_account_id"
        case title
        case canonicalUri = "canonical_uri"
        case content
        case metadata
        case contentTimestamp = "content_timestamp"
        case contentTimestampType = "content_timestamp_type"
        case people
        case threadId = "thread_id"
        case thread
        case intent
        case relevanceScore = "relevance_score"
        case hasDueDate = "has_due_date"
        case dueDate = "due_date"
        case isCompleted = "is_completed"
        case completedAt = "completed_at"
    }
}

public struct EmailAttachmentEnrichment: Codable, Equatable {
    public var ocrText: String?
    public var entities: [String: [String]]?
    public var caption: String?
    
    enum CodingKeys: String, CodingKey {
        case ocrText = "ocr_text"
        case entities
        case caption
    }
}

public struct EmailAttachmentMeta: Codable, Equatable {
    public var source: String
    public var path: String
    public var filename: String?
    public var mimeType: String?
    public var sha256: String
    public var size: Int?
    public var messageId: String?
    public var contentId: String?
    public var intent: EmailIntentPayload?
    public var relevanceScore: Double?
    public var enrichment: EmailAttachmentEnrichment?
    
    enum CodingKeys: String, CodingKey {
        case source
        case path
        case filename
        case mimeType = "mime_type"
        case sha256
        case size
        case messageId = "message_id"
        case contentId = "content_id"
        case intent
        case relevanceScore = "relevance_score"
        case enrichment
    }
}

public struct GatewaySubmissionResponse: Codable, Equatable, Sendable {
    public var submissionId: String
    public var docId: String
    public var externalId: String
    public var status: String
    public var threadId: String?
    public var duplicate: Bool
    public var totalChunks: Int
    
    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case docId = "doc_id"
        case externalId = "external_id"
        case status
        case threadId = "thread_id"
        case duplicate
        case totalChunks = "total_chunks"
    }
}

public struct GatewayFileSubmissionResponse: Codable, Equatable, Sendable {
    public var submissionId: String
    public var docId: String
    public var externalId: String
    public var status: String
    public var threadId: String?
    public var duplicate: Bool
    public var totalChunks: Int
    public var fileSha256: String
    public var objectKey: String
    public var extractionStatus: String
    
    public init(
        submissionId: String,
        docId: String,
        externalId: String,
        status: String,
        threadId: String? = nil,
        duplicate: Bool = false,
        totalChunks: Int = 0,
        fileSha256: String = "",
        objectKey: String = "",
        extractionStatus: String = "completed"
    ) {
        self.submissionId = submissionId
        self.docId = docId
        self.externalId = externalId
        self.status = status
        self.threadId = threadId
        self.duplicate = duplicate
        self.totalChunks = totalChunks
        self.fileSha256 = fileSha256
        self.objectKey = objectKey
        self.extractionStatus = extractionStatus
    }
    
    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case docId = "doc_id"
        case externalId = "external_id"
        case status
        case threadId = "thread_id"
        case duplicate
        case totalChunks = "total_chunks"
        case fileSha256 = "file_sha256"
        case objectKey = "object_key"
        case extractionStatus = "extraction_status"
    }
}

public actor EmailCollector {
    private let gatewayClient: GatewaySubmissionClient
    private let emailService: EmailService
    private let logger: HavenLogger
    private let defaultSourceType: String
    private let defaultSourceIdPrefix: String
    private let moduleRedaction: RedactionConfig?
    private let sourceRedaction: RedactionConfig?
    
    public init(
        gatewayConfig: GatewayConfig,
        authToken: String,
        session: URLSession? = nil,
        emailService: EmailService? = nil,
        logger: HavenLogger = HavenLogger(category: "email-collector"),
        sourceType: String = "email_local",
        sourceIdPrefix: String? = nil,
        moduleRedaction: RedactionConfig? = nil,
        sourceRedaction: RedactionConfig? = nil
    ) {
        self.gatewayClient = GatewaySubmissionClient(config: gatewayConfig, authToken: authToken, session: session)
        if let providedService = emailService {
            self.emailService = providedService
        } else {
            self.emailService = EmailService()
        }
        self.logger = logger
        self.defaultSourceType = sourceType
        if let explicitPrefix = sourceIdPrefix {
            self.defaultSourceIdPrefix = explicitPrefix
        } else if sourceType == "email_local" {
            self.defaultSourceIdPrefix = "email"
        } else {
            self.defaultSourceIdPrefix = sourceType
        }
        self.moduleRedaction = moduleRedaction
        self.sourceRedaction = sourceRedaction
    }
    
    public func buildDocumentPayload(
        email: EmailMessage,
        intent: IntentClassification? = nil,
        relevance: Double? = nil,
        sourceType overrideSourceType: String? = nil,
        sourceIdPrefix: String? = nil,
        sourceAccountId: String? = nil
    ) async throws -> EmailDocumentPayload {
        let messageId = normalizeMessageId(email.messageId)
        let resolvedSourceType = overrideSourceType ?? defaultSourceType
        let resolvedSourceIdPrefix = sourceIdPrefix ?? defaultSourceIdPrefix
        let sourceId = buildSourceId(messageId: messageId, email: email, prefix: resolvedSourceIdPrefix)
        
        // Use EmailBodyExtractor to get clean body text
        let bodyExtractor = EmailBodyExtractor()
        let cleanBody = await bodyExtractor.extractCleanBody(from: email)
        let normalizedBody = normalizeIngestText(cleanBody)
        guard !normalizedBody.isEmpty else {
            throw EmailCollectorError.emptyContent
        }
        
        let textHash = sha256Hex(of: normalizedBody)
        let redactionOpts = resolveRedactionOptions()
        let redacted = await emailService.redactPII(in: normalizedBody, options: redactionOpts)
        
        // Extract image captions
        let imageExtractor = EmailImageExtractor()
        let imageCaptions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: email.attachments,
            ocrService: nil // TODO: Pass OCR service when available
        )
        
        // Determine content_timestamp and content_timestamp_type following email rules
        // Prefer header Date as primary, fallback to IMAP internaldate
        let contentTimestamp: Date
        let contentTimestampType: String
        let headerDateString: String?
        
        if let headerDate = email.headers["Date"], !headerDate.isEmpty {
            // Try to parse header Date
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
            if let parsedDate = formatter.date(from: headerDate) {
                contentTimestamp = parsedDate
                contentTimestampType = "sent"
                headerDateString = headerDate
            } else {
                // Fallback to internaldate if header Date can't be parsed
                contentTimestamp = email.date ?? Date()
                contentTimestampType = "received"
                headerDateString = headerDate
            }
        } else {
            // Use IMAP internaldate
            contentTimestamp = email.date ?? Date()
            contentTimestampType = "received"
            headerDateString = nil
        }
        
        let content = EmailDocumentContent(mimeType: "text/plain", data: redacted, encoding: nil)
        let snippet = buildSnippet(from: redacted)
        let references = email.references.compactMap { normalizeMessageId($0) }
        
        let intentPayload = intent.map { classification in
            EmailIntentPayload(
                primaryIntent: classification.primaryIntent.rawValue,
                confidence: classification.confidence,
                secondaryIntents: classification.secondaryIntents.map(\.rawValue),
                extractedEntities: classification.extractedEntities
            )
        }
        
        let metadata = EmailDocumentMetadata(
            messageId: messageId,
            subject: email.subject,
            snippet: snippet,
            listUnsubscribe: email.listUnsubscribe,
            headers: email.headers,
            hasAttachments: !email.attachments.isEmpty,
            attachmentCount: email.attachments.count,
            contentHash: textHash,
            references: references,
            inReplyTo: normalizeMessageId(email.inReplyTo),
            intent: intentPayload,
            relevanceScore: relevance,
            imageCaptions: imageCaptions.isEmpty ? nil : imageCaptions,
            bodyProcessed: true
        )
        
        let people = buildPeople(from: email)
        var threadPayload = buildThreadPayload(email: email, people: people)
        // Add source_account_id to thread if available
        if let accountId = sourceAccountId {
            threadPayload?.sourceAccountId = accountId
        }
        let threadId: UUID?
        if let externalId = threadPayload?.externalId {
            threadId = deterministicUUID(from: externalId)
        } else {
            threadId = nil
        }
        
        return EmailDocumentPayload(
            sourceType: resolvedSourceType,
            sourceId: sourceId,
            sourceAccountId: sourceAccountId,
            title: email.subject,
            canonicalUri: messageId.map { "message://\($0)" },
            content: content,
            metadata: metadata,
            contentTimestamp: contentTimestamp,
            contentTimestampType: contentTimestampType,
            people: people,
            threadId: threadId,
            thread: threadPayload,
            intent: intentPayload,
            relevanceScore: relevance
        )
    }
    
    // Overload to satisfy EmailCollecting protocol without sourceAccountId parameter
    public func buildDocumentPayload(
        email: EmailMessage,
        intent: IntentClassification?,
        relevance: Double?,
        sourceType overrideSourceType: String?,
        sourceIdPrefix: String?
    ) async throws -> EmailDocumentPayload {
        return try await buildDocumentPayload(
            email: email,
            intent: intent,
            relevance: relevance,
            sourceType: overrideSourceType,
            sourceIdPrefix: sourceIdPrefix,
            sourceAccountId: nil
        )
    }
    
    public func submitEmailDocument(_ payload: EmailDocumentPayload) async throws -> GatewaySubmissionResponse {
        let textHash: String
        if !payload.metadata.contentHash.isEmpty {
            textHash = payload.metadata.contentHash
        } else {
            textHash = sha256Hex(of: normalizeIngestText(payload.content.data))
        }
        let idempotencyKey = EmailCollector.makeDocumentIdempotencyKey(
            sourceType: payload.sourceType,
            sourceId: payload.sourceId,
            textHash: textHash
        )
        logger.debug("Submitting email document", metadata: [
            "source_id": payload.sourceId,
            "idempotency_key": idempotencyKey
        ])
        return try await gatewayClient.submitDocument(payload: payload, idempotencyKey: idempotencyKey)
    }

    public func submitEmailDocuments(
        _ payloads: [EmailDocumentPayload],
        preferBatch: Bool
    ) async throws -> [EmailCollectorSubmissionResult] {
        guard !payloads.isEmpty else { return [] }

        if preferBatch, payloads.count > 1 {
            if let batchResults = try await gatewayClient.submitDocumentsBatch(payloads: payloads) {
                return batchResults.map {
                    EmailCollectorSubmissionResult(
                        statusCode: $0.statusCode,
                        submission: $0.submission,
                        errorCode: $0.errorCode,
                        errorMessage: $0.errorMessage,
                        retryable: $0.retryable
                    )
                }
            }
            logger.debug("Gateway batch ingest unavailable; falling back to single submissions", metadata: [
                "request_count": "\(payloads.count)"
            ])
        }

        var results: [EmailCollectorSubmissionResult] = []
        results.reserveCapacity(payloads.count)

        for payload in payloads {
            do {
                let submission = try await submitEmailDocument(payload)
                results.append(
                    EmailCollectorSubmissionResult(
                        statusCode: 202,
                        submission: submission,
                        errorCode: nil,
                        errorMessage: nil,
                        retryable: false
                    )
                )
            } catch {
                results.append(
                    EmailCollectorSubmissionResult(
                        statusCode: 500,
                        submission: nil,
                        errorCode: "INGEST.EMAIL_ERROR",
                        errorMessage: error.localizedDescription,
                        retryable: false
                    )
                )
            }
        }

        return results
    }
    
    public func submitEmailAttachment(
        fileURL: URL,
        attachment: EmailAttachment,
        messageId: String?,
        intent: IntentClassification? = nil,
        relevance: Double? = nil,
        enrichment: EmailAttachmentEnrichment? = nil,
        sourceType overrideSourceType: String? = nil,
        sourceIdPrefix: String? = nil
    ) async throws -> GatewayFileSubmissionResponse {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw EmailCollectorError.attachmentFileNotFound(fileURL)
        }
        
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw EmailCollectorError.attachmentReadFailed(fileURL, error.localizedDescription)
        }
        
        let sha = sha256Hex(of: data)
        let filename = attachment.filename ?? fileURL.lastPathComponent
        let pathComponent = messageId ?? sha
        let resolvedSourceType = overrideSourceType ?? defaultSourceType
        let resolvedSourceIdPrefix = sourceIdPrefix ?? defaultSourceIdPrefix
        let metaIntent = intent.map { classification in
            EmailIntentPayload(
                primaryIntent: classification.primaryIntent.rawValue,
                confidence: classification.confidence,
                secondaryIntents: classification.secondaryIntents.map(\.rawValue),
                extractedEntities: classification.extractedEntities
            )
        }
        
        let meta = EmailAttachmentMeta(
            source: resolvedSourceType,
            path: "\(resolvedSourceIdPrefix)/\(pathComponent)/\(filename)",
            filename: filename,
            mimeType: attachment.mimeType,
            sha256: sha,
            size: attachment.size,
            messageId: messageId,
            contentId: attachment.contentId,
            intent: metaIntent,
            relevanceScore: relevance,
            enrichment: enrichment
        )
        
        let idempotencyKey = "email-attachment:\(pathComponent):\(sha)"
        logger.debug("Submitting email attachment", metadata: [
            "filename": filename,
            "sha": sha,
            "idempotency_key": idempotencyKey
        ])
        
        return try await gatewayClient.submitAttachment(
            fileURL: fileURL,
            data: data,
            metadata: meta,
            idempotencyKey: idempotencyKey,
            mimeType: attachment.mimeType ?? "application/octet-stream"
        )
    }
    
    // MARK: - Helpers
    
    private func resolveRedactionOptions() -> RedactionOptions {
        // Resolution order: source override → module default → true (all enabled)
        let config = sourceRedaction ?? moduleRedaction ?? .boolean(true)
        
        switch config {
        case .boolean(let enabled):
            return RedactionOptions(
                emails: enabled,
                phones: enabled,
                accountNumbers: enabled,
                ssn: enabled
            )
        case .detailed(let options):
            return options
        }
    }
    
    private func buildSourceId(messageId: String?, email: EmailMessage, prefix: String) -> String {
        if let messageId, !messageId.isEmpty {
            return "\(prefix):\(messageId)"
        }
        var seedComponents: [String] = []
        if let date = email.date {
            seedComponents.append(String(date.timeIntervalSince1970))
        }
        if let subject = email.subject {
            seedComponents.append(subject)
        }
        if let from = email.from.first {
            seedComponents.append(from)
        }
        let seed = seedComponents.joined(separator: "|")
        return "\(prefix):\(sha256Hex(of: seed))"
    }
    
    private func normalizeIngestText(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func buildSnippet(from text: String, maxLength: Int = 280) -> String {
        if text.count <= maxLength {
            return text
        }
        let index = text.index(text.startIndex, offsetBy: maxLength)
        let prefix = text[text.startIndex..<index]
        return String(prefix) + "..."
    }
    
    private func buildPeople(from email: EmailMessage) -> [EmailDocumentPerson] {
        var people: [EmailDocumentPerson] = []
        var seen = Set<String>()
        
        func append(addresses: [String], role: String) {
            for entry in addresses {
                let parsed = parseAddress(entry)
                guard let identifier = parsed.address?.lowercased() else { continue }
                if seen.contains(identifier) { continue }
                seen.insert(identifier)
                let person = EmailDocumentPerson(
                    identifier: identifier,
                    identifierType: "email",
                    role: role,
                    displayName: parsed.displayName,
                    metadata: nil
                )
                people.append(person)
            }
        }
        
        append(addresses: email.from, role: "sender")
        append(addresses: email.to, role: "recipient")
        append(addresses: email.cc, role: "cc")
        append(addresses: email.bcc, role: "bcc")
        return people
    }
    
    private func parseAddress(_ raw: String) -> (address: String?, displayName: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, nil)
        }
        
        if let start = trimmed.firstIndex(of: "<"), let end = trimmed.firstIndex(of: ">"), start < end {
            let addressStart = trimmed.index(after: start)
            let address = String(trimmed[addressStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let namePart = trimmed[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = namePart.isEmpty ? nil : namePart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (address, displayName)
        }
        
        if trimmed.contains("@") {
            let address = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (address, nil)
        }
        
        return (nil, trimmed)
    }
    
    private func buildThreadPayload(email: EmailMessage, people: [EmailDocumentPerson]) -> EmailThreadPayload? {
        var identifiers = Set<String>()
        if let messageId = normalizeMessageId(email.messageId) {
            identifiers.insert(messageId)
        }
        if let inReplyTo = normalizeMessageId(email.inReplyTo) {
            identifiers.insert(inReplyTo)
        }
        for reference in email.references {
            let normalized = normalizeMessageId(reference)
            if let normalized {
                identifiers.insert(normalized)
            }
        }
        
        guard !identifiers.isEmpty else {
            return nil
        }
        
        let sortedIds = identifiers.sorted()
        let externalId = "email-thread:\(sha256Hex(of: sortedIds.joined(separator: "|")))"
        var metadata: [String: String] = ["message_ids": sortedIds.joined(separator: ",")]
        if let subject = email.subject {
            metadata["subject"] = subject
        }
        
        return EmailThreadPayload(
            externalId: externalId,
            sourceType: "email",
            title: email.subject,
            participants: people,
            metadata: metadata
        )
    }

    public static func makeDocumentIdempotencyKey(
        sourceType: String,
        sourceId: String,
        textHash: String
    ) -> String {
        let seed = "\(sourceType):\(sourceId):\(textHash)"
        return SHA256.hash(data: Data(seed.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func normalizeMessageId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutBrackets = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return withoutBrackets.isEmpty ? nil : withoutBrackets
    }
    
    private func sha256Hex(of text: String) -> String {
        guard let data = text.data(using: .utf8) else {
            return ""
        }
        return sha256Hex(of: data)
    }
    
    private func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func deterministicUUID(from seed: String) -> UUID {
        let data = Data(seed.utf8)
        let digest = SHA256.hash(data: data)
        var bytes = Array(digest.prefix(16))
        if bytes.count < 16 {
            bytes += Array(repeating: 0, count: 16 - bytes.count)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // Version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // Variant RFC4122
        let uuid = bytes.withUnsafeBytes { ptr -> UUID in
            let rawPtr = ptr.bindMemory(to: UInt8.self)
            let tuple = (
                rawPtr[0], rawPtr[1], rawPtr[2], rawPtr[3],
                rawPtr[4], rawPtr[5], rawPtr[6], rawPtr[7],
                rawPtr[8], rawPtr[9], rawPtr[10], rawPtr[11],
                rawPtr[12], rawPtr[13], rawPtr[14], rawPtr[15]
            )
            return UUID(uuid: tuple)
        }
        return uuid
    }
    
    // MARK: - New Architecture Methods
    
    /// Collect and submit email using the new architecture (TextExtractor, ImageExtractor, EnrichmentOrchestrator, DocumentSubmitter)
    /// This is a new method that demonstrates the refactored architecture
    /// - Parameters:
    ///   - email: The email message to process
    ///   - enrichmentOrchestrator: Optional enrichment orchestrator (if nil and skipEnrichment is false, will be created)
    ///   - submitter: Optional document submitter (if nil, will be created)
    ///   - skipEnrichment: Whether to skip enrichment (defaults to false)
    ///   - config: HavenConfig for initializing enrichment services if needed
    ///   - intent: Optional intent classification
    ///   - relevance: Optional relevance score
    /// - Returns: Submission result
    public func collectAndSubmit(
        email: EmailMessage,
        enrichmentOrchestrator: EnrichmentOrchestrator? = nil,
        enrichmentQueue: EnrichmentQueue? = nil,
        submitter: DocumentSubmitter? = nil,
        skipEnrichment: Bool = false,
        config: HavenConfig? = nil,
        intent: IntentClassification? = nil,
        relevance: Double? = nil
    ) async throws -> SubmissionResult {
        // 1. Extract text using shared TextExtractor
        let textExtractor = TextExtractor()
        let rawBody = selectBestBody(from: email)
        let markdownContent = await textExtractor.extractText(from: rawBody, mimeType: email.bodyHTML != nil ? "text/html" : "text/plain")
        let normalizedBody = normalizeIngestText(markdownContent)
        guard !normalizedBody.isEmpty else {
            throw EmailCollectorError.emptyContent
        }
        
        // 2. Redact PII
        let redactionOpts = resolveRedactionOptions()
        let redacted = await emailService.redactPII(in: normalizedBody, options: redactionOpts)
        
        // 3. Extract images using shared ImageExtractor
        // Filter images > 1000 square pixels
        let imageExtractor = ImageExtractor()
        var extractedImages: [ImageAttachment] = []
        
        // Extract images from HTML content (embedded images)
        if let htmlContent = email.bodyHTML {
            let htmlImages = await imageExtractor.extractImages(from: htmlContent, minSquarePixels: 1000)
            extractedImages.append(contentsOf: htmlImages)
        }
        
        // Extract images from email attachments
        // Note: This requires access to attachment file data, which may not be available
        // in all contexts. For IMAP emails, attachments are fetched separately.
        // For now, we'll extract from attachments that are embedded in the MIME message.
        let attachmentImages = await extractImagesFromAttachments(email: email, imageExtractor: imageExtractor)
        extractedImages.append(contentsOf: attachmentImages)
        
        // 4. Build CollectorDocument
        let messageId = normalizeMessageId(email.messageId)
        let resolvedSourceType = defaultSourceType
        let sourceId = buildSourceId(messageId: messageId, email: email, prefix: defaultSourceIdPrefix)
        let textHash = sha256Hex(of: normalizedBody)
        
        let document = CollectorDocument(
            content: redacted,
            sourceType: resolvedSourceType,
            externalId: sourceId,
            metadata: DocumentMetadata(
                contentHash: textHash,
                mimeType: "text/plain",
                timestamp: email.date,
                timestampType: "received",
                createdAt: email.date,
                modifiedAt: email.date
            ),
            images: extractedImages,
            contentType: .email,
            title: email.subject,
            canonicalUri: messageId.map { "message://\($0)" }
        )
        
        // 5. Enrich (if not skipped)
        func performDirectEnrichment() async throws -> EnrichedDocument {
            if let provided = enrichmentOrchestrator {
                return try await provided.enrich(document)
            } else if let config = config {
                let ocrService = config.modules.ocr.enabled ? OCRService(
                    timeoutMs: config.modules.ocr.timeoutMs,
                    languages: config.modules.ocr.languages,
                    recognitionLevel: config.modules.ocr.recognitionLevel,
                    includeLayout: config.modules.ocr.includeLayout
                ) : nil

                let faceService = config.modules.face.enabled ? FaceService(
                    minFaceSize: config.modules.face.minFaceSize,
                    minConfidence: config.modules.face.minConfidence,
                    includeLandmarks: config.modules.face.includeLandmarks
                ) : nil

                let entityService = config.modules.entity.enabled ? EntityService(
                    enabledTypes: config.modules.entity.types.compactMap { EntityType(rawValue: $0) },
                    minConfidence: config.modules.entity.minConfidence
                ) : nil

                let captionService = config.modules.caption.enabled ? CaptionService(
                    method: config.modules.caption.method,
                    timeoutMs: config.modules.caption.timeoutMs,
                    model: config.modules.caption.model
                ) : nil

                let orchestrator = DocumentEnrichmentOrchestrator(
                    ocrService: ocrService,
                    faceService: faceService,
                    entityService: entityService,
                    captionService: captionService,
                    ocrConfig: config.modules.ocr,
                    faceConfig: config.modules.face,
                    entityConfig: config.modules.entity,
                    captionConfig: config.modules.caption
                )
                return try await orchestrator.enrich(document)
            } else {
                return EnrichedDocument(base: document)
            }
        }

        let enriched: EnrichedDocument
        if !skipEnrichment {
            if let queue = enrichmentQueue {
                if let queuedResult = await queue.enqueueAndWait(document: document, documentId: document.externalId) {
                    enriched = queuedResult
                } else {
                    enriched = try await performDirectEnrichment()
                }
            } else {
                enriched = try await performDirectEnrichment()
            }
        } else {
            enriched = EnrichedDocument(base: document)
        }
        
        // 6. Submit
        let docSubmitter = submitter ?? BatchDocumentSubmitter(gatewayClient: gatewayClient)
        return try await docSubmitter.submit(enriched)
    }
    
    /// Select the best available body content from the email (helper for new architecture)
    private func selectBestBody(from email: EmailMessage) -> String {
        // Prefer plain text if available and not empty
        if let plainText = email.bodyPlainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainText
        }
        
        // Fall back to HTML if available
        if let html = email.bodyHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return html
        }
        
        // Last resort: raw content
        return email.rawContent ?? ""
    }
    
    /// Extract images from email attachments
    /// - Parameters:
    ///   - email: The email message
    ///   - imageExtractor: The image extractor to use
    /// - Returns: Array of ImageAttachment objects for images > 1000 square pixels
    private func extractImagesFromAttachments(email: EmailMessage, imageExtractor: ImageExtractor) async -> [ImageAttachment] {
        var images: [ImageAttachment] = []
        
        // Parse raw MIME message to extract image attachment data
        // We need to parse the raw content directly to get binary data before it's decoded as text
        guard let rawContent = email.rawContent else {
            return images
        }
        
        // Parse MIME message structure to find image parts
        let mimeMessage = MIMEParser.parseMIMEMessage(rawContent)
        
        // Process each MIME part to find image attachments
        for (index, part) in mimeMessage.parts.enumerated() {
            // Check if this part is an image attachment
            let contentType = part.contentType.lowercased()
            guard contentType.hasPrefix("image/") else { continue }
            
            // Find corresponding attachment metadata
            guard let attachment = email.attachments.first(where: { $0.partIndex == index }) else { continue }
            
            // Extract raw base64 content from the original MIME message
            // The MIMEParser has already decoded it as a string, but for images we need the raw bytes
            // We'll try to extract the base64 data directly from the raw content
            if let imageData = extractImageDataFromMIMEPart(
                rawContent: rawContent,
                partIndex: index,
                contentType: contentType,
                encoding: part.headers["content-transfer-encoding"]
            ) {
                // Extract images with size filtering
                let partImages = await imageExtractor.extractImages(
                    from: imageData,
                    mimeType: contentType,
                    filePath: attachment.filename,
                    minSquarePixels: 1000
                )
                images.append(contentsOf: partImages)
            }
        }
        
        return images
    }
    
    /// Extract binary image data from a MIME part in the raw email content
    /// - Parameters:
    ///   - rawContent: The raw email content
    ///   - partIndex: The index of the MIME part
    ///   - contentType: The content type of the part
    ///   - encoding: The content-transfer-encoding header value
    /// - Returns: Decoded image data if successful, nil otherwise
    private func extractImageDataFromMIMEPart(rawContent: String, partIndex: Int, contentType: String, encoding: String?) -> Data? {
        // Parse the raw MIME message to find the specific part
        let lines = rawContent.components(separatedBy: .newlines)
        
        // Find headers end
        var headerEndIndex = 0
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headerEndIndex = index
                break
            }
        }
        
        // Check if multipart
        let headerLines = headerEndIndex > 0 ? Array(lines[0..<headerEndIndex]) : []
        let headers = parseMIMEHeaders(headerLines)
        guard let contentTypeHeader = headers["content-type"], contentTypeHeader.lowercased().contains("multipart") else {
            // Single part message - decode directly
            let bodyContent = headerEndIndex < lines.count ? Array(lines[headerEndIndex..<lines.count]).joined(separator: "\n") : ""
            return decodeMIMEContent(bodyContent, encoding: encoding)
        }
        
        // Extract boundary
        guard let boundary = extractMIMEBoundary(from: contentTypeHeader) else {
            return nil
        }
        
        let boundaryMarker = "--\(boundary)"
        let bodyContent = headerEndIndex < lines.count ? Array(lines[headerEndIndex..<lines.count]).joined(separator: "\n") : ""
        let parts = bodyContent.components(separatedBy: boundaryMarker)
        
        // Find the part at the specified index (skip preamble and closing marker)
        var partCount = 0
        for part in parts {
            let trimmed = part.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" || trimmed.hasSuffix("--") {
                continue
            }
            
            // Skip preamble
            if partCount == 0 && !trimmed.contains("Content-Type:") && !trimmed.contains("content-type:") {
                continue
            }
            
            if partCount == partIndex {
                // Found the part - extract content
                let partLines = trimmed.components(separatedBy: "\n")
                var partHeaderEndIndex = 0
                for (lineIndex, line) in partLines.enumerated() {
                    if line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        partHeaderEndIndex = lineIndex
                        break
                    }
                }
                
                let partContent = partHeaderEndIndex < partLines.count ? Array(partLines[partHeaderEndIndex..<partLines.count]).joined(separator: "\n") : ""
                let partHeaders = partHeaderEndIndex > 0 ? parseMIMEHeaders(Array(partLines[0..<partHeaderEndIndex])) : [:]
                let partEncoding = partHeaders["content-transfer-encoding"] ?? encoding
                
                return decodeMIMEContent(partContent, encoding: partEncoding)
            }
            
            partCount += 1
        }
        
        return nil
    }
    
    /// Parse MIME headers from header lines
    private func parseMIMEHeaders(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        var currentHeader: String?
        var currentValue = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            
            if line.first?.isWhitespace == true {
                if currentHeader != nil {
                    currentValue += " " + trimmed
                }
            } else if line.contains(":") {
                if let header = currentHeader {
                    headers[header.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    currentHeader = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    currentValue = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        if let header = currentHeader {
            headers[header.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return headers
    }
    
    /// Extract boundary from Content-Type header
    private func extractMIMEBoundary(from contentType: String) -> String? {
        let pattern = #"boundary\s*=\s*"([^"]+)"|boundary\s*=\s*([^;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        
        let nsString = contentType as NSString
        let matches = regex.matches(in: contentType, range: NSRange(location: 0, length: nsString.length))
        
        if let match = matches.first {
            for i in 1...2 {
                if match.numberOfRanges > i {
                    let range = match.range(at: i)
                    if range.location != NSNotFound {
                        let boundary = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !boundary.isEmpty {
                            return boundary
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Decode MIME content based on transfer encoding
    private func decodeMIMEContent(_ content: String, encoding: String?) -> Data? {
        guard let encoding = encoding?.lowercased() else {
            // Try base64 by default
            let cleaned = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            return Data(base64Encoded: cleaned)
        }
        
        switch encoding {
        case "base64":
            let cleaned = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            return Data(base64Encoded: cleaned)
        case "quoted-printable":
            // Decode quoted-printable to bytes
            let decoded = content
                .replacingOccurrences(of: "=\r\n", with: "")
                .replacingOccurrences(of: "=\n", with: "")
            var result = Data()
            var i = decoded.startIndex
            while i < decoded.endIndex {
                if decoded[i] == "=" && decoded.index(i, offsetBy: 2) < decoded.endIndex {
                    let hexStart = decoded.index(i, offsetBy: 1)
                    let hexEnd = decoded.index(hexStart, offsetBy: 2)
                    if let byte = UInt8(decoded[hexStart..<hexEnd], radix: 16) {
                        result.append(byte)
                        i = hexEnd
                    } else {
                        if let ascii = decoded[i].asciiValue {
                            result.append(ascii)
                        }
                        i = decoded.index(after: i)
                    }
                } else {
                    if let ascii = decoded[i].asciiValue {
                        result.append(ascii)
                    }
                    i = decoded.index(after: i)
                }
            }
            return result
        case "7bit", "8bit", "binary":
            return content.data(using: .utf8)
        default:
            return content.data(using: .utf8)
        }
    }
}
