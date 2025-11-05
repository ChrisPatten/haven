//
//  HavenCoreStub.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//  Stub implementation for HavenCore types until package dependencies are added
//

import Foundation

// MARK: - HavenCore Types Stub

public struct HavenConfig: Codable {
    public var service: ServiceConfig
    public var api: ApiConfig
    public var gateway: GatewayConfig
    public var logging: LoggingConfig
    public var modules: ModulesConfig
    
    public init(service: ServiceConfig = ServiceConfig(),
                api: ApiConfig = ApiConfig(),
                gateway: GatewayConfig = GatewayConfig(),
                logging: LoggingConfig = LoggingConfig(),
                modules: ModulesConfig = ModulesConfig()) {
        self.service = service
        self.api = api
        self.gateway = gateway
        self.logging = logging
        self.modules = modules
    }
}

public struct ServiceConfig: Codable {
    public var port: Int
    public var auth: AuthConfig
    
    public init(port: Int = 7090, auth: AuthConfig = AuthConfig()) {
        self.port = port
        self.auth = auth
    }
}

public struct AuthConfig: Codable {
    public var header: String
    public var secret: String
    
    public init(header: String = "x-auth", secret: String = "changeme") {
        self.header = header
        self.secret = secret
    }
}

public struct GatewayConfig: Codable {
    public var baseUrl: String
    public var ingestPath: String
    public var ingestFilePath: String
    public var timeoutMs: Int
    
    public init(baseUrl: String = "http://gateway:8080",
                ingestPath: String = "/v1/ingest",
                ingestFilePath: String = "/v1/ingest/file",
                timeoutMs: Int = 30000) {
        self.baseUrl = baseUrl
        self.ingestPath = ingestPath
        self.ingestFilePath = ingestFilePath
        self.timeoutMs = timeoutMs
    }
}

public struct ApiConfig: Codable {
    public var responseTimeoutMs: Int
    public var statusTtlMinutes: Int
    
    public init(responseTimeoutMs: Int = 2000, statusTtlMinutes: Int = 1440) {
        self.responseTimeoutMs = responseTimeoutMs
        self.statusTtlMinutes = statusTtlMinutes
    }
}

public struct LoggingConfig: Codable {
    public var level: String
    public var format: String
    public var paths: LoggingPathsConfig
    
    public init(level: String = "info", format: String = "json", paths: LoggingPathsConfig = LoggingPathsConfig()) {
        self.level = level
        self.format = format
        self.paths = paths
    }
}

public struct LoggingPathsConfig: Codable {
    public var output: String
    public var error: String
    
    public init(output: String = "~/Library/Logs/Haven/hostagent.log", error: String = "~/Library/Logs/Haven/hostagent-error.log") {
        self.output = output
        self.error = error
    }
}

public struct ModulesConfig: Codable {
    public var imessage: IMessageModuleConfig
    public var ocr: OCRModuleConfig
    public var entity: EntityModuleConfig
    public var face: FaceModuleConfig
    public var fswatch: FSWatchModuleConfig
    public var localfs: LocalFSModuleConfig
    public var contacts: StubModuleConfig
    public var mail: MailModuleConfig
    
    public init(imessage: IMessageModuleConfig = IMessageModuleConfig(),
                ocr: OCRModuleConfig = OCRModuleConfig(),
                entity: EntityModuleConfig = EntityModuleConfig(),
                face: FaceModuleConfig = FaceModuleConfig(),
                fswatch: FSWatchModuleConfig = FSWatchModuleConfig(),
                localfs: LocalFSModuleConfig = LocalFSModuleConfig(),
                contacts: StubModuleConfig = StubModuleConfig(),
                mail: MailModuleConfig = MailModuleConfig()) {
        self.imessage = imessage
        self.ocr = ocr
        self.entity = entity
        self.face = face
        self.fswatch = fswatch
        self.localfs = localfs
        self.contacts = contacts
        self.mail = mail
    }
}

public struct IMessageModuleConfig: Codable {
    public var enabled: Bool
    public var chatDbPath: String
    public var ocrEnabled: Bool
    
    public init(enabled: Bool = false, chatDbPath: String = "~/Library/Messages/chat.db", ocrEnabled: Bool = false) {
        self.enabled = enabled
        self.chatDbPath = chatDbPath
        self.ocrEnabled = ocrEnabled
    }
}

