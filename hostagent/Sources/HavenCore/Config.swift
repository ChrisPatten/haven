import Foundation

/// Global application configuration
public struct HavenConfig: Codable {
    public var service: ServiceConfig
    public var api: ApiConfig
    public var gateway: GatewayConfig
    public var logging: LoggingConfig
    public var modules: ModulesConfig
    
    enum CodingKeys: String, CodingKey {
        case service
        case api
        case gateway
        case logging
        case modules
    }
    
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
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // For backward compatibility, decode service section if present
        self.service = try container.decodeIfPresent(ServiceConfig.self, forKey: .service) ?? ServiceConfig()
        self.api = try container.decodeIfPresent(ApiConfig.self, forKey: .api) ?? ApiConfig()
        self.gateway = try container.decode(GatewayConfig.self, forKey: .gateway)
        self.logging = try container.decode(LoggingConfig.self, forKey: .logging)
        self.modules = try container.decode(ModulesConfig.self, forKey: .modules)
    }
}

public struct ServiceConfig: Codable {
    public var port: Int
    public var auth: AuthConfig
    
    enum CodingKeys: String, CodingKey {
        case port
        case auth
    }
    
    public init(port: Int = 7090, auth: AuthConfig = AuthConfig()) {
        self.port = port
        self.auth = auth
    }
}

public struct ApiConfig: Codable {
    public var responseTimeoutMs: Int
    public var statusTtlMinutes: Int
    
    enum CodingKeys: String, CodingKey {
        case responseTimeoutMs = "response_timeout_ms"
        case statusTtlMinutes = "status_ttl_minutes"
    }
    
    public init(responseTimeoutMs: Int = 2000, statusTtlMinutes: Int = 1440) {
        self.responseTimeoutMs = responseTimeoutMs
        self.statusTtlMinutes = statusTtlMinutes
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
    
    enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case ingestPath = "ingest_path"
        case ingestFilePath = "ingest_file_path"
        case timeoutMs = "timeout_ms"
    }
    
    public init(baseUrl: String = "http://gateway:8080",
                ingestPath: String = "/v1/ingest",
                ingestFilePath: String = "/v1/ingest/file",
                timeoutMs: Int = 30000) {
        self.baseUrl = baseUrl
        self.ingestPath = ingestPath
        self.ingestFilePath = ingestFilePath
        self.timeoutMs = timeoutMs
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseUrl = try container.decode(String.self, forKey: .baseUrl)
        self.ingestPath = try container.decode(String.self, forKey: .ingestPath)
        self.ingestFilePath = try container.decodeIfPresent(String.self, forKey: .ingestFilePath) ?? "/v1/ingest/file"
        
        // Support both timeout_ms (new) and timeout (legacy)
        if let timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) {
            self.timeoutMs = timeoutMs
        } else {
            // Legacy: try to decode as timeout (in seconds) and convert to ms
            let legacyKey = CodingKeys(stringValue: "timeout")!
            if let timeoutSecs = try container.decodeIfPresent(Int.self, forKey: legacyKey) {
                self.timeoutMs = timeoutSecs * 1000
            } else {
                self.timeoutMs = 30000
            }
        }
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
    
    enum CodingKeys: String, CodingKey {
        case imessage
        case ocr
        case entity
        case face
        case fswatch
        case localfs
        case contacts
        case mail
    }
    
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
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        imessage = try container.decode(IMessageModuleConfig.self, forKey: .imessage)
        ocr = try container.decode(OCRModuleConfig.self, forKey: .ocr)
        
        // New fields with defaults for backward compatibility
        entity = try container.decodeIfPresent(EntityModuleConfig.self, forKey: .entity) ?? EntityModuleConfig()
        face = try container.decodeIfPresent(FaceModuleConfig.self, forKey: .face) ?? FaceModuleConfig()
        
        fswatch = try container.decode(FSWatchModuleConfig.self, forKey: .fswatch)
        localfs = try container.decodeIfPresent(LocalFSModuleConfig.self, forKey: .localfs) ?? LocalFSModuleConfig()
        contacts = try container.decode(StubModuleConfig.self, forKey: .contacts)
        
