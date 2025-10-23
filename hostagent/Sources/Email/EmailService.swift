import Foundation
import HavenCore

/// Errors that can occur during email parsing and processing
public enum EmailServiceError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidEmlxFormat(String)
    case parsingFailed(String)
    case attachmentNotFound(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Email file not found: \(path)"
        case .invalidEmlxFormat(let reason):
            return "Invalid .emlx format: \(reason)"
        case .parsingFailed(let reason):
            return "Failed to parse email: \(reason)"
        case .attachmentNotFound(let path):
            return "Attachment not found: \(path)"
        }
    }
}

/// Represents a parsed email message
public struct EmailMessage: Codable {
    public var messageId: String?
    public var subject: String?
    public var from: [String]
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var date: Date?
    public var inReplyTo: String?
    public var references: [String]
    public var listUnsubscribe: String?
    public var bodyPlainText: String?
    public var bodyHTML: String?
    public var attachments: [EmailAttachment]
    public var headers: [String: String]
    public var rawContent: String?
    
    public init(
        messageId: String? = nil,
        subject: String? = nil,
        from: [String] = [],
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        date: Date? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        listUnsubscribe: String? = nil,
        bodyPlainText: String? = nil,
        bodyHTML: String? = nil,
        attachments: [EmailAttachment] = [],
        headers: [String: String] = [:],
        rawContent: String? = nil
    ) {
        self.messageId = messageId
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.date = date
        self.inReplyTo = inReplyTo
        self.references = references
        self.listUnsubscribe = listUnsubscribe
        self.bodyPlainText = bodyPlainText
        self.bodyHTML = bodyHTML
        self.attachments = attachments
        self.headers = headers
        self.rawContent = rawContent
    }
}

/// Represents an email attachment
public struct EmailAttachment: Codable {
    public var filename: String?
    public var mimeType: String?
    public var contentId: String?
    public var size: Int?
    public var partIndex: Int
    
    public init(filename: String? = nil, mimeType: String? = nil, contentId: String? = nil, size: Int? = nil, partIndex: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.contentId = contentId
        self.size = size
        self.partIndex = partIndex
    }
}

/// Email metadata for filtering and classification
public struct EmailMetadata: Codable {
    public var subject: String?
    public var from: [String]
    public var to: [String]
    public var cc: [String]
    public var date: Date?
    public var messageId: String?
    public var inReplyTo: String?
    public var references: [String]
    public var listUnsubscribe: String?
    public var hasAttachments: Bool
    public var attachmentCount: Int
    public var bodyPreview: String?
    public var isNoiseEmail: Bool
    public var intentClassification: IntentClassification?
    
    public init(
        subject: String? = nil,
        from: [String] = [],
        to: [String] = [],
        cc: [String] = [],
        date: Date? = nil,
        messageId: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        listUnsubscribe: String? = nil,
        hasAttachments: Bool = false,
        attachmentCount: Int = 0,
        bodyPreview: String? = nil,
        isNoiseEmail: Bool = false,
        intentClassification: IntentClassification? = nil
    ) {
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.listUnsubscribe = listUnsubscribe
        self.hasAttachments = hasAttachments
        self.attachmentCount = attachmentCount
        self.bodyPreview = bodyPreview
        self.isNoiseEmail = isNoiseEmail
        self.intentClassification = intentClassification
    }
}

/// Email intent classification
public struct IntentClassification: Codable {
    public var primaryIntent: EmailIntent
    public var confidence: Double
    public var secondaryIntents: [EmailIntent]
    public var extractedEntities: [String: String]
    
    public init(primaryIntent: EmailIntent, confidence: Double, secondaryIntents: [EmailIntent] = [], extractedEntities: [String: String] = [:]) {
        self.primaryIntent = primaryIntent
        self.confidence = confidence
        self.secondaryIntents = secondaryIntents
        self.extractedEntities = extractedEntities
    }
}

/// Email intent categories
public enum EmailIntent: String, Codable, CaseIterable {
    case bill
    case receipt
    case orderConfirmation
    case appointment
    case actionRequired
    case notification
    case promotional
    case newsletter
    case personal
    case unknown
}

