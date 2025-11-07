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
        // Use homeDirectoryForCurrentUser for sandboxed apps (returns actual home, not container)
        let messagesPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
        return FileManager.default.isReadableFile(atPath: messagesPath)
    }
    
    private func checkContactsPermission() -> Bool {
        // Check Contacts authorization status
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        return authStatus == .authorized
    }
}

public struct CapabilitiesResponse: Codable {
    public let modules: ModulesCapabilities
    
    public init(modules: ModulesCapabilities) {
        self.modules = modules
    }
}

public struct ModulesCapabilities: Codable {
    public let imessage: ModuleCapability<IMessageConfigInfo>
    public let ocr: ModuleCapability<OCRConfigInfo>
    public let fswatch: ModuleCapability<FSWatchConfigInfo>
    public let contacts: StubModuleCapability
    public let calendar: StubModuleCapability
    public let reminders: StubModuleCapability
    public let mail: StubModuleCapability
    public let notes: StubModuleCapability
    public let face: FaceModuleCapability
    
    public init(imessage: ModuleCapability<IMessageConfigInfo>, ocr: ModuleCapability<OCRConfigInfo>, fswatch: ModuleCapability<FSWatchConfigInfo>, contacts: StubModuleCapability, calendar: StubModuleCapability, reminders: StubModuleCapability, mail: StubModuleCapability, notes: StubModuleCapability, face: FaceModuleCapability) {
        self.imessage = imessage
        self.ocr = ocr
        self.fswatch = fswatch
        self.contacts = contacts
        self.calendar = calendar
        self.reminders = reminders
        self.mail = mail
        self.notes = notes
        self.face = face
    }
    
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

public struct ModuleCapability<T: Codable>: Codable {
    public let enabled: Bool
    public let permissions: [String: Bool]
    public let config: T
    
    public init(enabled: Bool, permissions: [String: Bool], config: T) {
        self.enabled = enabled
        self.permissions = permissions
        self.config = config
    }
}

public struct StubModuleCapability: Codable {
    public let enabled: Bool
    public let permissions: [String: Bool]
    public let status: String
    
    public init(enabled: Bool, permissions: [String: Bool], status: String) {
        self.enabled = enabled
        self.permissions = permissions
        self.status = status
    }
}

public struct FaceModuleCapability: Codable {
    public let enabled: Bool
    public let minFaceSize: Double
    public let minConfidence: Double
    public let includeLandmarks: Bool
    
    public init(enabled: Bool, minFaceSize: Double, minConfidence: Double, includeLandmarks: Bool) {
        self.enabled = enabled
        self.minFaceSize = minFaceSize
        self.minConfidence = minConfidence
        self.includeLandmarks = includeLandmarks
    }
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case minFaceSize = "min_face_size"
        case minConfidence = "min_confidence"
        case includeLandmarks = "include_landmarks"
    }
}

public struct IMessageConfigInfo: Codable {
    public let ocrEnabled: Bool
    
    public init(ocrEnabled: Bool) {
        self.ocrEnabled = ocrEnabled
    }
    
    enum CodingKeys: String, CodingKey {
        case ocrEnabled = "ocr_enabled"
    }
}

public struct OCRConfigInfo: Codable {
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

public struct FSWatchConfigInfo: Codable {
    public let watchesCount: Int
    
    public init(watchesCount: Int) {
        self.watchesCount = watchesCount
    }
    
    enum CodingKeys: String, CodingKey {
        case watchesCount = "watches_count"
    }
}