        if let mailConfig = try container.decodeIfPresent(MailModuleConfig.self, forKey: .mail) {
            mail = mailConfig
        } else if let legacyMail = try container.decodeIfPresent(StubModuleConfig.self, forKey: .mail) {
            mail = MailModuleConfig(enabled: legacyMail.enabled)
        } else {
            mail = MailModuleConfig()
        }
        
        // Validate that no placeholder modules are present
        let allKeys = Set(container.allKeys.map { $0.stringValue })
        let placeholderKeys = ["calendar", "reminders", "notes"]
        let foundPlaceholders = allKeys.intersection(placeholderKeys)
        if !foundPlaceholders.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.imessage,
                in: container,
                debugDescription: "Placeholder modules are no longer supported: \(foundPlaceholders.joined(separator: ", ")). Please use Haven UI to configure these features."
            )
        }
    }
}

public struct IMessageModuleConfig: Codable {
    public var enabled: Bool
    public var ocrEnabled: Bool
    public var chatDbPath: String
    public var attachmentsPath: String
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case ocrEnabled = "ocr_enabled"
        case chatDbPath = "chat_db_path"
        case attachmentsPath = "attachments_path"
    }
    
    public init(enabled: Bool = true, ocrEnabled: Bool = false, chatDbPath: String = "", attachmentsPath: String = "") {
        self.enabled = enabled
        self.ocrEnabled = ocrEnabled
        self.chatDbPath = chatDbPath
        self.attachmentsPath = attachmentsPath
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        ocrEnabled = try container.decodeIfPresent(Bool.self, forKey: .ocrEnabled) ?? false
        chatDbPath = try container.decodeIfPresent(String.self, forKey: .chatDbPath) ?? ""
        attachmentsPath = try container.decodeIfPresent(String.self, forKey: .attachmentsPath) ?? ""
    }
}

public struct OCRModuleConfig: Codable {
    public var enabled: Bool
    public var languages: [String]
    public var timeoutMs: Int
    public var recognitionLevel: String
    public var includeLayout: Bool
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case languages
        case timeoutMs = "timeout_ms"
        case recognitionLevel = "recognition_level"
        case includeLayout = "include_layout"
    }
    
    public init(enabled: Bool = true, 
                languages: [String] = ["en"], 
                timeoutMs: Int = 2000,
                recognitionLevel: String = "fast",
                includeLayout: Bool = true) {
        self.enabled = enabled
        self.languages = languages
        self.timeoutMs = timeoutMs
        self.recognitionLevel = recognitionLevel
        self.includeLayout = includeLayout
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        enabled = try container.decode(Bool.self, forKey: .enabled)
        languages = try container.decode([String].self, forKey: .languages)
        timeoutMs = try container.decode(Int.self, forKey: .timeoutMs)
        
        // New fields with defaults for backward compatibility
        recognitionLevel = try container.decodeIfPresent(String.self, forKey: .recognitionLevel) ?? "fast"
        includeLayout = try container.decodeIfPresent(Bool.self, forKey: .includeLayout) ?? true
    }
}

public struct EntityModuleConfig: Codable {
    public var enabled: Bool
    public var types: [String]
    public var minConfidence: Float
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case types
        case minConfidence = "min_confidence"
    }
    
    public init(enabled: Bool = true, 
                types: [String] = ["person", "organization", "place"],
                minConfidence: Float = 0.0) {
        self.enabled = enabled
        self.types = types
        self.minConfidence = minConfidence
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        enabled = try container.decode(Bool.self, forKey: .enabled)
        types = try container.decode([String].self, forKey: .types)
        
        // New field with defaults for backward compatibility
        minConfidence = try container.decodeIfPresent(Float.self, forKey: .minConfidence) ?? 0.0
    }
}

