import Foundation
import HavenCore
import Contacts

/// Handler for GET /v1/capabilities
public struct CapabilitiesHandler {
    private let config: HavenConfig
    private let logger = HavenLogger(category: "capabilities")
    
    public init(config: HavenConfig) {
        self.config = config
    }
    
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        let capabilities = getCapabilities()
        
        logger.debug("Capabilities check completed", metadata: [
            "request_id": context.requestId
        ])
        
        return HTTPResponse.ok(json: capabilities)
    }
    
    // MARK: - Direct Swift API
    
    /// Direct Swift API for getting capabilities
    /// Replaces HTTP-based handle for in-app integration
    public func getCapabilities() -> CapabilitiesResponse {
        return buildCapabilities()
    }
    
    private func buildCapabilities() -> CapabilitiesResponse {
        return CapabilitiesResponse(
            modules: ModulesCapabilities(
                imessage: ModuleCapability(
                    enabled: config.modules.imessage.enabled,
                    permissions: ["fda": checkFullDiskAccess()],
                    config: IMessageConfigInfo(
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
                    permissions: ["contacts": checkContactsPermission()],
                    status: config.modules.contacts.enabled ? "active" : "stub"
                ),
                calendar: StubModuleCapability(
                    enabled: false,
                    permissions: [:],
                    status: "stub"
                ),
                reminders: StubModuleCapability(
                    enabled: false,
                    permissions: [:],
                    status: "stub"
                ),
                mail: StubModuleCapability(
                    enabled: config.modules.mail.enabled,
                    permissions: [:],
                    status: "stub"
                ),
                notes: StubModuleCapability(
                    enabled: false,
                    permissions: [:],
                    status: "stub"
                ),
                face: FaceModuleCapability(
                    enabled: config.modules.face.enabled,
                    minFaceSize: config.modules.face.minFaceSize,
                    minConfidence: config.modules.face.minConfidence,
                    includeLandmarks: config.modules.face.includeLandmarks
                )
            )
        )
    }
    
    private func checkFullDiskAccess() -> Bool {
        // Check if we can read the Messages database
        let messagesPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        return FileManager.default.isReadableFile(atPath: messagesPath)
    }
    
    private func checkContactsPermission() -> Bool {
        // Check Contacts authorization status
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        return authStatus == .authorized
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
    let face: FaceModuleCapability
    
    enum CodingKeys: String, CodingKey {
        case imessage
        case ocr
        case fswatch
        case contacts
        case calendar
        case reminders
        case mail
        case notes
        case face
    }
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

struct FaceModuleCapability: Codable {
    let enabled: Bool
    let minFaceSize: Double
    let minConfidence: Double
    let includeLandmarks: Bool
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case minFaceSize = "min_face_size"
        case minConfidence = "min_confidence"
        case includeLandmarks = "include_landmarks"
    }
}

struct IMessageConfigInfo: Codable {
    let ocrEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
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
