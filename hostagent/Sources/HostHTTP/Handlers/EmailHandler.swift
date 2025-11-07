import Foundation
import HavenCore
import Email

/// Handler for email utility endpoints
public actor EmailHandler {
    private let emailService: EmailService
    private let config: HavenConfig
    private let logger = HavenLogger(category: "email-handler")
    
    public init(config: HavenConfig) {
        self.config = config
        self.emailService = EmailService()
    }
    
    /// Handle POST /v1/email/parse
    /// Parse an .emlx file and return structured email data
    public func handleParse(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        
        // Parse request body
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let path = json["path"] as? String else {
            logger.warning("Invalid parse request - missing path")
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Missing required field: path"}"#.data(using: .utf8)
            )
        }
        
        // Expand tilde in path
        let expandedPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        
        do {
            let message = try await emailService.parseEmlxFile(at: url)
            
            // Encode response
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let responseData = try encoder.encode(message)
            
            logger.info("Successfully parsed email", metadata: [
                "path": expandedPath,
                "subject": message.subject ?? "no subject",
                "from": message.from.joined(separator: ", ")
            ])
            
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
            )
        } catch {
            logger.error("Failed to parse email", metadata: [
                "path": expandedPath,
                "error": "\(error)"
            ])
            
            let errorMessage = [
                "error": "Failed to parse email",
                "details": error.localizedDescription
            ]
            let errorData = try? JSONSerialization.data(withJSONObject: errorMessage)
            
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: errorData
            )
        }
    }
    
    /// Handle POST /v1/email/metadata
    /// Extract metadata from a parsed email message
    public func handleMetadata(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.mail.enabled else {
            return HTTPResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Email module is disabled"}"#.data(using: .utf8)
            )
        }
        
        // Parse request body
        guard let body = request.body else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Missing request body"}"#.data(using: .utf8)
            )
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let message = try decoder.decode(EmailMessage.self, from: body)
            
            let metadata = await emailService.extractEmailMetadata(from: message)
            
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let responseData = try encoder.encode(metadata)
            
            logger.info("Extracted email metadata", metadata: [
                "subject": message.subject ?? "no subject",
                "is_noise": "\(metadata.isNoiseEmail)",
                "intent": metadata.intentClassification?.primaryIntent.rawValue ?? "unknown"
            ])
            
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
            )
        } catch {
            logger.error("Failed to extract metadata", metadata: ["error": "\(error)"])
            
            let errorMessage = [
                "error": "Failed to extract metadata",
                "details": error.localizedDescription
            ]
            let errorData = try? JSONSerialization.data(withJSONObject: errorMessage)
            
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: errorData
            )
        }
    }
    
    /// Handle POST /v1/email/classify-intent
    /// Classify the intent of email text
    public func handleClassifyIntent(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.mail.enabled else {
            return HTTPResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Email module is disabled"}"#.data(using: .utf8)
            )
        }
        
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let subject = json["subject"] as? String,
              let bodyText = json["body"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Missing required fields: subject, body"}"#.data(using: .utf8)
            )
        }
        
        let sender = json["sender"] as? String ?? ""
        
        let classification = await emailService.classifyIntent(
            subject: subject,
            body: bodyText,
            sender: sender
        )
        
        do {
            let encoder = JSONEncoder()
            let responseData = try encoder.encode(classification)
            
            logger.info("Classified email intent", metadata: [
                "intent": classification.primaryIntent.rawValue,
                "confidence": "\(classification.confidence)"
            ])
            
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
            )
        } catch {
            let errorMessage = ["error": "Failed to encode classification"]
            let errorData = try? JSONSerialization.data(withJSONObject: errorMessage)
            
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: errorData
            )
        }
    }
    
    /// Handle POST /v1/email/redact-pii
    /// Redact PII from text
    public func handleRedactPII(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.mail.enabled else {
            return HTTPResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Email module is disabled"}"#.data(using: .utf8)
            )
        }
        
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = json["text"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Missing required field: text"}"#.data(using: .utf8)
            )
        }
        
        let redactedText = await emailService.redactPII(in: text)
        
        let response = ["redacted_text": redactedText]
        if let responseData = try? JSONSerialization.data(withJSONObject: response) {
            logger.debug("Redacted PII from text", metadata: [
                "original_length": "\(text.count)",
                "redacted_length": "\(redactedText.count)"
            ])
            
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
            )
        } else {
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Failed to encode response"}"#.data(using: .utf8)
            )
        }
    }
    
    /// Handle POST /v1/email/is-noise
    /// Check if email metadata indicates noise/promotional content
    public func handleIsNoise(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.mail.enabled else {
            return HTTPResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Email module is disabled"}"#.data(using: .utf8)
            )
        }
        
        guard let body = request.body else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Missing request body"}"#.data(using: .utf8)
            )
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(EmailMetadata.self, from: body)
            
            let isNoise = await emailService.isNoiseEmail(metadata: metadata)
            
            let response = ["is_noise": isNoise]
            let responseData = try JSONSerialization.data(withJSONObject: response)
            
            logger.debug("Checked if email is noise", metadata: [
                "is_noise": "\(isNoise)",
                "subject": metadata.subject ?? "no subject"
            ])
            
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
            )
        } catch {
            let errorMessage = [
                "error": "Failed to process request",
                "details": error.localizedDescription
            ]
            let errorData = try? JSONSerialization.data(withJSONObject: errorMessage)
            
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: errorData
            )
        }
    }
}