public struct FaceModuleConfig: Codable {
    public var enabled: Bool
    public var minFaceSize: Double
    public var minConfidence: Double
    public var includeLandmarks: Bool
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case minFaceSize = "min_face_size"
        case minConfidence = "min_confidence"
        case includeLandmarks = "include_landmarks"
    }
    
    public init(enabled: Bool = true,
                minFaceSize: Double = 0.01,
                minConfidence: Double = 0.7,
                includeLandmarks: Bool = false) {
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
    public var debounceMs: Int
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case watches
        case eventQueueSize = "event_queue_size"
        case debounceMs = "debounce_ms"
    }
    
    public init(enabled: Bool = false, 
                watches: [FSWatchEntry] = [],
                eventQueueSize: Int = 1000,
                debounceMs: Int = 500) {
        self.enabled = enabled
        self.watches = watches
        self.eventQueueSize = eventQueueSize
        self.debounceMs = debounceMs
    }
    
    // Custom decoder to support legacy configs without these fields
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        watches = try container.decodeIfPresent([FSWatchEntry].self, forKey: .watches) ?? []
        eventQueueSize = try container.decodeIfPresent(Int.self, forKey: .eventQueueSize) ?? 1000
        debounceMs = try container.decodeIfPresent(Int.self, forKey: .debounceMs) ?? 500
    }
}

public struct LocalFSModuleConfig: Codable {
    public var enabled: Bool
    public var eventQueueSize: Int
    public var debounceMs: Int
    public var maxFileBytes: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case eventQueueSize = "event_queue_size"
        case debounceMs = "debounce_ms"
        case maxFileBytes = "max_file_bytes"
    }

    public init(
        enabled: Bool = false,
        eventQueueSize: Int = 1024,
        debounceMs: Int = 500,
        maxFileBytes: Int = 104857600
    ) {
        self.enabled = enabled
        self.eventQueueSize = eventQueueSize
        self.debounceMs = debounceMs
        self.maxFileBytes = maxFileBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        eventQueueSize = try container.decodeIfPresent(Int.self, forKey: .eventQueueSize) ?? 1024
        debounceMs = try container.decodeIfPresent(Int.self, forKey: .debounceMs) ?? 500
        maxFileBytes = try container.decodeIfPresent(Int.self, forKey: .maxFileBytes) ?? 104857600
        
        // Validate that no per-run fields are present
        let allKeys = Set(container.allKeys.map { $0.stringValue })
        let deprecatedKeys = ["default_watch_dir", "include", "exclude", "tags", "move_to", "delete_after", "dry_run", "one_shot", "state_file", "request_timeout", "follow_symlinks"]
        let foundDeprecated = allKeys.intersection(deprecatedKeys)
        if !foundDeprecated.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.enabled,
                in: container,
                debugDescription: "LocalFS module no longer supports per-run configuration in config file: \(foundDeprecated.joined(separator: ", ")). These must now be passed per-run via API calls from Haven UI."
            )
        }
    }
}

public struct FSWatchEntry: Codable, Identifiable {
    public var id: String
    public var path: String
    public var glob: String?
    public var target: String
    public var handoff: String
    
    public init(id: String = UUID().uuidString,
                path: String,
                glob: String? = nil,
                target: String = "gateway",
                handoff: String = "presigned") {
        self.id = id
        self.path = path
        self.glob = glob
        self.target = target
        self.handoff = handoff
    }
}

public struct StubModuleConfig: Codable {
    public var enabled: Bool
    
    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

public struct LoggingConfig: Codable {
    public var level: String
    public var format: String
    public var paths: LoggingPathsConfig
    
    enum CodingKeys: String, CodingKey {
        case level
        case format
        case paths
    }
    
    public init(level: String = "info", format: String = "json", paths: LoggingPathsConfig = LoggingPathsConfig()) {
        self.level = level
        self.format = format
        self.paths = paths
    }
}

public struct LoggingPathsConfig: Codable {
    public var app: String
    public var error: String
    public var access: String
    
    enum CodingKeys: String, CodingKey {
        case app
        case error
        case access
    }
    