public struct OCRModuleConfig: Codable {
    public var enabled: Bool
    public var timeoutMs: Int
    public var languages: [String]
    public var recognitionLevel: String
    public var includeLayout: Bool
    public var maxImageDimension: Int
    
    public init(enabled: Bool = false, timeoutMs: Int = 2000, languages: [String] = ["en"], recognitionLevel: String = "fast", includeLayout: Bool = true, maxImageDimension: Int = 1600) {
        self.enabled = enabled
        self.timeoutMs = timeoutMs
        self.languages = languages
        self.recognitionLevel = recognitionLevel
        self.includeLayout = includeLayout
        self.maxImageDimension = maxImageDimension
    }
}

public struct EntityModuleConfig: Codable {
    public var enabled: Bool
    public var types: [String]
    public var minConfidence: Float
    
    public init(enabled: Bool = false, types: [String] = [], minConfidence: Float = 0.0) {
        self.enabled = enabled
        self.types = types
        self.minConfidence = minConfidence
    }
}

public struct FaceModuleConfig: Codable {
    public var enabled: Bool
    public var minFaceSize: Double
    public var minConfidence: Double
    public var includeLandmarks: Bool
    
    public init(enabled: Bool = false, minFaceSize: Double = 50.0, minConfidence: Double = 0.5, includeLandmarks: Bool = false) {
        self.enabled = enabled
        self.minFaceSize = minFaceSize
        self.minConfidence = minConfidence
        self.includeLandmarks = includeLandmarks
    }
}

public struct FSWatchModuleConfig: Codable {
    public var enabled: Bool
    public var watches: [FSWatchEntry]
    public var eventQueueSize: Int
    
    public init(enabled: Bool = false, watches: [FSWatchEntry] = [], eventQueueSize: Int = 1000) {
        self.enabled = enabled
        self.watches = watches
        self.eventQueueSize = eventQueueSize
    }
}

public struct FSWatchEntry: Codable, Identifiable {
    public var id: String
    public var path: String
    public var recursive: Bool
    
    public init(id: String = UUID().uuidString, path: String = "", recursive: Bool = true) {
        self.id = id
        self.path = path
        self.recursive = recursive
    }
}

public struct LocalFSModuleConfig: Codable {
    public var enabled: Bool
    
    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

public struct StubModuleConfig: Codable {
    public var enabled: Bool
    
    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

public struct MailModuleConfig: Codable {
    public var enabled: Bool
    public var sources: [MailSourceConfig]?
    public var redactPii: Bool
    
    public init(enabled: Bool = false, sources: [MailSourceConfig]? = nil, redactPii: Bool = true) {
        self.enabled = enabled
        self.sources = sources
        self.redactPii = redactPii
    }
}

public struct MailSourceConfig: Codable {
    public var id: String
    public var type: String
    public var enabled: Bool
    public var host: String?
    public var port: Int?
    public var username: String?
    public var tls: Bool?
    public var folders: [String]?
    public var auth: MailSourceAuthConfig?
    
    public init(id: String = "", type: String = "imap", enabled: Bool = false, host: String? = nil, port: Int? = nil, username: String? = nil, tls: Bool? = true, folders: [String]? = nil, auth: MailSourceAuthConfig? = nil) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.host = host
        self.port = port
        self.username = username
        self.tls = tls
        self.folders = folders
        self.auth = auth
    }
    
    public var responseIdentifier: String { id }
    public var debugIdentifier: String { id }
}

public struct MailSourceAuthConfig: Codable {
    public var kind: String?
    public var secretRef: String?
    
    public init(kind: String? = nil, secretRef: String? = nil) {
        self.kind = kind
        self.secretRef = secretRef
    }
}

public class ConfigLoader {
    public init() {}
    
    public func load(from path: String? = nil) throws -> HavenConfig {
        // Stub implementation - return default config
        return HavenConfig()
    }
    
    public func save(_ config: HavenConfig, to path: String? = nil) throws {
        // Stub implementation
    }
}

public actor GatewayClient {
    private let baseUrl: String
    private let ingestPath: String
    private let authToken: String
    private let timeout: TimeInterval
    
    public init(config: GatewayConfig, authToken: String) {
        self.baseUrl = config.baseUrl
        self.ingestPath = config.ingestPath
        self.authToken = authToken
        self.timeout = TimeInterval(config.timeoutMs) / 1000.0
    }
    
    public func ingest(events: [IngestEvent]) async throws {
        // Stub implementation
    }
    
    public func postAdmin(path: String, payload: [String: Any]) async -> (statusCode: Int, body: String) {
        // Stub implementation
        return (200, "")
    }
}

public struct IngestEvent: Codable {
    // Stub implementation
}

public struct CollectorRunRequest: Codable {
    public enum Mode: String, Codable {
        case simulate
        case real
    }
    
