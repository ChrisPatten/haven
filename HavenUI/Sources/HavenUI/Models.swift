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

// MARK: - Modules Response

struct ModulesResponse: Codable {
    let imessage: SimpleModuleInfo
    let ocr: SimpleModuleInfo
    let fswatch: SimpleModuleInfo
    let contacts: SimpleModuleInfo
    let calendar: SimpleModuleInfo
    let reminders: SimpleModuleInfo
    let mail: SimpleModuleInfo
    let notes: SimpleModuleInfo
    let face: SimpleModuleInfo
    
    // Computed property to provide dictionary-like access
    var modules: [String: SimpleModuleInfo] {
        [
            "imessage": imessage,
            "ocr": ocr,
            "fswatch": fswatch,
            "contacts": contacts,
            "calendar": calendar,
            "reminders": reminders,
            "mail": mail,
            "notes": notes,
            "face": face
        ]
    }
}

struct SimpleModuleInfo: Codable {
    let enabled: Bool
}

// MARK: - Collector Run Models

struct CollectorRunRequest: Codable {
    let limit: Int?
    let dateRange: DateRange?
    let collectorOptions: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case limit
        case dateRange = "date_range"
        case collectorOptions = "collector_options"
    }
    
    init(limit: Int? = nil, dateRange: DateRange? = nil, collectorOptions: [String: AnyCodable]? = nil) {
        self.limit = limit
        self.dateRange = dateRange
        self.collectorOptions = collectorOptions
    }
}

struct DateRange: Codable {
    let since: String?
    let until: String?
}

struct RunResponse: Codable {
    let status: String  // ok, error, partial
    let collector: String
    let runId: String
    let startedAt: String
    let finishedAt: String?
    let stats: RunStats
    let warnings: [String]
    let errors: [String]
    
    enum CodingKeys: String, CodingKey {
        case status
        case collector
        case runId = "run_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case stats
        case warnings
        case errors
    }
}

struct RunStats: Codable {
    let scanned: Int
    let matched: Int
    let submitted: Int
    let skipped: Int
    let earliestTouched: String?
    let latestTouched: String?
    let batches: Int
    
    enum CodingKeys: String, CodingKey {
        case scanned
        case matched
        case submitted
        case skipped
        case earliestTouched = "earliest_touched"
        case latestTouched = "latest_touched"
        case batches
    }
}

struct CollectorStateResponse: Codable {
    let isRunning: Bool?
    let lastRunStatus: String?
    let lastRunTime: String?
    let lastRunStats: [String: AnyCodable]?
    let lastRunError: String?
    
    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case lastRunStatus = "last_run_status"
        case lastRunTime = "last_run_time"
        case lastRunStats = "last_run_stats"
        case lastRunError = "last_run_error"
    }
}

// MARK: - Local Activity Model

struct CollectorActivity: Identifiable, Codable {
    let id: String
    let collector: String
    let timestamp: Date
    let status: String  // ok, error, partial
    let scanned: Int
    let submitted: Int
    let errors: [String]
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

// MARK: - AnyCodable Helper

enum AnyCodable: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    
    init(from decoder: Decoder) throws {
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
    
    func encode(to encoder: Encoder) throws {
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

// MARK: - Collector Info Model

struct CollectorInfo: Identifiable {
    let id: String  // e.g., "imessage", "email_imap"
    let displayName: String
    let description: String
    let category: String  // e.g., "messages", "email", "files", "contacts"
    var enabled: Bool
    var lastRunTime: Date?
    var lastRunStatus: String?
    var isRunning: Bool = false
    var lastError: String?
    var payload: String = ""
    
    static let supportedCollectors: [String: CollectorInfo] = [
        "imessage": CollectorInfo(
            id: "imessage",
            displayName: "iMessage",
            description: "Messages from Messages.app",
            category: "messages",
            enabled: false,
            payload: #"{"limit": 1000}"#
        ),
        "email_local": CollectorInfo(
            id: "email_local",
            displayName: "Mail.app",
            description: "Emails from Mail.app",
            category: "email",
            enabled: false,
            payload: #"{"limit": 500}"#
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
        return stateAwareCollectors.contains(collectorId)
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
}