    public init(app: String = "~/.haven/hostagent.log", error: String = "~/.haven/hostagent_error.log", access: String = "~/.haven/hostagent_access.log") {
        self.app = app
        self.error = error
        self.access = access
    }
}

// MARK: - Mail Module Configuration

// MARK: - PII Redaction Configuration

public enum RedactionConfig: Codable {
    case boolean(Bool)
    case detailed(RedactionOptions)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try to decode as boolean first
        if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
            return
        }
        
        // Try to decode as detailed options
        if let options = try? container.decode(RedactionOptions.self) {
            self = .detailed(options)
            return
        }
        
        throw DecodingError.typeMismatch(RedactionConfig.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Bool or RedactionOptions"))
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .boolean(let value):
            try container.encode(value)
        case .detailed(let options):
            try container.encode(options)
        }
    }
}

public struct RedactionOptions: Codable {
    public var emails: Bool
    public var phones: Bool
    public var accountNumbers: Bool
    public var ssn: Bool
    
    enum CodingKeys: String, CodingKey {
        case emails
        case phones
        case accountNumbers = "account_numbers"
        case ssn
    }
    
    public init(emails: Bool = true, phones: Bool = true, accountNumbers: Bool = true, ssn: Bool = true) {
        self.emails = emails
        self.phones = phones
        self.accountNumbers = accountNumbers
        self.ssn = ssn
    }
}

public struct MailSourceConfig: Codable {
    public var id: String
    public var type: String  // "local", "imap"
    public var enabled: Bool
    public var redactPii: RedactionConfig?
    // Local-specific
    public var sourcePath: String?
    // IMAP-specific
    public var host: String?
    public var port: Int?
    public var tls: Bool?
    public var username: String?
    public var auth: MailSourceAuthConfig?
    public var folders: [String]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case enabled
        case redactPii = "redact_pii"
        case sourcePath = "source_path"
        case host
        case port
        case tls
        case username
        case auth
        case folders
    }
    
    public init(id: String = "",
                type: String = "imap",
                enabled: Bool = true,
                redactPii: RedactionConfig? = nil,
                sourcePath: String? = nil,
                host: String? = nil,
                port: Int? = nil,
                tls: Bool? = nil,
                username: String? = nil,
                auth: MailSourceAuthConfig? = nil,
                folders: [String]? = nil) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.redactPii = redactPii
        self.sourcePath = sourcePath
        self.host = host
        self.port = port
        self.tls = tls
        self.username = username
        self.auth = auth
        self.folders = folders
    }
}

public struct MailSourceAuthConfig: Codable {
    public var kind: String
    public var secretRef: String
    
    enum CodingKeys: String, CodingKey {
        case kind
        case secretRef = "secret_ref"
    }
    
    public init(kind: String = "app_password", secretRef: String = "") {
        self.kind = kind
        self.secretRef = secretRef
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "app_password"
        secretRef = try container.decodeIfPresent(String.self, forKey: .secretRef) ?? ""
    }
}

extension MailSourceConfig {
    public var responseIdentifier: String {
        if !id.isEmpty {
            return id
        }
        return username?.isEmpty == false ? username! : (host ?? "unknown")
    }
    
    public var debugIdentifier: String {
        "\(responseIdentifier)@\(host ?? "unknown")"
    }
}

public struct MailModuleConfig: Codable {
    public var enabled: Bool
    public var redactPii: RedactionConfig?
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case redactPii = "redact_pii"
    }
    
    public init(
        enabled: Bool = false,
        redactPii: RedactionConfig? = nil
    ) {
        self.enabled = enabled
        self.redactPii = redactPii
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        redactPii = try container.decodeIfPresent(RedactionConfig.self, forKey: .redactPii)
        
        // Validate that no per-run fields are present (sources, filters, state, etc.)
        let allKeys = Set(container.allKeys.map { $0.stringValue })
        let deprecatedKeys = ["sources", "filters", "state", "default_order", "default_since", "default_until", "allow_override"]
        let foundDeprecated = allKeys.intersection(deprecatedKeys)
        if !foundDeprecated.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.enabled,
                in: container,
                debugDescription: "Mail module no longer supports per-run configuration in config file: \(foundDeprecated.joined(separator: ", ")). These must now be passed per-run via API calls from Haven UI."
            )
        }
    }
}