    public enum Order: String, Codable {
        case asc
        case desc
    }
    
    public let mode: Mode?
    public let limit: Int?
    public let order: Order?
    public let concurrency: Int?
    public let dateRange: DateRange?
    public let timeWindow: String?
    public let batch: Bool?
    public let batchSize: Int?
    public let scope: HavenCore.AnyCodable?
    
    public struct DateRange: Codable {
        public let since: Date?
        public let until: Date?
    }
    
    public init(mode: Mode? = nil, limit: Int? = nil, order: Order? = nil, concurrency: Int? = nil, dateRange: DateRange? = nil, timeWindow: String? = nil, batch: Bool? = nil, batchSize: Int? = nil, scope: HavenCore.AnyCodable? = nil) {
        self.mode = mode
        self.limit = limit
        self.order = order
        self.concurrency = concurrency
        self.dateRange = dateRange
        self.timeWindow = timeWindow
        self.batch = batch
        self.batchSize = batchSize
        self.scope = scope
    }
}

public enum HavenCore {
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
}

// RunResponse is defined in Models.swift, not here

public nonisolated struct StubLogger {
    public nonisolated static func setMinimumLevel(_ level: String) {}
    public nonisolated static func setOutputFormat(_ format: String) {}
    public nonisolated static func enableDirectFileLogging() {}
    
    private let category: String
    
    public nonisolated init(category: String) {
        self.category = category
    }
    
    public nonisolated func info(_ message: String, metadata: [String: String] = [:]) {}
    public nonisolated func warning(_ message: String, metadata: [String: String] = [:]) {}
    public nonisolated func error(_ message: String, metadata: [String: String] = [:]) {}
    public nonisolated func debug(_ message: String, metadata: [String: String] = [:]) {}
}

public enum BuildInfo {
    public nonisolated static var versionWithBuildID: String {
        return "0.0.0-stub"
    }
}

// MARK: - HostAgent Types Stub (will be replaced when package is integrated)

/// Stub for hostagent's RunResponse.Status enum
public enum HostAgentRunResponseStatus: String, Codable {
    case ok
    case error
    case partial
}

/// Stub for hostagent's RunResponse.Stats struct
public struct HostAgentStats: Codable {
    public let scanned: Int
    public let matched: Int
    public let submitted: Int
    public let skipped: Int
    public let earliest_touched: String?
    public let latest_touched: String?
    public let batches: Int
    
    public init(scanned: Int, matched: Int, submitted: Int, skipped: Int, earliest_touched: String?, latest_touched: String?, batches: Int) {
        self.scanned = scanned
        self.matched = matched
        self.submitted = submitted
        self.skipped = skipped
        self.earliest_touched = earliest_touched
        self.latest_touched = latest_touched
        self.batches = batches
    }
}

/// Stub for hostagent's RunResponse struct
public struct HostAgentRunResponse: Codable {
    public let status: HostAgentRunResponseStatus
    public let collector: String
    public let run_id: String
    public let started_at: String
    public let finished_at: String?
    public let stats: HostAgentStats
    public let warnings: [String]
    public let errors: [String]
    
    public init(status: HostAgentRunResponseStatus, collector: String, run_id: String, started_at: String, finished_at: String?, stats: HostAgentStats, warnings: [String], errors: [String]) {
        self.status = status
        self.collector = collector
        self.run_id = run_id
        self.started_at = started_at
        self.finished_at = finished_at
        self.stats = stats
        self.warnings = warnings
        self.errors = errors
    }
}

/// Stub for hostagent's CollectorStateInfo struct
public struct HostAgentCollectorStateInfo: Codable {
    public let isRunning: Bool
    public let lastRunTime: Date?
    public let lastRunStatus: String?
    public let lastRunStats: [String: AnyCodable]?
    public let lastRunError: String?
    
    public init(isRunning: Bool, lastRunTime: Date?, lastRunStatus: String?, lastRunStats: [String: AnyCodable]?, lastRunError: String?) {
        self.isRunning = isRunning
        self.lastRunTime = lastRunTime
        self.lastRunStatus = lastRunStatus
        self.lastRunStats = lastRunStats
        self.lastRunError = lastRunError
    }
}

