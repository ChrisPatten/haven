//
//  Models.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

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

public struct ModuleSummary: Codable {
    public let name: String
    public let enabled: Bool
    public let status: String
    public let extraInfo: [String: Int]?
    
    enum CodingKeys: String, CodingKey {
        case name, enabled, status
        case extraInfo = "extra_info"
    }
}

// MARK: - Collector Run Models

// RunResponse matches the real type from hostagent.RunResponse
// Uses snake_case properties to match the real type structure
public struct RunResponse: Codable {
    public enum Status: String, Codable {
        case ok
        case error
        case partial
    }
    
    public var status: Status
    public var collector: String
    public var run_id: String
    public var started_at: String
    public var finished_at: String?
    public var stats: Stats
    public var warnings: [String]
    public var errors: [String]
    
    public struct Stats: Codable {
        public var scanned: Int
        public var matched: Int
        public var submitted: Int
        public var skipped: Int
        public var earliest_touched: String?
        public var latest_touched: String?
        public var batches: Int
        
        public init(scanned: Int = 0, matched: Int = 0, submitted: Int = 0, skipped: Int = 0, earliest_touched: String? = nil, latest_touched: String? = nil, batches: Int = 0) {
            self.scanned = scanned
            self.matched = matched
            self.submitted = submitted
            self.skipped = skipped
            self.earliest_touched = earliest_touched
            self.latest_touched = latest_touched
            self.batches = batches
        }
    }
    
    public init(collector: String, runID: String, startedAt: Date = Date()) {
        self.status = .ok
        self.collector = collector
        self.run_id = runID
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        self.started_at = formatter.string(from: startedAt)
        self.finished_at = nil
        self.stats = Stats()
        self.warnings = []
        self.errors = []
    }
}

public struct CollectorStateResponse: Codable {
    public let isRunning: Bool?
    public let lastRunStatus: String?
    public let lastRunTime: String?
    public let lastRunStats: [String: AnyCodable]?
    public let lastRunError: String?
    
    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case lastRunStatus = "last_run_status"
        case lastRunTime = "last_run_time"
        case lastRunStats = "last_run_stats"
        case lastRunError = "last_run_error"
    }
}

// MARK: - HostAgent Types
// Using real types from HavenCore package where available
import HavenCore

// CollectorStateInfo is available directly from HavenCore after import
// No typealias needed - use CollectorStateInfo directly

// Note: RunResponse and CollectorRunRequest are in HostAgentEmail which is not exported
// as a library. These local definitions match the real types from hostagent.
// TODO: Move RunResponse and CollectorRunRequest to HavenCore or export HostAgentEmail

// MARK: - CollectorRunRequest (API-compatible version with snake_case)

/// API-compatible CollectorRunRequest for HTTP requests
/// Uses snake_case properties to match the actual API
public struct CollectorRunRequest: Codable {
    public var mode: String?
    public var order: String?
    public var limit: Int?
    public var concurrency: Int?
    public var date_range: DateRange?
    public var time_window: String?
    public var filters: FilterConfig?
    public var redaction_override: [String: Bool]?
    public var scope: [String: AnyCodable]?
    public var wait_for_completion: Bool?
    public var timeout_ms: Int?
    
    public init() {}
    
    public struct DateRange: Codable {
        public var since: String?
        public var until: String?
        
        public init() {}
    }
    
    public struct FilterConfig: Codable {
        public var combination_mode: String?
        public var default_action: String?
        public var inline: String?
        public var files: [String]?
        public var environment_variable: String?
        
        public init() {}
    }
}

/// Temporary stub for hostagent's AnyCodable
public enum HostAgentAnyCodable: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    
    public init(_ value: Any) {
        switch value {
        case let str as String:
            self = .string(str)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let bool as Bool:
            self = .bool(bool)
        default:
            self = .null
        }
    }
    
    public var value: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .null
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - Local Activity Model

public struct CollectorActivity: Identifiable, Codable {
    public let id: String
    let collector: String
    let timestamp: Date
    let status: String  // ok, error, partial
    let scanned: Int
    let submitted: Int
    let errors: [String]
}

// MARK: - App Status Enum

public enum AppStatus: Equatable {
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
}

// MARK: - Process State

public enum ProcessState: Equatable {
    case running
    case stopped
    case unknown
}

// MARK: - Collector Info Model

public struct CollectorInfo: Identifiable {
    public let id: String  // e.g., "imessage", "email_imap", or "email_imap:personal-icloud"
    let displayName: String
    let description: String
    let category: String  // e.g., "messages", "email", "files", "contacts"
    var enabled: Bool
    var lastRunTime: Date?
    var lastRunStatus: String?
    var isRunning: Bool = false
    var lastError: String?
    var payload: String = ""
    var imapAccountId: String?  // For IMAP account-specific collectors
    
    static let supportedCollectors: [String: CollectorInfo] = [
        "imessage": CollectorInfo(
            id: "imessage",
            displayName: "iMessage",
            description: "Messages from Messages.app",
            category: "messages",
            enabled: false,
            payload: #"{"limit": 1000}"#
        ),
        "email_imap": CollectorInfo(
            id: "email_imap",
            displayName: "IMAP",
            description: "Remote email via IMAP",
            category: "email",
            enabled: false,
            payload: #"{"limit": 100}"#
        ),
        "localfs": CollectorInfo(
            id: "localfs",
            displayName: "Local Files",
            description: "Documents and files from disk",
            category: "files",
            enabled: false,
            payload: #"{"collector_options": {"watch_dir": "~/HavenInbox"}}"#
        ),
        "contacts": CollectorInfo(
            id: "contacts",
            displayName: "Contacts",
            description: "Contacts from Contacts.app",
            category: "contacts",
            enabled: false,
            payload: #"{"collector_options": {"mode": "real"}}"#
        )
    ]
    
    // Collectors that have /state endpoints
    static let stateAwareCollectors = Set(["imessage", "contacts", "localfs"])
    
    static func hasStateEndpoint(_ collectorId: String) -> Bool {
        // Extract base collector ID for account-specific collectors (e.g., "email_imap" from "email_imap:personal-icloud")
        let baseCollectorId: String
        if let colonIndex = collectorId.firstIndex(of: ":") {
            baseCollectorId = String(collectorId[..<colonIndex])
        } else {
            baseCollectorId = collectorId
        }
        return stateAwareCollectors.contains(baseCollectorId)
    }
    
    func statusDescription() -> String {
        if isRunning {
            return "Running..."
        }
        if let lastError = lastError, !lastError.isEmpty {
            return "Error"
        }
        if let status = lastRunStatus, !status.isEmpty {
            switch status.lowercased() {
            case "ok":
                return "Idle"
            case "error":
                return "Error"
            case "partial":
                return "Partial"
            default:
                return status
            }
        }
        return "Idle"
    }
    
    func lastRunDescription() -> String {
        guard let lastRunTime = lastRunTime else {
            return "Never"
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter.string(from: lastRunTime)
    }
    
    func relativeTimeString() -> String {
        guard let lastRunTime = lastRunTime else {
            return "Never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastRunTime, relativeTo: Date())
    }
    
    static func groupedByCategory(_ collectors: [CollectorInfo]) -> [String: [CollectorInfo]] {
        Dictionary(grouping: collectors, by: { $0.category })
    }
    
    static func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "messages":
            return "Messages"
        case "email":
            return "Email"
        case "files":
            return "Files"
        case "contacts":
            return "Contacts"
        default:
            return category.capitalized
        }
    }
}

// MARK: - AnyCodable Helper (UI version)

public enum AnyCodable: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .null
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

