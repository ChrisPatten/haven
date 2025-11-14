//
//  SystemConfig.swift
//  Haven
//
//  System-level configuration for Haven.app
//  Persisted in ~/.haven/system.plist
//

import Foundation

/// System-level configuration matching system.plist structure
public struct SystemConfig: Codable, Equatable, @unchecked Sendable {
    public var service: SystemServiceConfig
    public var api: SystemApiConfig
    public var gateway: SystemGatewayConfig
    public var logging: SystemLoggingConfig
    public var modules: ModulesEnablementConfig
    public var advanced: AdvancedModuleSettings
    public var selfIdentifier: String?
    
    enum CodingKeys: String, CodingKey {
        case service
        case api
        case gateway
        case logging
        case modules
        case advanced
        case selfIdentifier = "self_identifier"
    }
    
    public init(
        service: SystemServiceConfig = SystemServiceConfig(),
        api: SystemApiConfig = SystemApiConfig(),
        gateway: SystemGatewayConfig = SystemGatewayConfig(),
        logging: SystemLoggingConfig = SystemLoggingConfig(),
        modules: ModulesEnablementConfig = ModulesEnablementConfig(),
        advanced: AdvancedModuleSettings = AdvancedModuleSettings(),
        selfIdentifier: String? = nil
    ) {
        self.service = service
        self.api = api
        self.gateway = gateway
        self.logging = logging
        self.modules = modules
        self.advanced = advanced
        self.selfIdentifier = selfIdentifier
    }
}

/// Service configuration (port, auth)
public struct SystemServiceConfig: Codable, Equatable {
    public var port: Int
    public var auth: SystemAuthConfig
    
    public init(port: Int = 7090, auth: SystemAuthConfig = SystemAuthConfig()) {
        self.port = port
        self.auth = auth
    }
}

/// Authentication configuration
public struct SystemAuthConfig: Codable, Equatable {
    public var header: String
    public var secret: String
    
    public init(header: String = "X-Haven-Key", secret: String = "changeme") {
        self.header = header
        self.secret = secret
    }
}

/// API configuration (timeouts, TTL)
public struct SystemApiConfig: Codable, Equatable {
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

/// Gateway configuration
public struct SystemGatewayConfig: Codable, Equatable {
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
    
    public init(
        baseUrl: String = "http://localhost:8085",
        ingestPath: String = "/v1/ingest",
        ingestFilePath: String = "/v1/ingest/file",
        timeoutMs: Int = 30000
    ) {
        self.baseUrl = baseUrl
        self.ingestPath = ingestPath
        self.ingestFilePath = ingestFilePath
        self.timeoutMs = timeoutMs
    }
}

/// Logging configuration
public struct SystemLoggingConfig: Codable, Equatable {
    public var level: String
    public var format: String
    public var paths: SystemLoggingPathsConfig
    
    public init(
        level: String = "info",
        format: String = "json",
        paths: SystemLoggingPathsConfig = SystemLoggingPathsConfig()
    ) {
        self.level = level
        self.format = format
        self.paths = paths
    }
}

/// Logging paths configuration
public struct SystemLoggingPathsConfig: Codable, Equatable {
    public var app: String
    public var error: String?  // Deprecated: kept for backward compatibility, not used
    public var access: String
    
    public init(
        app: String = "",
        error: String? = nil,
        access: String = ""
    ) {
        // Default to HavenFilePaths if empty
        self.app = app.isEmpty ? HavenFilePaths.logFile("hostagent.log").path : app
        self.error = error
        self.access = access.isEmpty ? HavenFilePaths.logFile("hostagent_access.log").path : access
    }
}

/// Module enablement flags
public struct ModulesEnablementConfig: Codable, Equatable {
    public var imessage: Bool
    public var ocr: Bool
    public var entity: Bool
    public var face: Bool
    public var fswatch: Bool
    public var localfs: Bool
    public var contacts: Bool
    public var mail: Bool
    public var reminders: Bool
    
    public init(
        imessage: Bool = true,
        ocr: Bool = true,
        entity: Bool = true,
        face: Bool = true,
        fswatch: Bool = true,
        localfs: Bool = true,
        contacts: Bool = true,
        mail: Bool = true,
        reminders: Bool = true
    ) {
        self.imessage = imessage
        self.ocr = ocr
        self.entity = entity
        self.face = face
        self.fswatch = fswatch
        self.localfs = localfs
        self.contacts = contacts
        self.mail = mail
        self.reminders = reminders
    }
}

/// Advanced module settings
public struct AdvancedModuleSettings: Codable, Equatable {
    public var ocr: OCRModuleSettings
    public var entity: EntityModuleSettings
    public var face: FaceModuleSettings
    public var caption: CaptionModuleSettings
    public var fswatch: FSWatchModuleSettings
    public var localfs: LocalFSModuleSettings
    public var debug: DebugSettings
    
