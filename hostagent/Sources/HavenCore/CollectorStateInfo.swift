import Foundation

/// Shared state representation for collector services
/// Used by all collectors to provide consistent state information
public struct CollectorStateInfo: Codable {
    public let isRunning: Bool
    public let lastRunTime: Date?
    public let lastRunStatus: String?
    public let lastRunStats: [String: AnyCodable]?
    public let lastRunError: String?
    
    public init(
        isRunning: Bool,
        lastRunTime: Date? = nil,
        lastRunStatus: String? = nil,
        lastRunStats: [String: AnyCodable]? = nil,
        lastRunError: String? = nil
    ) {
        self.isRunning = isRunning
        self.lastRunTime = lastRunTime
        self.lastRunStatus = lastRunStatus
        self.lastRunStats = lastRunStats
        self.lastRunError = lastRunError
    }
}

