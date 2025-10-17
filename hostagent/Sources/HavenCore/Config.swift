import Foundation

/// Global application configuration
public struct HavenConfig: Codable {
    public var port: Int
    public var auth: AuthConfig
    public var gateway: GatewayConfig
    public var modules: ModulesConfig
    public var logging: LoggingConfig
    
    public init(port: Int = 7090,
                auth: AuthConfig = AuthConfig(),
                gateway: GatewayConfig = GatewayConfig(),
                modules: ModulesConfig = ModulesConfig(),
                logging: LoggingConfig = LoggingConfig()) {
        self.port = port
        self.auth = auth
        self.gateway = gateway
        self.modules = modules
        self.logging = logging
    }
}

public struct AuthConfig: Codable {
    public var header: String
    public var secret: String
    
    public init(header: String = "x-auth", secret: String = "change-me") {
        self.header = header
        self.secret = secret
    }
}

public struct GatewayConfig: Codable {
    public var baseUrl: String
    public var ingestPath: String
    public var timeout: Int
    
    enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case ingestPath = "ingest_path"
        case timeout
    }
    
    public init(baseUrl: String = "http://gateway:8080",
                ingestPath: String = "/v1/ingest",
                timeout: Int = 30) {
        self.baseUrl = baseUrl
        self.ingestPath = ingestPath
        self.timeout = timeout
    }
}

public struct ModulesConfig: Codable {
    public var imessage: IMessageModuleConfig
    public var ocr: OCRModuleConfig
    public var entity: EntityModuleConfig
    public var face: FaceModuleConfig
    public var fswatch: FSWatchModuleConfig
    public var contacts: StubModuleConfig
    public var calendar: StubModuleConfig
    public var reminders: StubModuleConfig
    public var mail: StubModuleConfig
    public var notes: StubModuleConfig
    
    public init(imessage: IMessageModuleConfig = IMessageModuleConfig(),
                ocr: OCRModuleConfig = OCRModuleConfig(),
                entity: EntityModuleConfig = EntityModuleConfig(),
                face: FaceModuleConfig = FaceModuleConfig(),
                fswatch: FSWatchModuleConfig = FSWatchModuleConfig(),
                contacts: StubModuleConfig = StubModuleConfig(),
                calendar: StubModuleConfig = StubModuleConfig(),
                reminders: StubModuleConfig = StubModuleConfig(),
                mail: StubModuleConfig = StubModuleConfig(),
                notes: StubModuleConfig = StubModuleConfig()) {
        self.imessage = imessage
        self.ocr = ocr
        self.entity = entity
        self.face = face
        self.fswatch = fswatch
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
        contacts = try container.decode(StubModuleConfig.self, forKey: .contacts)
        calendar = try container.decode(StubModuleConfig.self, forKey: .calendar)
        reminders = try container.decode(StubModuleConfig.self, forKey: .reminders)
        mail = try container.decode(StubModuleConfig.self, forKey: .mail)
        notes = try container.decode(StubModuleConfig.self, forKey: .notes)
    }
}

public struct IMessageModuleConfig: Codable {
    public var enabled: Bool
    public var batchSize: Int
    public var ocrEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case batchSize = "batch_size"
        case ocrEnabled = "ocr_enabled"
    }
    
    public init(enabled: Bool = true, batchSize: Int = 500, ocrEnabled: Bool = true) {
        self.enabled = enabled
        self.batchSize = batchSize
        self.ocrEnabled = ocrEnabled
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
    
    public init(enabled: Bool = false, watches: [FSWatchEntry] = []) {
        self.enabled = enabled
        self.watches = watches
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
        
        // Load from file if it exists
        if FileManager.default.fileExists(atPath: configPath) {
            logger.info("Loading configuration from \(configPath)")
            let url = URL(fileURLWithPath: configPath)
            let data = try Data(contentsOf: url)
            
            // Parse YAML
            let decoder = YAMLDecoder()
            config = try decoder.decode(HavenConfig.self, from: data)
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
    }
    
    private func validate(_ config: HavenConfig) throws {
        if config.port < 1024 || config.port > 65535 {
            throw ConfigError.validationError("Port must be between 1024 and 65535")
        }
        
        if config.auth.secret.isEmpty || config.auth.secret == "change-me" {
            logger.warning("Using default auth secret - this is insecure!")
        }
        
        if config.gateway.baseUrl.isEmpty {
            throw ConfigError.validationError("Gateway base URL cannot be empty")
        }
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
