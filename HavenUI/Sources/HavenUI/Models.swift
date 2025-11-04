import Foundation
import Yams

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
    let imessage: IMessageModuleInfo
    let ocr: OCRModuleInfo
    let fswatch: FSWatchModuleInfo
    let contacts: SimpleModuleInfo
    let mail: SimpleModuleInfo
    let face: SimpleModuleInfo
    
    // Computed property to provide dictionary-like access
    var modules: [String: SimpleModuleInfo] {
        var result: [String: SimpleModuleInfo] = [:]
        result["imessage"] = SimpleModuleInfo(enabled: imessage.enabled)
        result["ocr"] = SimpleModuleInfo(enabled: ocr.enabled)
        result["fswatch"] = SimpleModuleInfo(enabled: fswatch.enabled)
        result["contacts"] = contacts
        result["mail"] = mail
        result["face"] = face
        // Add missing modules as disabled by default
        result["calendar"] = SimpleModuleInfo(enabled: false)
        result["reminders"] = SimpleModuleInfo(enabled: false)
        result["notes"] = SimpleModuleInfo(enabled: false)
        return result
    }
}

struct IMessageModuleInfo: Codable {
    let enabled: Bool
    let config: IMessageModuleConfig
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case config
    }
}

struct IMessageModuleConfig: Codable {
    let ocrEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
        case ocrEnabled = "ocr_enabled"
    }
}

struct OCRModuleInfo: Codable {
    let enabled: Bool
    let config: OCRModuleConfigInfo
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case config
    }
}

struct OCRModuleConfigInfo: Codable {
    let languages: [String]
    let timeoutMs: Int
    
    enum CodingKeys: String, CodingKey {
        case languages
        case timeoutMs = "timeout_ms"
    }
}

struct FSWatchModuleInfo: Codable {
    let enabled: Bool
    let config: FSWatchModuleConfigInfo
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case config
    }
}

struct FSWatchModuleConfigInfo: Codable {
    let watches: [WatchInfo]
}

struct WatchInfo: Codable {
    let id: String
    let path: String
    let glob: String
    let target: String
    let handoff: String
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

// MARK: - IMAP Account Info

struct IMAPAccountInfo: Codable {
    let id: String
    let username: String?
    let host: String?
    let enabled: Bool
    let folders: [String]?
}

// MARK: - Collector Info Model

struct CollectorInfo: Identifiable {
    let id: String  // e.g., "imessage", "email_imap", or "email_imap:personal-icloud"
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
}

// MARK: - Schema Models for Dynamic Form Generation

enum FieldType {
    case string(placeholder: String? = nil)
    case integer(min: Int? = nil, max: Int? = nil)
    case double(min: Double? = nil, max: Double? = nil)
    case boolean
    case stringArray(placeholder: String? = nil)
    case enumeration(values: [String])
    case dateTime
}

struct SchemaField: Identifiable {
    let id: String
    let label: String
    let description: String?
    let fieldType: FieldType
    let required: Bool
    let defaultValue: AnyCodable?
    
    var jsonKey: String {
        // Convert camelCase or snake_case to consistent form
        id
    }
}

struct CollectorSchema: Identifiable {
    let id: String
    let displayName: String
    let fields: [SchemaField]
    
    func field(for key: String) -> SchemaField? {
        fields.first { $0.id == key }
    }
}

// MARK: - Collector Schema Definitions

extension CollectorSchema {
    // Global/top-level fields that apply to all requests
    static let globalFields: [SchemaField] = [
        SchemaField(
            id: "order",
            label: "Order",
            description: "Sort order for results (asc=oldest first, desc=newest first)",
            fieldType: .enumeration(values: ["asc", "desc"]),
            required: true,
            defaultValue: .string("desc")
        ),
        SchemaField(
            id: "mode",
            label: "Mode",
            description: "Execution mode (real=process, simulate=dry-run)",
            fieldType: .enumeration(values: ["real", "simulate"]),
            required: false,
            defaultValue: .string("real")
        ),
        SchemaField(
            id: "limit",
            label: "Limit",
            description: "Maximum number of records to process",
            fieldType: .integer(min: 1),
            required: false,
            defaultValue: nil
        ),
        SchemaField(
            id: "since",
            label: "Since (Start Date)",
            description: "Only collect items from this date onwards",
            fieldType: .string(placeholder: "2024-01-15T10:30:00Z"),
            required: false,
            defaultValue: nil
        ),
        SchemaField(
            id: "until",
            label: "Until (End Date)",
            description: "Only collect items up to this date",
            fieldType: .string(placeholder: "2024-01-15T10:30:00Z"),
            required: false,
            defaultValue: nil
        ),
        SchemaField(
            id: "batch",
            label: "Batch Mode",
            description: "Submit documents via batch ingest endpoint",
            fieldType: .boolean,
            required: false,
            defaultValue: .bool(false)
        ),
        SchemaField(
            id: "batch_size",
            label: "Batch Size",
            description: "Number of documents per submission when batching",
            fieldType: .integer(min: 1),
            required: false,
            defaultValue: nil
        )
    ]
    
