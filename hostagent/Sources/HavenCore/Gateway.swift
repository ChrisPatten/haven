import Foundation

/// Gateway client for posting ingestion events
public actor GatewayClient {
    private let baseUrl: String
    private let ingestPath: String
    private let authToken: String
    private let timeout: TimeInterval
    private let logger = HavenLogger(category: "gateway")
    
    public init(config: GatewayConfig, authToken: String) {
        self.baseUrl = config.baseUrl
        self.ingestPath = config.ingestPath
        self.authToken = authToken
        self.timeout = TimeInterval(config.timeout)
    }
    
    public func ingest(events: [IngestEvent]) async throws {
        let url = URL(string: baseUrl + ingestPath)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(events)
        
        logger.info("Posting \(events.count) events to gateway")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Gateway returned \(httpResponse.statusCode): \(body)")
            throw GatewayError.httpError(httpResponse.statusCode, body)
        }
        
        logger.info("Successfully posted \(events.count) events")
    }
    
    /// Post to an admin endpoint with JSON payload
    public func postAdmin(path: String, payload: [String: Any]) async -> (statusCode: Int, body: String) {
        let urlString = baseUrl + path
        guard let url = URL(string: urlString) else {
            logger.error("Invalid URL for admin endpoint", metadata: ["path": path])
            return (statusCode: -1, body: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            
            logger.info("Admin endpoint response", metadata: [
                "path": path,
                "status": String(statusCode)
            ])
            
            return (statusCode: statusCode, body: body)
        } catch {
            logger.error("Admin endpoint request failed", metadata: [
                "path": path,
                "error": error.localizedDescription
            ])
            return (statusCode: -1, body: error.localizedDescription)
        }
    }
}

public enum GatewayError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from gateway"
        case .httpError(let code, let body):
            return "Gateway HTTP error \(code): \(body)"
        }
    }
}

/// Ingest event sent to gateway
public struct IngestEvent: Codable {
    public let sourceType: String
    public let sourceId: String
    public let content: String
    public let chunks: [IngestChunk]
    public let metadata: IngestMetadata
    
    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case sourceId = "source_id"
        case content
        case chunks
        case metadata
    }
    
    public init(sourceType: String, sourceId: String, content: String, chunks: [IngestChunk], metadata: IngestMetadata) {
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.content = content
        self.chunks = chunks
        self.metadata = metadata
    }
}

public struct IngestChunk: Codable {
    public let chunkId: String
    public let type: String
    public let text: String
    public let meta: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id"
        case type
        case text
        case meta
    }
    
    public init(chunkId: String, type: String, text: String, meta: [String: AnyCodable]? = nil) {
        self.chunkId = chunkId
        self.type = type
        self.text = text
        self.meta = meta
    }
}

public struct IngestMetadata: Codable {
    public let thread: ThreadMetadata?
    public let message: MessageMetadata?
    public let file: FileMetadata?
    
    public init(thread: ThreadMetadata? = nil, message: MessageMetadata? = nil, file: FileMetadata? = nil) {
        self.thread = thread
        self.message = message
        self.file = file
    }
}

public struct ThreadMetadata: Codable {
    public let chatGuid: String
    public let participants: [String]
    public let service: String
    
    enum CodingKeys: String, CodingKey {
        case chatGuid = "chat_guid"
        case participants
        case service
    }
    
    public init(chatGuid: String, participants: [String], service: String) {
        self.chatGuid = chatGuid
        self.participants = participants
        self.service = service
    }
}

public struct MessageMetadata: Codable {
    public let rowid: Int64
    public let date: Date
    public let isFromMe: Bool
    public let handle: HandleMetadata
    public let attachments: [AttachmentMetadata]
    
    enum CodingKeys: String, CodingKey {
        case rowid
        case date
        case isFromMe = "is_from_me"
        case handle
        case attachments
    }
    
    public init(rowid: Int64, date: Date, isFromMe: Bool, handle: HandleMetadata, attachments: [AttachmentMetadata]) {
        self.rowid = rowid
        self.date = date
        self.isFromMe = isFromMe
        self.handle = handle
        self.attachments = attachments
    }
}

public struct HandleMetadata: Codable {
    public let id: String
    public let phone: String?
    public let email: String?
    
    public init(id: String, phone: String? = nil, email: String? = nil) {
        self.id = id
        self.phone = phone
        self.email = email
    }
}

public struct AttachmentMetadata: Codable {
    public let id: String
    public let uti: String?
    public let path: String?
    public let sha256: String?
    
    public init(id: String, uti: String? = nil, path: String? = nil, sha256: String? = nil) {
        self.id = id
        self.uti = uti
        self.path = path
        self.sha256 = sha256
    }
}

public struct FileMetadata: Codable {
    public let path: String
    public let size: Int64
    public let mtime: Date
    public let sha256: String
    
    public init(path: String, size: Int64, mtime: Date, sha256: String) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.sha256 = sha256
    }
}

/// Type-erased codable value for dynamic metadata
public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
