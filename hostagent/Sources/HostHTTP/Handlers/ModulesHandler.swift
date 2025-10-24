import Foundation
import HavenCore

/// Handler for GET /v1/modules and PUT /v1/modules/{name}
public struct ModulesHandler {
    private let config: HavenConfig
    private let configLoader: ConfigLoader
    private let logger = HavenLogger(category: "modules")
    
    public init(config: HavenConfig, configLoader: ConfigLoader) {
        self.config = config
        self.configLoader = configLoader
    }
    
    public func handleList(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        let modules = ModulesListResponse(
            imessage: IMessageModuleInfo(
                enabled: config.modules.imessage.enabled,
                config: IMessageModuleConfig(
                    batchSize: config.modules.imessage.batchSize,
                    ocrEnabled: config.modules.imessage.ocrEnabled
                )
            ),
            ocr: OCRModuleInfo(
                enabled: config.modules.ocr.enabled,
                config: OCRModuleConfigInfo(
                    languages: config.modules.ocr.languages,
                    timeoutMs: config.modules.ocr.timeoutMs
                )
            ),
            fswatch: FSWatchModuleInfo(
                enabled: config.modules.fswatch.enabled,
                config: FSWatchModuleConfigInfo(
                    watches: config.modules.fswatch.watches.map { watch in
                        WatchInfo(
                            id: watch.id,
                            path: watch.path,
                            glob: watch.glob ?? "",
                            target: watch.target,
                            handoff: watch.handoff
                        )
                    }
                )
            ),
            contacts: SimpleModuleInfo(enabled: config.modules.contacts.enabled),
            calendar: SimpleModuleInfo(enabled: config.modules.calendar.enabled),
            reminders: SimpleModuleInfo(enabled: config.modules.reminders.enabled),
            mail: SimpleModuleInfo(enabled: config.modules.mail.enabled),
            mailImap: SimpleModuleInfo(enabled: config.modules.mailImap.enabled),
            notes: SimpleModuleInfo(enabled: config.modules.notes.enabled),
            face: SimpleModuleInfo(enabled: config.modules.face.enabled)
        )
        
        return HTTPResponse.ok(json: modules)
    }
    
    public func handleUpdate(request: HTTPRequest, context: RequestContext, moduleName: String) async -> HTTPResponse {
        // Parse request body
        guard let body = request.body else {
            return HTTPResponse.badRequest(message: "Missing request body")
        }
        
        struct UpdateRequest: Codable {
            let enabled: Bool?
            let config: [String: AnyCodable]?
        }
        
        do {
            let updateReq = try JSONDecoder().decode(UpdateRequest.self, from: body)
            
            // TODO: Actually update the config and persist it
            // For now, just return success
            
            logger.info("Module config update requested", metadata: [
                "module": moduleName,
                "enabled": updateReq.enabled as Any,
                "request_id": context.requestId
            ])
            
            return HTTPResponse.ok(json: [
                "message": "Module configuration updated (not yet persisted)",
                "module": moduleName
            ])
            
        } catch {
            logger.error("Failed to parse update request", error: error)
            return HTTPResponse.badRequest(message: "Invalid request body")
        }
    }
}

// MARK: - Response Models

struct ModulesListResponse: Codable {
    let imessage: IMessageModuleInfo
    let ocr: OCRModuleInfo
    let fswatch: FSWatchModuleInfo
    let contacts: SimpleModuleInfo
    let calendar: SimpleModuleInfo
    let reminders: SimpleModuleInfo
    let mail: SimpleModuleInfo
    let mailImap: SimpleModuleInfo
    let notes: SimpleModuleInfo
    let face: SimpleModuleInfo
    
    enum CodingKeys: String, CodingKey {
        case imessage
        case ocr
        case fswatch
        case contacts
        case calendar
        case reminders
        case mail
        case mailImap = "mail_imap"
        case notes
        case face
    }
}

struct IMessageModuleInfo: Codable {
    let enabled: Bool
    let config: IMessageModuleConfig
}

struct IMessageModuleConfig: Codable {
    let batchSize: Int
    let ocrEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
        case batchSize = "batch_size"
        case ocrEnabled = "ocr_enabled"
    }
}

struct OCRModuleInfo: Codable {
    let enabled: Bool
    let config: OCRModuleConfigInfo
}

struct OCRModuleConfigInfo: Codable {
    let languages: [String]
    let timeoutMs: Int
    
    enum CodingKeys: String, CodingKey {
        case languages
        case timeoutMs = "timeout_ms"
    }
}

struct FSWatchModuleInfo: Codable {
    let enabled: Bool
    let config: FSWatchModuleConfigInfo
}

struct FSWatchModuleConfigInfo: Codable {
    let watches: [WatchInfo]
}

struct WatchInfo: Codable {
    let id: String
    let path: String
    let glob: String
    let target: String
    let handoff: String
}

struct SimpleModuleInfo: Codable {
    let enabled: Bool
}

// MARK: - Helper Types

// Helper for decoding arbitrary JSON
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
