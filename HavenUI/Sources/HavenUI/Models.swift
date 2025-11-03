import Foundation

// MARK: - Health Response Models

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

// MARK: - App Status Enum

enum AppStatus: Equatable {
    case green   // Healthy, running
    case yellow  // Running but health check failing
    case red     // Not running or unreachable
    
    var description: String {
        switch self {
        case .green:
            return "Healthy"
        case .yellow:
            return "Running (checking...)"
        case .red:
            return "Stopped"
        }
    }
    
    var symbol: String {
        switch self {
        case .green:
            return "🟢"
        case .yellow:
            return "🟡"
        case .red:
            return "🔴"
        }
    }
}

// MARK: - Process State

enum ProcessState: Equatable {
    case running
    case stopped
    case unknown
}