    public init(
        ocr: OCRModuleSettings = OCRModuleSettings(),
        entity: EntityModuleSettings = EntityModuleSettings(),
        face: FaceModuleSettings = FaceModuleSettings(),
        caption: CaptionModuleSettings = CaptionModuleSettings(),
        fswatch: FSWatchModuleSettings = FSWatchModuleSettings(),
        localfs: LocalFSModuleSettings = LocalFSModuleSettings(),
        debug: DebugSettings = DebugSettings()
    ) {
        self.ocr = ocr
        self.entity = entity
        self.face = face
        self.caption = caption
        self.fswatch = fswatch
        self.localfs = localfs
        self.debug = debug
    }
}

/// OCR module settings
public struct OCRModuleSettings: Codable, Equatable {
    public var languages: [String]
    public var timeoutMs: Int
    public var recognitionLevel: String
    public var includeLayout: Bool
    
    enum CodingKeys: String, CodingKey {
        case languages
        case timeoutMs = "timeout_ms"
        case recognitionLevel = "recognition_level"
        case includeLayout = "include_layout"
    }
    
    public init(
        languages: [String] = ["en"],
        timeoutMs: Int = 15000,
        recognitionLevel: String = "accurate",
        includeLayout: Bool = false
    ) {
        self.languages = languages
        self.timeoutMs = timeoutMs
        self.recognitionLevel = recognitionLevel
        self.includeLayout = includeLayout
    }
}

/// Entity module settings
public struct EntityModuleSettings: Codable, Equatable {
    public var types: [String]
    public var minConfidence: Float
    
    enum CodingKeys: String, CodingKey {
        case types
        case minConfidence = "min_confidence"
    }
    
    public init(
        types: [String] = ["person", "organization", "place"],
        minConfidence: Float = 0.6
    ) {
        self.types = types
        self.minConfidence = minConfidence
    }
}

/// Face module settings
public struct FaceModuleSettings: Codable, Equatable {
    public var minFaceSize: Double
    public var minConfidence: Double
    public var includeLandmarks: Bool
    
    enum CodingKeys: String, CodingKey {
        case minFaceSize = "min_face_size"
        case minConfidence = "min_confidence"
        case includeLandmarks = "include_landmarks"
    }
    
    public init(
        minFaceSize: Double = 0.01,
        minConfidence: Double = 0.7,
        includeLandmarks: Bool = false
    ) {
        self.minFaceSize = minFaceSize
        self.minConfidence = minConfidence
        self.includeLandmarks = includeLandmarks
    }
}

/// Caption module settings
public struct CaptionModuleSettings: Codable, Equatable {
    public var enabled: Bool
    public var method: String
    public var timeoutMs: Int
    public var model: String?
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case method
        case timeoutMs = "timeout_ms"
        case model
    }
    
    public init(
        enabled: Bool = true,
        method: String = "ollama",
        timeoutMs: Int = 60000,
        model: String? = "llava:7b"
    ) {
        self.enabled = enabled
        self.method = method
        self.timeoutMs = timeoutMs
        self.model = model
    }
}

/// FSWatch module settings
public struct FSWatchModuleSettings: Codable, Equatable {
    public var eventQueueSize: Int
    public var debounceMs: Int
    
    enum CodingKeys: String, CodingKey {
        case eventQueueSize = "event_queue_size"
        case debounceMs = "debounce_ms"
    }
    
    public init(
        eventQueueSize: Int = 1024,
        debounceMs: Int = 500
    ) {
        self.eventQueueSize = eventQueueSize
        self.debounceMs = debounceMs
    }
}

/// LocalFS module settings
public struct LocalFSModuleSettings: Codable, Equatable {
    public var maxFileBytes: Int
    
    enum CodingKeys: String, CodingKey {
        case maxFileBytes = "max_file_bytes"
    }
    
    public init(maxFileBytes: Int = 104857600) {
        self.maxFileBytes = maxFileBytes
    }
}

/// Debug settings
public struct DebugSettings: Codable, Equatable {
    public var enabled: Bool
    public var outputPath: String
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case outputPath = "output_path"
    }
    
    public init(enabled: Bool = false, outputPath: String = "") {
        self.enabled = enabled
        // Default to HavenFilePaths debug directory if empty
        self.outputPath = outputPath.isEmpty ? HavenFilePaths.debugFile("debug_documents.jsonl").path : outputPath
    }
}