public struct MailStateConfig: Codable {
    public var clearOnNewRun: Bool
    public var runStatePath: String
    public var rejectedLogPath: String
    public var lockFilePath: String
    public var rejectedRetentionDays: Int

    enum CodingKeys: String, CodingKey {
        case clearOnNewRun = "clear_on_new_run"
        case runStatePath = "run_state_path"
        case rejectedLogPath = "rejected_log_path"
        case lockFilePath = "lock_file_path"
        case rejectedRetentionDays = "rejected_retention_days"
    }

    public init(
        clearOnNewRun: Bool = true,
        runStatePath: String = "~/.haven/email_collector_state_run.json",
        rejectedLogPath: String = "~/.haven/rejected_emails.log",
        lockFilePath: String = "~/.haven/email_collector.lock",
        rejectedRetentionDays: Int = 30
    ) {
        self.clearOnNewRun = clearOnNewRun
        self.runStatePath = runStatePath
        self.rejectedLogPath = rejectedLogPath
        self.lockFilePath = lockFilePath
        self.rejectedRetentionDays = rejectedRetentionDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clearOnNewRun = try container.decodeIfPresent(Bool.self, forKey: .clearOnNewRun) ?? true
        runStatePath = try container.decodeIfPresent(String.self, forKey: .runStatePath) ?? "~/.haven/email_collector_state_run.json"
        rejectedLogPath = try container.decodeIfPresent(String.self, forKey: .rejectedLogPath) ?? "~/.haven/rejected_emails.log"
        lockFilePath = try container.decodeIfPresent(String.self, forKey: .lockFilePath) ?? "~/.haven/email_collector.lock"
        rejectedRetentionDays = try container.decodeIfPresent(Int.self, forKey: .rejectedRetentionDays) ?? 30
    }
}

public struct MailFiltersConfig: Codable {
    public var combinationMode: MailFilterCombinationMode
    public var defaultAction: MailFilterDefaultAction
    public var inline: [MailFilterExpression]
    public var files: [String]
    public var environmentVariable: String?
    public var prefilter: MailPrefilterConfig
    
    enum CodingKeys: String, CodingKey {
        case combinationMode = "combination_mode"
        case defaultAction = "default_action"
        case inline
        case files
        case environmentVariable = "environment_variable"
        case prefilter
    }
    
    public init(
        combinationMode: MailFilterCombinationMode = .any,
        defaultAction: MailFilterDefaultAction = .include,
        inline: [MailFilterExpression] = [],
        files: [String] = [MailFiltersConfig.defaultFiltersPath],
        environmentVariable: String? = "EMAIL_COLLECTOR_FILTERS",
        prefilter: MailPrefilterConfig = MailPrefilterConfig()
    ) {
        self.combinationMode = combinationMode
        self.defaultAction = defaultAction
        self.inline = inline
        self.files = files
        self.environmentVariable = environmentVariable
        self.prefilter = prefilter
    }
    
    public static var defaultFiltersPath: String {
        return "~/.haven/email_collector_filters.yaml"
    }
}

public struct MailPrefilterConfig: Codable {
    public var includeFolders: [String] = []
    public var excludeFolders: [String] = []
    public var vipOnly: Bool = false
    public var requireListUnsubscribe: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case includeFolders = "include_folders"
        case excludeFolders = "exclude_folders"
        case vipOnly = "vip_only"
        case requireListUnsubscribe = "require_list_unsubscribe"
    }
    
    public init(includeFolders: [String] = [],
                excludeFolders: [String] = [],
                vipOnly: Bool = false,
                requireListUnsubscribe: Bool = false) {
        self.includeFolders = includeFolders
        self.excludeFolders = excludeFolders
        self.vipOnly = vipOnly
        self.requireListUnsubscribe = requireListUnsubscribe
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeFolders = try container.decodeIfPresent([String].self, forKey: .includeFolders) ?? []
        excludeFolders = try container.decodeIfPresent([String].self, forKey: .excludeFolders) ?? []
        vipOnly = try container.decodeIfPresent(Bool.self, forKey: .vipOnly) ?? false
        requireListUnsubscribe = try container.decodeIfPresent(Bool.self, forKey: .requireListUnsubscribe) ?? false
    }
}

