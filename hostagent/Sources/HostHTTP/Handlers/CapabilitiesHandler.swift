import Foundation
import HavenCore

/// Handler for GET /v1/capabilities
public struct CapabilitiesHandler {
    private let config: HavenConfig
    private let logger = HavenLogger(category: "capabilities")
    
    public init(config: HavenConfig) {
        self.config = config
    }
    
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        let capabilities = buildCapabilities()
        
        logger.debug("Capabilities check completed", metadata: [
            "request_id": context.requestId
        ])
        
        return HTTPResponse.ok(json: capabilities)
    }
    
    private func buildCapabilities() -> CapabilitiesResponse {
        return CapabilitiesResponse(
            modules: ModulesCapabilities(
                imessage: ModuleCapability(
                    enabled: config.modules.imessage.enabled,
                    permissions: ["fda": checkFullDiskAccess()],
                    config: IMessageConfigInfo(
                        batchSize: config.modules.imessage.batchSize,
                        ocrEnabled: config.modules.imessage.ocrEnabled
                    )
                ),
                ocr: ModuleCapability(
                    enabled: config.modules.ocr.enabled,
                    permissions: [:],
                    config: OCRConfigInfo(
                        languages: config.modules.ocr.languages,
                        timeoutMs: config.modules.ocr.timeoutMs
                    )
                ),
                fswatch: ModuleCapability(
                    enabled: config.modules.fswatch.enabled,
                    permissions: [:],
                    config: FSWatchConfigInfo(
                        watchesCount: config.modules.fswatch.watches.count
                    )
                ),
                contacts: StubModuleCapability(
                    enabled: config.modules.contacts.enabled,
                    permissions: [:],
                    status: "stub"
                ),
                calendar: StubModuleCapability(
                    enabled: config.modules.calendar.enabled,
                    permissions: [:],
                    status: "stub"
                ),
                reminders: StubModuleCapability(
                    enabled: config.modules.reminders.enabled,
                    permissions: [:],
                    status: "stub"
                ),
                mail: StubModuleCapability(
                    enabled: config.modules.mail.enabled,
                    permissions: [:],
                    status: "stub"
                ),
                notes: StubModuleCapability(
                    enabled: config.modules.notes.enabled,
                    permissions: [:],
                    status: "stub"
                ),
                faces: StubModuleCapability(
                    enabled: config.modules.faces.enabled,
                    permissions: [:],
                    status: "stub"
                )
            )
        )
    }
    
    private func checkFullDiskAccess() -> Bool {
        // Check if we can read the Messages database
        let messagesPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        return FileManager.default.isReadableFile(atPath: messagesPath)
    }
}

struct CapabilitiesResponse: Codable {
    let modules: ModulesCapabilities
}

struct ModulesCapabilities: Codable {
    let imessage: ModuleCapability<IMessageConfigInfo>
    let ocr: ModuleCapability<OCRConfigInfo>
    let fswatch: ModuleCapability<FSWatchConfigInfo>
    let contacts: StubModuleCapability
    let calendar: StubModuleCapability
    let reminders: StubModuleCapability
    let mail: StubModuleCapability
    let notes: StubModuleCapability
    let faces: StubModuleCapability
}

struct ModuleCapability<T: Codable>: Codable {
    let enabled: Bool
    let permissions: [String: Bool]
    let config: T
}

struct StubModuleCapability: Codable {
    let enabled: Bool
    let permissions: [String: Bool]
    let status: String
}

struct IMessageConfigInfo: Codable {
    let batchSize: Int
    let ocrEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
        case batchSize = "batch_size"
        case ocrEnabled = "ocr_enabled"
    }
}

struct OCRConfigInfo: Codable {
    let languages: [String]
    let timeoutMs: Int
    
    enum CodingKeys: String, CodingKey {
        case languages
        case timeoutMs = "timeout_ms"
    }
}

struct FSWatchConfigInfo: Codable {
    let watchesCount: Int
    
    enum CodingKeys: String, CodingKey {
        case watchesCount = "watches_count"
    }
}

