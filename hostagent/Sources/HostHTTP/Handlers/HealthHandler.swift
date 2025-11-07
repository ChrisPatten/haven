import Foundation
import HavenCore

/// Handler for GET /v1/health
public struct HealthHandler {
    private let config: HavenConfig
    private let startTime: Date
    private let logger = HavenLogger(category: "health")
    
    public init(config: HavenConfig, startTime: Date = Date()) {
        self.config = config
        self.startTime = startTime
    }
    
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        let moduleSummaries = buildModuleSummaries()
        
        let response = HealthResponse(
            status: "healthy",
            startedAt: ISO8601DateFormatter().string(from: startTime),
            version: BuildInfo.versionWithBuildID,
            uptimeSeconds: Int(Date().timeIntervalSince(startTime)),
            modules: moduleSummaries
        )
        
        logger.debug("Health check completed", metadata: [
            "uptime": Int(Date().timeIntervalSince(startTime)),
            "request_id": context.requestId
        ])
        
        return HTTPResponse.ok(json: response)
    }
    
    // MARK: - Direct Swift API
    
    /// Direct Swift API for getting health status
    /// Replaces HTTP-based handle for in-app integration
    public func getStatus() -> HealthResponse {
        let moduleSummaries = buildModuleSummaries()
        
        return HealthResponse(
            status: "healthy",
            startedAt: ISO8601DateFormatter().string(from: startTime),
            version: BuildInfo.versionWithBuildID,
            uptimeSeconds: Int(Date().timeIntervalSince(startTime)),
            modules: moduleSummaries
        )
    }
    
    private func buildModuleSummaries() -> [ModuleSummary] {
        var summaries: [ModuleSummary] = []
        
        // iMessage
        summaries.append(ModuleSummary(
            name: "imessage",
            enabled: config.modules.imessage.enabled,
            status: config.modules.imessage.enabled ? "ready" : "disabled",
            extraInfo: nil
        ))
        
        // OCR
        summaries.append(ModuleSummary(
            name: "ocr",
            enabled: config.modules.ocr.enabled,
            status: config.modules.ocr.enabled ? "ready" : "disabled",
            extraInfo: nil
        ))
        
        // FSWatch
        summaries.append(ModuleSummary(
            name: "fswatch",
            enabled: config.modules.fswatch.enabled,
            status: config.modules.fswatch.enabled ? "ready" : "disabled",
            extraInfo: ["watches_count": config.modules.fswatch.watches.count]
        ))
        
        // Face detection module
        summaries.append(ModuleSummary(
            name: "face",
            enabled: config.modules.face.enabled,
            status: config.modules.face.enabled ? "ready" : "disabled",
            extraInfo: nil
        ))
        
        // Stub and simple modules (use enabled booleans to avoid type mismatch between
        // different module config types like MailModuleConfig and StubModuleConfig)
        for (name, enabled) in [
            ("contacts", config.modules.contacts.enabled),
            ("mail", config.modules.mail.enabled)
        ] {
            summaries.append(ModuleSummary(
                name: name,
                enabled: enabled,
                status: enabled ? "stub" : "disabled",
                extraInfo: nil
            ))
        }
        
        return summaries
    }
}

public struct HealthResponse: Codable {
    public let status: String
    public let startedAt: String
    public let version: String
    public let uptimeSeconds: Int
    public let modules: [ModuleSummary]
    
    public init(status: String, startedAt: String, version: String, uptimeSeconds: Int, modules: [ModuleSummary]) {
        self.status = status
        self.startedAt = startedAt
        self.version = version
        self.uptimeSeconds = uptimeSeconds
        self.modules = modules
    }
    
    enum CodingKeys: String, CodingKey {
        case status
        case startedAt = "started_at"
        case version
        case uptimeSeconds = "uptime_seconds"
        case modules
    }
}

public struct ModuleSummary: Codable {
    public let name: String
    public let enabled: Bool
    public let status: String
    public let extraInfo: [String: Int]?
    
    public init(name: String, enabled: Bool, status: String, extraInfo: [String: Int]?) {
        self.name = name
        self.enabled = enabled
        self.status = status
        self.extraInfo = extraInfo
    }
    
    enum CodingKeys: String, CodingKey {
        case name, enabled, status
        case extraInfo = "extra_info"
    }
}
