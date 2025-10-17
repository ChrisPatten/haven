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
            version: "1.0.0",
            uptimeSeconds: Int(Date().timeIntervalSince(startTime)),
            modules: moduleSummaries
        )
        
        logger.debug("Health check completed", metadata: [
            "uptime": Int(Date().timeIntervalSince(startTime)),
            "request_id": context.requestId
        ])
        
        return HTTPResponse.ok(json: response)
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
        
        // Stub modules
        for (name, moduleConfig) in [
            ("contacts", config.modules.contacts),
            ("calendar", config.modules.calendar),
            ("reminders", config.modules.reminders),
            ("mail", config.modules.mail),
            ("notes", config.modules.notes)
        ] {
            summaries.append(ModuleSummary(
                name: name,
                enabled: moduleConfig.enabled,
                status: moduleConfig.enabled ? "stub" : "disabled",
                extraInfo: nil
            ))
        }
        
        return summaries
    }
}

struct HealthResponse: Codable {
    let status: String
    let startedAt: String
    let version: String
    let uptimeSeconds: Int
    let modules: [ModuleSummary]
    
    enum CodingKeys: String, CodingKey {
        case status
        case startedAt = "started_at"
        case version
        case uptimeSeconds = "uptime_seconds"
        case modules
    }
}

struct ModuleSummary: Codable {
    let name: String
    let enabled: Bool
    let status: String
    let extraInfo: [String: Int]?
    
    enum CodingKeys: String, CodingKey {
        case name, enabled, status
        case extraInfo = "extra_info"
    }
}

