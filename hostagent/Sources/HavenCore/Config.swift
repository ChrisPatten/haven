import Foundation

/// Global application configuration
public struct HavenConfig: Codable {
    public var port: Int
    public var defaultLimit: Int
    public var auth: AuthConfig
    public var gateway: GatewayConfig
    public var modules: ModulesConfig
    public var logging: LoggingConfig
    
    enum CodingKeys: String, CodingKey {
        case port
        case defaultLimit = "default_limit"
        case auth
        case gateway
        case modules
        case logging
    }
    
    public init(port: Int = 7090,
                defaultLimit: Int = 100,
                auth: AuthConfig = AuthConfig(),
                gateway: GatewayConfig = GatewayConfig(),
                modules: ModulesConfig = ModulesConfig(),
                logging: LoggingConfig = LoggingConfig()) {
        self.port = port
        self.defaultLimit = defaultLimit
        self.auth = auth
        self.gateway = gateway
        self.modules = modules
        self.logging = logging
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
    public var timeout: Int
    
    enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case ingestPath = "ingest_path"
        case ingestFilePath = "ingest_file_path"
        case timeout
    }
    
    public init(baseUrl: String = "http://gateway:8080",
                ingestPath: String = "/v1/ingest",
                ingestFilePath: String = "/v1/ingest/file",
                timeout: Int = 30) {
        self.baseUrl = baseUrl
        self.ingestPath = ingestPath
        self.ingestFilePath = ingestFilePath
        self.timeout = timeout
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseUrl = try container.decode(String.self, forKey: .baseUrl)
        self.ingestPath = try container.decode(String.self, forKey: .ingestPath)
        self.ingestFilePath = try container.decodeIfPresent(String.self, forKey: .ingestFilePath) ?? "/v1/ingest/file"
        self.timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 30
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
    public var calendar: StubModuleConfig
    public var reminders: StubModuleConfig
    public var mail: MailModuleConfig
    public var notes: StubModuleConfig
    
    enum CodingKeys: String, CodingKey {
        case imessage
        case ocr
        case entity
        case face
        case fswatch
        case localfs
        case contacts
        case calendar
        case reminders
        case mail
        case notes
    }
    
    public init(imessage: IMessageModuleConfig = IMessageModuleConfig(),
                ocr: OCRModuleConfig = OCRModuleConfig(),
                entity: EntityModuleConfig = EntityModuleConfig(),
                face: FaceModuleConfig = FaceModuleConfig(),
                fswatch: FSWatchModuleConfig = FSWatchModuleConfig(),
                localfs: LocalFSModuleConfig = LocalFSModuleConfig(),
                contacts: StubModuleConfig = StubModuleConfig(),
                calendar: StubModuleConfig = StubModuleConfig(),
                reminders: StubModuleConfig = StubModuleConfig(),
                mail: MailModuleConfig = MailModuleConfig(),
                notes: StubModuleConfig = StubModuleConfig()) {
        self.imessage = imessage
        self.ocr = ocr
        self.entity = entity
        self.face = face
        self.fswatch = fswatch
        self.localfs = localfs
        self.contacts = contacts
        self.calendar = calendar
        self.reminders = reminders
        self.mail = mail
        self.notes = notes
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
        calendar = try container.decode(StubModuleConfig.self, forKey: .calendar)
        reminders = try container.decode(StubModuleConfig.self, forKey: .reminders)
        
        if let mailConfig = try container.decodeIfPresent(MailModuleConfig.self, forKey: .mail) {
            mail = mailConfig
        } else if let legacyMail = try container.decodeIfPresent(StubModuleConfig.self, forKey: .mail) {
            mail = MailModuleConfig(enabled: legacyMail.enabled)
        } else {
            mail = MailModuleConfig()
        }
        notes = try container.decode(StubModuleConfig.self, forKey: .notes)
    }
}

public struct IMessageModuleConfig: Codable {
    public var enabled: Bool
    public var ocrEnabled: Bool
    public var chatDbPath: String
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case ocrEnabled = "ocr_enabled"
        case chatDbPath = "chat_db_path"
    }
    
    public init(enabled: Bool = true, ocrEnabled: Bool = true, chatDbPath: String = "") {
        self.enabled = enabled
        self.ocrEnabled = ocrEnabled
        self.chatDbPath = chatDbPath
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        ocrEnabled = try container.decode(Bool.self, forKey: .ocrEnabled)
        chatDbPath = try container.decodeIfPresent(String.self, forKey: .chatDbPath) ?? ""
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
    public var defaultWatchDir: String?
    public var include: [String]
    public var exclude: [String]
    public var tags: [String]
    public var moveTo: String?
    public var deleteAfter: Bool
    public var dryRun: Bool
    public var oneShot: Bool
    public var stateFile: String
    public var maxFileBytes: Int
    public var requestTimeout: Double
    public var followSymlinks: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case defaultWatchDir = "default_watch_dir"
        case include
        case exclude
        case tags
        case moveTo = "move_to"
        case deleteAfter = "delete_after"
        case dryRun = "dry_run"
        case oneShot = "one_shot"
        case stateFile = "state_file"
        case maxFileBytes = "max_file_bytes"
        case requestTimeout = "request_timeout"
        case followSymlinks = "follow_symlinks"
    }

