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
        let modules = getModuleSummaries()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let jsonData = try encoder.encode(modules)
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: jsonData
            )
        } catch {
            logger.error("Failed to encode modules response", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "Failed to encode response")
        }
    }
    
    // MARK: - Direct Swift API
    
    /// Direct Swift API for getting module summaries
    /// Replaces HTTP-based handleList for in-app integration
    public func getModuleSummaries() -> ModulesListResponse {
        return ModulesListResponse(
            imessage: IMessageModuleInfo(
                enabled: config.modules.imessage.enabled,
                config: IMessageModuleConfig(
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
            mail: SimpleModuleInfo(enabled: config.modules.mail.enabled),
            face: SimpleModuleInfo(enabled: config.modules.face.enabled)
        )
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

public struct ModulesListResponse: Codable {
    public let imessage: IMessageModuleInfo
    public let ocr: OCRModuleInfo
    public let fswatch: FSWatchModuleInfo
    public let contacts: SimpleModuleInfo
    public let mail: SimpleModuleInfo
    public let face: SimpleModuleInfo
    
    public init(imessage: IMessageModuleInfo, ocr: OCRModuleInfo, fswatch: FSWatchModuleInfo, contacts: SimpleModuleInfo, mail: SimpleModuleInfo, face: SimpleModuleInfo) {
        self.imessage = imessage
        self.ocr = ocr
        self.fswatch = fswatch
        self.contacts = contacts
        self.mail = mail
        self.face = face
    }
    
    enum CodingKeys: String, CodingKey {
        case imessage
        case ocr
        case fswatch
        case contacts
        case mail
        case face
    }
}

public struct IMessageModuleInfo: Codable {
    public let enabled: Bool
    public let config: IMessageModuleConfig
    
    public init(enabled: Bool, config: IMessageModuleConfig) {
        self.enabled = enabled
        self.config = config
    }
}

public struct IMessageModuleConfig: Codable {
    public let ocrEnabled: Bool
    
    public init(ocrEnabled: Bool) {
        self.ocrEnabled = ocrEnabled
    }
    
    enum CodingKeys: String, CodingKey {
        case ocrEnabled = "ocr_enabled"
    }
}

public struct OCRModuleInfo: Codable {
    public let enabled: Bool
    public let config: OCRModuleConfigInfo
    
    public init(enabled: Bool, config: OCRModuleConfigInfo) {
        self.enabled = enabled
        self.config = config
    }
}

public struct OCRModuleConfigInfo: Codable {
    public let languages: [String]
    public let timeoutMs: Int
    
    public init(languages: [String], timeoutMs: Int) {
        self.languages = languages
        self.timeoutMs = timeoutMs
    }
    
    enum CodingKeys: String, CodingKey {
        case languages
        case timeoutMs = "timeout_ms"
    }
}

public struct FSWatchModuleInfo: Codable {
    public let enabled: Bool
    public let config: FSWatchModuleConfigInfo
    
    public init(enabled: Bool, config: FSWatchModuleConfigInfo) {
        self.enabled = enabled
        self.config = config
    }
}

public struct FSWatchModuleConfigInfo: Codable {
    public let watches: [WatchInfo]
    
    public init(watches: [WatchInfo]) {
        self.watches = watches
    }
}

public struct WatchInfo: Codable {
    public let id: String
    public let path: String
    public let glob: String
    public let target: String
    public let handoff: String
    
    public init(id: String, path: String, glob: String, target: String, handoff: String) {
        self.id = id
        self.path = path
        self.glob = glob
        self.target = target
        self.handoff = handoff
    }
}

public struct SimpleModuleInfo: Codable {
    public let enabled: Bool
    
    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

// MARK: - Helper Types

// Helper for decoding arbitrary JSON
// Note: This is a local helper for ModulesHandler only.
// For public APIs, use HavenCore.AnyCodable instead.
private struct AnyCodable: Codable {
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