/// Service for parsing and processing .emlx email files
public actor EmailService {
    private let logger = HavenLogger(category: "email-service")
    
    public init() {}
    
    /// Parse an .emlx file and return a structured EmailMessage
    /// .emlx format: <byte_count>\n<RFC 2822 message>\n<?xml plist?>
    public func parseEmlxFile(at path: URL) throws -> EmailMessage {
        logger.debug("Parsing .emlx file", metadata: ["path": path.path])
        
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw EmailServiceError.fileNotFound(path.path)
        }
        
        let data = try Data(contentsOf: path)
        guard let content = String(data: data, encoding: .utf8) else {
            throw EmailServiceError.invalidEmlxFormat("Unable to decode file as UTF-8")
        }
        
        // Parse .emlx format: first line is byte count, followed by RFC 2822 message
        let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count >= 2 else {
            throw EmailServiceError.invalidEmlxFormat("Missing byte count or message content")
        }
        
        // Skip the byte count line and parse the RFC 2822 message
        let messageContent = String(lines[1])
        
        // Split message and plist (if present)
        let parts = messageContent.components(separatedBy: "\n<?xml")
        let rfc2822Content = parts[0]
        
        // Parse RFC 2822 message
        return try parseRFC2822Message(rfc2822Content)
    }
    
    /// Parse an RFC 2822 email message
    private func parseRFC2822Message(_ content: String) throws -> EmailMessage {
        var message = EmailMessage()
        message.rawContent = content
        
        // Split headers and body
        let parts = content.components(separatedBy: "\n\n")
        guard parts.count >= 1 else {
            throw EmailServiceError.parsingFailed("Invalid message format")
        }
        
        let headerSection = parts[0]
        let bodySection = parts.count > 1 ? parts[1...].joined(separator: "\n\n") : ""
        
        // Parse headers
        var headers: [String: String] = [:]
        var currentHeader: String?
        var currentValue = ""
        
        for line in headerSection.components(separatedBy: "\n") {
            // Continuation line (starts with whitespace)
            if line.first?.isWhitespace == true {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if line.contains(":") {
                // Save previous header
                if let header = currentHeader {
                    headers[header.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                
                // New header
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    currentHeader = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    currentValue = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        // Save last header
        if let header = currentHeader {
            headers[header.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
        }
        
        message.headers = headers
        
        // Extract standard fields
        message.subject = headers["subject"]
        message.messageId = headers["message-id"]
        message.inReplyTo = headers["in-reply-to"]
        message.listUnsubscribe = headers["list-unsubscribe"]
        
        // Parse email addresses
        if let from = headers["from"] {
            message.from = parseEmailAddresses(from)
        }
        if let to = headers["to"] {
            message.to = parseEmailAddresses(to)
        }
        if let cc = headers["cc"] {
            message.cc = parseEmailAddresses(cc)
        }
        if let bcc = headers["bcc"] {
            message.bcc = parseEmailAddresses(bcc)
        }
        
        // Parse references
        if let refs = headers["references"] {
            message.references = refs.split(separator: " ").map { String($0) }
        }
        
        // Parse date
        if let dateStr = headers["date"] {
            message.date = parseEmailDate(dateStr)
        }
        
        // Parse body (simplified - would need full MIME parser for complex messages)
        let contentType = headers["content-type"] ?? ""
        if contentType.contains("text/html") {
            message.bodyHTML = bodySection
        } else {
            message.bodyPlainText = bodySection
        }
        
        return message
    }
    
    /// Parse email addresses from a header value
    private func parseEmailAddresses(_ value: String) -> [String] {
        // Simple extraction - matches email patterns
        let pattern = #"[\w\.-]+@[\w\.-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        
        let nsString = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsString.length))
        
        return matches.compactMap { match in
            nsString.substring(with: match.range)
        }
    }
    
    /// Parse email date header
    private func parseEmailDate(_ dateString: String) -> Date? {
        // RFC 2822 date format: "Thu, 21 Oct 2025 10:30:00 -0400"
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        // Try alternative format without day of week
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: dateString)
    }
    
    /// Extract metadata from an email message
    public func extractEmailMetadata(from message: EmailMessage) -> EmailMetadata {
        var metadata = EmailMetadata(
            subject: message.subject,
            from: message.from,
            to: message.to,
            cc: message.cc,
            date: message.date,
            messageId: message.messageId,
            inReplyTo: message.inReplyTo,
            references: message.references,
            listUnsubscribe: message.listUnsubscribe,
            hasAttachments: !message.attachments.isEmpty,
            attachmentCount: message.attachments.count
        )
        
        // Create body preview (first 200 chars)
        if let plainText = message.bodyPlainText {
            metadata.bodyPreview = String(plainText.prefix(200))
        } else if let html = message.bodyHTML {
            // Strip HTML tags for preview
            let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            metadata.bodyPreview = String(stripped.prefix(200))
        }
        
        // Check if noise email
        metadata.isNoiseEmail = isNoiseEmail(metadata: metadata)
        
        // Classify intent
        metadata.intentClassification = classifyIntent(
            subject: message.subject ?? "",
            body: message.bodyPlainText ?? message.bodyHTML ?? "",
            sender: message.from.first ?? ""
        )
        
        return metadata
    }
    
    /// Resolve the filesystem path for an email attachment
    public func resolveAttachmentPath(for message: EmailMessage, partIndex: Int) -> URL? {
        guard partIndex < message.attachments.count else {
            return nil
        }
        
        // Mail.app stores attachments in ~/Library/Mail/V*/Data/Messages/Attachments/
        // The structure is: <mailbox_id>/<message_id>/<part_index>/<filename>
        // This is a simplified approach - actual implementation would need message context
        
        let attachment = message.attachments[partIndex]
        guard let filename = attachment.filename else {
            return nil
        }
        
        // For now, return nil - caller needs to provide full context
        // In practice, this would use the envelope database or message metadata
        logger.debug("Attachment path resolution requires additional context", metadata: [
            "filename": filename,
            "partIndex": "\(partIndex)"
        ])
        
        return nil
    }
    
    /// Determine if an email is likely noise (promotional, spam, etc.)
    public func isNoiseEmail(metadata: EmailMetadata) -> Bool {
        var score = 0
        
        // Check for List-Unsubscribe header (strong indicator of bulk mail)
        if metadata.listUnsubscribe != nil {
            score += 3
        }
        
        // Check subject for promotional keywords
        if let subject = metadata.subject?.lowercased() {
            let promotionalKeywords = ["sale", "offer", "discount", "deal", "promo", "newsletter", "subscribe", "unsubscribe"]
            for keyword in promotionalKeywords {
                if subject.contains(keyword) {
                    score += 2
                    break
                }
            }
        }
        
        // Check sender domain for common bulk mail patterns
        if let sender = metadata.from.first?.lowercased() {
            let bulkDomains = ["noreply", "no-reply", "donotreply", "mailer", "newsletter"]
            for pattern in bulkDomains {
                if sender.contains(pattern) {
                    score += 2
                    break
                }
            }
        }
        
        // Threshold: score >= 2 is likely noise (lowered from 3 for better sensitivity)
        return score >= 2
    }
    
    /// Classify the intent of an email message
    public func classifyIntent(subject: String, body: String, sender: String) -> IntentClassification {
        let subjectLower = subject.lowercased()
        let bodyLower = body.lowercased()
        let senderLower = sender.lowercased()
        
        var primaryIntent: EmailIntent = .unknown
        var confidence: Double = 0.3
        var secondaryIntents: [EmailIntent] = []
        var entities: [String: String] = [:]
        
        // Bill detection
        if subjectLower.contains("bill") || subjectLower.contains("invoice") || subjectLower.contains("statement") {
            primaryIntent = .bill
            confidence = 0.8
            
            // Extract potential amount
            if let match = bodyLower.range(of: #"\$[\d,]+\.?\d*"#, options: .regularExpression) {
                entities["amount"] = String(body[match])
            }
        }
        // Receipt detection
        else if subjectLower.contains("receipt") || subjectLower.contains("payment confirmation") {
            primaryIntent = .receipt
            confidence = 0.85
            
            // Extract order number
            if let match = bodyLower.range(of: #"order[# ]+[\w\d-]+"#, options: .regularExpression) {
                entities["order_number"] = String(body[match])
            }
        }
        // Order confirmation
        else if subjectLower.contains("order") && (subjectLower.contains("confirm") || subjectLower.contains("shipped")) {
            primaryIntent = .orderConfirmation
            confidence = 0.8
        }
        // Appointment
        else if subjectLower.contains("appointment") || subjectLower.contains("meeting") || bodyLower.contains("calendar invite") {
            primaryIntent = .appointment
            confidence = 0.75
            secondaryIntents.append(.actionRequired)
        }
        // Action required
        else if subjectLower.contains("action required") || subjectLower.contains("attention needed") || subjectLower.contains("urgent") {
            primaryIntent = .actionRequired
            confidence = 0.7
        }
        // Promotional
        else if subjectLower.contains("sale") || subjectLower.contains("offer") || subjectLower.contains("discount") {
            primaryIntent = .promotional
            confidence = 0.8
        }
        // Newsletter
        else if subjectLower.contains("newsletter") || senderLower.contains("newsletter") {
            primaryIntent = .newsletter
            confidence = 0.85
        }
        
        return IntentClassification(
            primaryIntent: primaryIntent,
            confidence: confidence,
            secondaryIntents: secondaryIntents,
            extractedEntities: entities
        )
    }
    
    /// Redact PII from text (email addresses, phone numbers, account numbers)
    public func redactPII(in text: String) -> String {
        var redacted = text
        
        // Redact email addresses
        redacted = redacted.replacingOccurrences(
            of: #"[\w\.-]+@[\w\.-]+"#,
            with: "[EMAIL_REDACTED]",
            options: .regularExpression
        )
        
        // Redact phone numbers (various formats)
        let phonePatterns = [
            #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#,  // 555-123-4567 or 5551234567
            #"\(\d{3}\)\s*\d{3}[-.]?\d{4}"#,     // (555) 123-4567
            #"\+\d{1,3}\s*\d{3}[-.]?\d{3}[-.]?\d{4}"#  // +1 555-123-4567
        ]
        
        for pattern in phonePatterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[PHONE_REDACTED]",
                options: .regularExpression
            )
        }
        
        // Redact account numbers (8+ digits)
        redacted = redacted.replacingOccurrences(
            of: #"\b\d{8,}\b"#,
            with: "[ACCOUNT_REDACTED]",
            options: .regularExpression
        )
        
        // Redact SSN patterns
        redacted = redacted.replacingOccurrences(
            of: #"\b\d{3}-\d{2}-\d{4}\b"#,
            with: "[SSN_REDACTED]",
            options: .regularExpression
        )
        
        return redacted
    }
}