    static let imessage = CollectorSchema(
        id: "imessage",
        displayName: "iMessage",
        fields: globalFields + [
            SchemaField(
                id: "thread_lookback_days",
                label: "Thread Lookback Days",
                description: "Days to look back for thread context",
                fieldType: .integer(min: 0),
                required: false,
                defaultValue: nil
            ),
            SchemaField(
                id: "message_lookback_days",
                label: "Message Lookback Days",
                description: "Days to look back for messages",
                fieldType: .integer(min: 0),
                required: false,
                defaultValue: nil
            ),
            SchemaField(
                id: "chat_db_path",
                label: "Chat DB Path",
                description: "Path to chat.db (leave empty for default)",
                fieldType: .string(placeholder: "~/.haven/chat.db"),
                required: false,
                defaultValue: nil
            )
        ]
    )
    
    static let email_imap = CollectorSchema(
        id: "email_imap",
        displayName: "IMAP",
        fields: globalFields + [
            SchemaField(
                id: "account_id",
                label: "Account ID",
                description: "IMAP account identifier (matches source ID from config, e.g., personal-icloud, personal-gmail). If omitted, uses first enabled account.",
                fieldType: .string(placeholder: "personal-icloud"),
                required: false,
                defaultValue: nil
            ),
            SchemaField(
                id: "folder",
                label: "Folder/Mailbox",
                description: "IMAP folder to process (e.g., INBOX, Sent Messages). If omitted, processes all folders configured for the account.",
                fieldType: .string(placeholder: "INBOX"),
                required: false,
                defaultValue: .string("INBOX")
            ),
            SchemaField(
                id: "max_limit",
                label: "Max Limit",
                description: "Maximum records to process",
                fieldType: .integer(min: 1),
                required: false,
                defaultValue: nil
            ),
            SchemaField(
                id: "reset",
                label: "Reset State",
                description: "Reset collector state before running (clears coverage tracking)",
                fieldType: .boolean,
                required: false,
                defaultValue: .bool(false)
            ),
            SchemaField(
                id: "dry_run",
                label: "Dry Run",
                description: "Test run without processing or submitting to server",
                fieldType: .boolean,
                required: false,
                defaultValue: .bool(false)
            )
        ]
    )
    
    static let localfs = CollectorSchema(
        id: "localfs",
        displayName: "Local Files",
        fields: globalFields + [
            SchemaField(
                id: "watch_dir",
                label: "Watch Directory",
                description: "Directory to scan for files",
                fieldType: .string(placeholder: "~/HavenInbox"),
                required: true,
                defaultValue: nil
            ),
            SchemaField(
                id: "include",
                label: "Include Patterns",
                description: "Glob patterns to include (e.g., *.txt, *.pdf)",
                fieldType: .stringArray(placeholder: "*.txt"),
                required: false,
                defaultValue: nil
            ),
            SchemaField(
                id: "exclude",
                label: "Exclude Patterns",
                description: "Glob patterns to exclude",
                fieldType: .stringArray(placeholder: "*.tmp"),
                required: false,
                defaultValue: nil
            ),
            SchemaField(
                id: "tags",
                label: "Tags",
                description: "Tags to apply to collected files",
                fieldType: .stringArray(placeholder: "inbox"),
                required: false,
                defaultValue: nil
            ),
            SchemaField(
                id: "delete_after",
                label: "Delete After Processing",
                description: "Remove files after successful upload",
                fieldType: .boolean,
                required: false,
                defaultValue: .bool(false)
            ),
            SchemaField(
                id: "dry_run",
                label: "Dry Run",
                description: "Identify matches without uploading",
                fieldType: .boolean,
                required: false,
                defaultValue: .bool(false)
            ),
            SchemaField(
                id: "follow_symlinks",
                label: "Follow Symlinks",
                description: "Follow symbolic links when scanning",
                fieldType: .boolean,
                required: false,
                defaultValue: .bool(false)
            )
        ]
    )
    
    static let contacts = CollectorSchema(
        id: "contacts",
        displayName: "Contacts",
        fields: globalFields + [
            SchemaField(
                id: "mode",
                label: "Mode",
                description: "Import mode (real or simulate)",
                fieldType: .enumeration(values: ["real", "simulate"]),
                required: false,
                defaultValue: .string("real")
            )
        ]
    )
    
    static func schema(for collectorId: String) -> CollectorSchema? {
        let schemas: [String: CollectorSchema] = [
            "imessage": .imessage,
            "email_imap": .email_imap,
            "localfs": .localfs,
            "contacts": .contacts
        ]
        return schemas[collectorId]
    }
}
