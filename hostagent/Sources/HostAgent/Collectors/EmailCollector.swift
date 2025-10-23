import Foundation
import CryptoKit
import HavenCore
import Email

public protocol EmailCollecting: Sendable {
    func buildDocumentPayload(
        email: EmailMessage,
        intent: IntentClassification?,
        relevance: Double?
    ) async throws -> EmailDocumentPayload

    func submitEmailDocument(_ payload: EmailDocumentPayload) async throws -> GatewaySubmissionResponse

    func submitEmailAttachment(
        fileURL: URL,
        attachment: EmailAttachment,
        messageId: String?,
        intent: IntentClassification?,
        relevance: Double?,
        enrichment: EmailAttachmentEnrichment?
    ) async throws -> GatewayFileSubmissionResponse
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
    public var title: String?
    public var participants: [EmailDocumentPerson]
    public var metadata: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case sourceType = "source_type"
        case title
        case participants
        case metadata
    }
}

public struct EmailDocumentPayload: Codable, Equatable {
    public var sourceType: String
    public var sourceId: String
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
    
    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case sourceId = "source_id"
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

public struct GatewaySubmissionResponse: Codable, Equatable {
    public var submissionId: String
    public var docId: String
    public var externalId: String
    public var status: String
    public var threadId: String?
    public var fileIds: [String]
    public var duplicate: Bool
    public var totalChunks: Int
    
    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case docId = "doc_id"
        case externalId = "external_id"
        case status
        case threadId = "thread_id"
        case fileIds = "file_ids"
        case duplicate
        case totalChunks = "total_chunks"
    }
}

public struct GatewayFileSubmissionResponse: Codable, Equatable {
    public var submissionId: String
    public var docId: String
    public var externalId: String
    public var status: String
    public var threadId: String?
    public var fileIds: [String]
    public var duplicate: Bool
    public var totalChunks: Int
    public var fileSha256: String
    public var objectKey: String
    public var extractionStatus: String
    
    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case docId = "doc_id"
        case externalId = "external_id"
        case status
        case threadId = "thread_id"
        case fileIds = "file_ids"
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
    
    public init(gatewayConfig: GatewayConfig, authToken: String, session: URLSession? = nil, emailService: EmailService? = nil, logger: HavenLogger = HavenLogger(category: "email-collector")) {
        self.gatewayClient = GatewaySubmissionClient(config: gatewayConfig, authToken: authToken, session: session)
        if let providedService = emailService {
            self.emailService = providedService
        } else {
            self.emailService = EmailService()
        }
        self.logger = logger
    }
    
    public func buildDocumentPayload(
        email: EmailMessage,
        intent: IntentClassification? = nil,
        relevance: Double? = nil
    ) async throws -> EmailDocumentPayload {
        let messageId = normalizeMessageId(email.messageId)
        let sourceId = buildSourceId(messageId: messageId, email: email)
        
        let rawBody = selectBody(from: email)
        let normalizedBody = normalizeIngestText(rawBody)
        guard !normalizedBody.isEmpty else {
            throw EmailCollectorError.emptyContent
        }
        
        let textHash = sha256Hex(of: normalizedBody)
        let redacted = await emailService.redactPII(in: normalizedBody)
        
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
            relevanceScore: relevance
        )
        
        let people = buildPeople(from: email)
        let threadPayload = buildThreadPayload(email: email, people: people)
        let threadId: UUID?
        if let externalId = threadPayload?.externalId {
            threadId = deterministicUUID(from: externalId)
        } else {
            threadId = nil
        }
        
        return EmailDocumentPayload(
            sourceType: "email_local",
            sourceId: sourceId,
            title: email.subject,
            canonicalUri: messageId.map { "message://\($0)" },
            content: content,
            metadata: metadata,
            contentTimestamp: email.date,
            contentTimestampType: "received",
            people: people,
            threadId: threadId,
            thread: threadPayload,
            intent: intentPayload,
            relevanceScore: relevance
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
    
    public func submitEmailAttachment(
        fileURL: URL,
        attachment: EmailAttachment,
        messageId: String?,
        intent: IntentClassification? = nil,
        relevance: Double? = nil,
        enrichment: EmailAttachmentEnrichment? = nil
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
        let metaIntent = intent.map { classification in
            EmailIntentPayload(
                primaryIntent: classification.primaryIntent.rawValue,
                confidence: classification.confidence,
                secondaryIntents: classification.secondaryIntents.map(\.rawValue),
                extractedEntities: classification.extractedEntities
            )
        }
        
        let meta = EmailAttachmentMeta(
            source: "email_local",
            path: "email/\(pathComponent)/\(filename)",
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
    
    private func buildSourceId(messageId: String?, email: EmailMessage) -> String {
        if let messageId, !messageId.isEmpty {
            return "email:\(messageId)"
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
        return "email:\(sha256Hex(of: seed))"
    }
    
    private func selectBody(from email: EmailMessage) -> String {
        if let body = email.bodyPlainText, !body.isEmpty {
            return body
        }
        if let html = email.bodyHTML {
            return stripHTML(html)
        }
        return email.rawContent ?? ""
    }
    
    private func normalizeIngestText(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func stripHTML(_ html: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(location: 0, length: html.utf16.count)
        let stripped = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: " ")
        return stripped.replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
}