    public init(
        enabled: Bool = false,
        defaultWatchDir: String? = nil,
        include: [String] = ["*.txt", "*.md", "*.pdf", "*.png", "*.jpg", "*.jpeg", "*.heic"],
        exclude: [String] = ["*.tmp", "~*"],
        tags: [String] = [],
        moveTo: String? = nil,
        deleteAfter: Bool = false,
        dryRun: Bool = false,
        oneShot: Bool = true,
        stateFile: String = "~/.haven/localfs_collector_state.json",
        maxFileBytes: Int = 10 * 1024 * 1024,
        requestTimeout: Double = 30.0,
        followSymlinks: Bool = false
    ) {
        self.enabled = enabled
        self.defaultWatchDir = defaultWatchDir
        self.include = include
        self.exclude = exclude
        self.tags = tags
        self.moveTo = moveTo
        self.deleteAfter = deleteAfter
        self.dryRun = dryRun
        self.oneShot = oneShot
        self.stateFile = stateFile
        self.maxFileBytes = maxFileBytes
        self.requestTimeout = requestTimeout
        self.followSymlinks = followSymlinks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        defaultWatchDir = try container.decodeIfPresent(String.self, forKey: .defaultWatchDir)
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? ["*.txt", "*.md", "*.pdf", "*.png", "*.jpg", "*.jpeg", "*.heic"]
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? ["*.tmp", "~*"]
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
        deleteAfter = try container.decodeIfPresent(Bool.self, forKey: .deleteAfter) ?? false
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        oneShot = try container.decodeIfPresent(Bool.self, forKey: .oneShot) ?? true
        stateFile = try container.decodeIfPresent(String.self, forKey: .stateFile) ?? "~/.haven/localfs_collector_state.json"
        maxFileBytes = try container.decodeIfPresent(Int.self, forKey: .maxFileBytes) ?? 10 * 1024 * 1024
        requestTimeout = try container.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? 30.0
        followSymlinks = try container.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? false
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
    
    public init(level: String = "info", format: String = "json") {
        self.level = level
        self.format = format
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
    public var sources: [MailSourceConfig]
    public var filters: MailFiltersConfig
    public var state: MailStateConfig
    public var defaultOrder: String?
    public var defaultSince: String?
    public var defaultUntil: String?
    public var allowOverride: Bool
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case redactPii = "redact_pii"
        case sources
        case filters
        case state
        case defaultOrder = "default_order"
        case defaultSince = "default_since"
        case defaultUntil = "default_until"
        case allowOverride = "allow_override"
    }
    
    public init(
        enabled: Bool = false,
        redactPii: RedactionConfig? = nil,
        sources: [MailSourceConfig] = [],
        filters: MailFiltersConfig = MailFiltersConfig(),
        state: MailStateConfig = MailStateConfig(),
        defaultOrder: String? = nil,
        defaultSince: String? = nil,
        defaultUntil: String? = nil,
        allowOverride: Bool = true
    ) {
        self.enabled = enabled
        self.redactPii = redactPii
        self.sources = sources
        self.filters = filters
        self.state = state
        self.defaultOrder = defaultOrder
        self.defaultSince = defaultSince
        self.defaultUntil = defaultUntil
        self.allowOverride = allowOverride
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        redactPii = try container.decodeIfPresent(RedactionConfig.self, forKey: .redactPii)
        sources = try container.decodeIfPresent([MailSourceConfig].self, forKey: .sources) ?? []
        filters = try container.decodeIfPresent(MailFiltersConfig.self, forKey: .filters) ?? MailFiltersConfig()
        state = try container.decodeIfPresent(MailStateConfig.self, forKey: .state) ?? MailStateConfig()
        defaultOrder = try container.decodeIfPresent(String.self, forKey: .defaultOrder)
        defaultSince = try container.decodeIfPresent(String.self, forKey: .defaultSince)
        defaultUntil = try container.decodeIfPresent(String.self, forKey: .defaultUntil)
        allowOverride = try container.decodeIfPresent(Bool.self, forKey: .allowOverride) ?? true
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
            config.port = portInt
        }
        
        if let secret = ProcessInfo.processInfo.environment["HAVEN_AUTH_SECRET"] {
            config.auth.secret = secret
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
        if config.port < 1024 || config.port > 65535 {
            throw ConfigError.validationError("Port must be between 1024 and 65535")
        }
        
        if config.auth.secret.isEmpty || config.auth.secret == "changeme" {
            logger.warning("Using default auth secret - this is insecure!")
        }
        
        if config.gateway.baseUrl.isEmpty {
            throw ConfigError.validationError("Gateway base URL cannot be empty")
        }
        
        // No longer need to check for mail/mailImap conflicts since mailImap is removed
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