public enum MailFilterCombinationMode: String, Codable {
    case any
    case all
}

public enum MailFilterDefaultAction: String, Codable {
    case include
    case exclude
}

// MARK: - Config Loading

public enum ConfigError: Error, LocalizedError {
    case fileNotFound(String)
    case parseError(String)
    case validationError(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Configuration file not found: \(path)"
        case .parseError(let msg):
            return "Failed to parse configuration: \(msg)"
        case .validationError(let msg):
            return "Configuration validation failed: \(msg)"
        }
    }
}

public class ConfigLoader {
    private let logger = HavenLogger(category: "config")
    
    public init() {}
    
    /// Load configuration from YAML file with environment variable overrides
    public func load(from path: String? = nil) throws -> HavenConfig {
        let configPath = path ?? defaultConfigPath()
        
        // Start with defaults
        var config = HavenConfig()
        // Ensure default config is present in user's ~/.haven when no explicit config provided
        if path == nil {
            ensureDefaultConfigExists(at: configPath)
        }

        // Load from file if it exists
        if FileManager.default.fileExists(atPath: configPath) {
            logger.info("Loading configuration from \(configPath)")
            let url = URL(fileURLWithPath: configPath)
            let data = try Data(contentsOf: url)

            // Parse YAML - if parsing fails, log and continue using defaults
            let decoder = YAMLDecoder()
            do {
                config = try decoder.decode(HavenConfig.self, from: data)
            } catch {
                logger.error("Failed to parse configuration file; using defaults", metadata: ["error": "\(error)"])
                // Keep `config` as initialized defaults and continue
            }
        } else {
            logger.warning("Configuration file not found at \(configPath), using defaults")
        }
        
        // Apply environment variable overrides
        applyEnvironmentOverrides(&config)
        
        // Validate
        try validate(config)
        
        return config
    }
    
    public func save(_ config: HavenConfig, to path: String? = nil) throws {
        let configPath = path ?? defaultConfigPath()
        let url = URL(fileURLWithPath: configPath)
        
        // Ensure directory exists
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        // Encode to YAML
        let encoder = YAMLEncoder()
        let data = try encoder.encode(config)
        try data.write(to: url)
        
        logger.info("Saved configuration to \(configPath)")
    }
    
    private func defaultConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".haven/hostagent.yaml").path
    }

    /// Ensure the default config file is copied from bundled resources to the user's ~/.haven
    /// if no explicit config path was provided and the file does not already exist.
    private func ensureDefaultConfigExists(at configPath: String) {
        // If config already exists, nothing to do
        if FileManager.default.fileExists(atPath: configPath) {
            return
        }

        // Attempt to locate the bundled default config in package resources
        var defaultConfigURL: URL? = nil
        // Try a few candidate locations within the repository layout for Resources/default-config.yaml
        var candidates: [URL] = []

        // 1) Resources/ relative to this package directory (source layout)
        let currentFileURL = URL(fileURLWithPath: #file)
        let packageDir = currentFileURL.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(packageDir.appendingPathComponent("Resources/default-config.yaml"))

        // 2) Resources/ relative to current working directory (when running from hostagent folder)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/default-config.yaml"))
        candidates.append(cwd.appendingPathComponent("../Resources/default-config.yaml"))

        // 3) workspace-relative hostagent/Resources (when running from repo root)
        candidates.append(cwd.appendingPathComponent("hostagent/Resources/default-config.yaml"))

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                defaultConfigURL = candidate
                break
            }
        }

        guard let src = defaultConfigURL else {
            logger.info("No bundled default-config.yaml found; skipping copy to \(configPath)")
            return
        }

        do {
            let destURL = URL(fileURLWithPath: configPath)
            let dir = destURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destURL.path) == false {
                try FileManager.default.copyItem(at: src, to: destURL)
                logger.info("Created default config at \(configPath)")
            }
        } catch {
            logger.error("Failed to copy default config to \(configPath)", metadata: ["error": "\(error)"])
        }
    }
    
    private func applyEnvironmentOverrides(_ config: inout HavenConfig) {
        if let port = ProcessInfo.processInfo.environment["HAVEN_PORT"],
           let portInt = Int(port) {
            config.service.port = portInt
        }
        
        if let secret = ProcessInfo.processInfo.environment["HAVEN_AUTH_SECRET"] {
            config.service.auth.secret = secret
        }
        
        if let gatewayUrl = ProcessInfo.processInfo.environment["HAVEN_GATEWAY_URL"] {
            config.gateway.baseUrl = gatewayUrl
        }
        
        if let logLevel = ProcessInfo.processInfo.environment["HAVEN_LOG_LEVEL"] {
            config.logging.level = logLevel
        }
        
        if let chatDbPath = ProcessInfo.processInfo.environment["HAVEN_IMESSAGE_CHAT_DB_PATH"] {
            config.modules.imessage.chatDbPath = chatDbPath
        }
        if let mailEnabled = ProcessInfo.processInfo.environment["HAVEN_MAIL_ENABLED"] {
            config.modules.mail.enabled = (mailEnabled as NSString).boolValue
        }
    }
    
    private func validate(_ config: HavenConfig) throws {
        if config.service.port < 1024 || config.service.port > 65535 {
            throw ConfigError.validationError("Port must be between 1024 and 65535")
        }
        
        if config.service.auth.secret.isEmpty || config.service.auth.secret == "changeme" {
            logger.warning("Using default auth secret - this is insecure!")
        }
        
        if config.gateway.baseUrl.isEmpty {
            throw ConfigError.validationError("Gateway base URL cannot be empty")
        }
    }
    
    internal func validateConfiguration(_ config: HavenConfig) throws {
        try validate(config)
    }
}

// MARK: - YAML Coding Support

import Yams

struct YAMLDecoder {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let string = String(data: data, encoding: .utf8) ?? ""
        let node = try Yams.compose(yaml: string)
        
        guard let node = node else {
            throw ConfigError.parseError("Empty YAML document")
        }
        
        let decoder = YAMLNodeDecoder()
        return try decoder.decode(type, from: node)
    }
}

struct YAMLEncoder {
    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(value)
        
        // Convert JSON to dictionary, then to YAML
        let json = try JSONSerialization.jsonObject(with: jsonData)
        let yaml = try Yams.dump(object: json)
        
        guard let data = yaml.data(using: .utf8) else {
            throw ConfigError.parseError("Failed to encode YAML")
        }
        
        return data
    }
}

// Simple YAML node decoder
struct YAMLNodeDecoder {
    func decode<T: Decodable>(_ type: T.Type, from node: Yams.Node) throws -> T {
        // Convert YAML node to JSON-compatible object
        let object = nodeToObject(node)
        
        // Use JSONDecoder to decode from the object
        let jsonData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: jsonData)
    }
    
    private func nodeToObject(_ node: Yams.Node) -> Any {
        switch node {
        case .scalar(let scalar):
            // Try to parse as number or bool
            if let int = Int(scalar.string) {
                return int
            } else if let double = Double(scalar.string) {
                return double
            } else if scalar.string == "true" {
                return true
            } else if scalar.string == "false" {
                return false
            } else {
                return scalar.string
            }
            
        case .mapping(let mapping):
            var dict = [String: Any]()
            for (key, value) in mapping {
                if case .scalar(let keyScalar) = key {
                    dict[keyScalar.string] = nodeToObject(value)
                }
            }
            return dict
            
        case .sequence(let sequence):
            return sequence.map { nodeToObject($0) }
            
        case .alias:
            // Aliases should be dereferenced before this point
            return NSNull()
        }
    }
}
