//
//  ConfigManager.swift
//  Haven
//
//  Main configuration manager for loading/saving plist files
//  Handles atomic writes and validation
//

import Foundation
import HavenCore

/// Main configuration manager actor
/// Handles loading and saving all configuration files atomically
public actor ConfigManager {
    private let configDirectory: URL
    private let logger = HavenLogger(category: "config-manager")
    
    // Cached configurations
    private var systemConfig: SystemConfig?
    private var emailConfig: EmailInstancesConfig?
    private var filesConfig: FilesInstancesConfig?
    private var icloudDriveConfig: ICloudDriveInstancesConfig?
    private var contactsConfig: ContactsInstancesConfig?
    private var imessageConfig: IMessageInstanceConfig?
    private var remindersConfig: RemindersInstanceConfig?
    private var schedulesConfig: CollectorSchedulesConfig?
    
    public init(configDirectory: URL? = nil) {
        // Use HavenFilePaths for macOS-standard directory
        if let directory = configDirectory {
            self.configDirectory = directory
        } else {
            self.configDirectory = HavenFilePaths.configDirectory
        }
        
        // Ensure directories exist
        try? HavenFilePaths.initializeDirectories()
    }
    
    // MARK: - System Configuration
    
    /// Load system configuration from system.plist
    public func loadSystemConfig() throws -> SystemConfig {
        if let cached = systemConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("system.plist")
        let config = try loadConfig(from: url, type: SystemConfig.self, default: SystemConfig())
        systemConfig = config
        return config
    }
    
    /// Save system configuration to system.plist
    public func saveSystemConfig(_ config: SystemConfig) throws {
        let url = configDirectory.appendingPathComponent("system.plist")
        try saveConfig(config, to: url)
        systemConfig = config
        logger.info("System configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - Email Configuration
    
    /// Load email instances configuration from email.plist
    public func loadEmailConfig() throws -> EmailInstancesConfig {
        if let cached = emailConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("email.plist")
        let config = try loadConfig(from: url, type: EmailInstancesConfig.self, default: EmailInstancesConfig())
        emailConfig = config
        return config
    }
    
    /// Save email instances configuration to email.plist
    public func saveEmailConfig(_ config: EmailInstancesConfig) throws {
        let url = configDirectory.appendingPathComponent("email.plist")
        try saveConfig(config, to: url)
        emailConfig = config
        logger.info("Email configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - Files Configuration
    
    /// Load files instances configuration from files.plist
    public func loadFilesConfig() throws -> FilesInstancesConfig {
        if let cached = filesConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("files.plist")
        let config = try loadConfig(from: url, type: FilesInstancesConfig.self, default: FilesInstancesConfig())
        filesConfig = config
        return config
    }
    
    /// Save files instances configuration to files.plist
    public func saveFilesConfig(_ config: FilesInstancesConfig) throws {
        let url = configDirectory.appendingPathComponent("files.plist")
        try saveConfig(config, to: url)
        filesConfig = config
        logger.info("Files configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - iCloud Drive Configuration
    
    /// Load iCloud Drive instances configuration from icloud_drive.plist
    public func loadICloudDriveConfig() throws -> ICloudDriveInstancesConfig {
        if let cached = icloudDriveConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("icloud_drive.plist")
        let config = try loadConfig(from: url, type: ICloudDriveInstancesConfig.self, default: ICloudDriveInstancesConfig())
        icloudDriveConfig = config
        return config
    }
    
    /// Save iCloud Drive instances configuration to icloud_drive.plist
    public func saveICloudDriveConfig(_ config: ICloudDriveInstancesConfig) throws {
        let url = configDirectory.appendingPathComponent("icloud_drive.plist")
        try saveConfig(config, to: url)
        icloudDriveConfig = config
        logger.info("iCloud Drive configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - Contacts Configuration
    
    /// Load contacts instances configuration from contacts.plist
    public func loadContactsConfig() throws -> ContactsInstancesConfig {
        if let cached = contactsConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("contacts.plist")
        let config = try loadConfig(from: url, type: ContactsInstancesConfig.self, default: ContactsInstancesConfig())
        contactsConfig = config
        return config
    }
    
    /// Save contacts instances configuration to contacts.plist
    public func saveContactsConfig(_ config: ContactsInstancesConfig) throws {
        let url = configDirectory.appendingPathComponent("contacts.plist")
        try saveConfig(config, to: url)
        contactsConfig = config
        logger.info("Contacts configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - iMessage Configuration
    
    /// Load iMessage configuration from imessage.plist
    public func loadIMessageConfig() throws -> IMessageInstanceConfig {
        if let cached = imessageConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("imessage.plist")
        let config = try loadConfig(from: url, type: IMessageInstanceConfig.self, default: IMessageInstanceConfig())
        imessageConfig = config
        return config
    }
    
    /// Save iMessage configuration to imessage.plist
    public func saveIMessageConfig(_ config: IMessageInstanceConfig) throws {
        let url = configDirectory.appendingPathComponent("imessage.plist")
        try saveConfig(config, to: url)
        imessageConfig = config
        logger.info("iMessage configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - Reminders Configuration
    
    /// Load Reminders configuration from reminders.plist
    public func loadRemindersConfig() throws -> RemindersInstanceConfig {
        if let cached = remindersConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("reminders.plist")
        let config = try loadConfig(from: url, type: RemindersInstanceConfig.self, default: RemindersInstanceConfig())
        remindersConfig = config
        return config
    }
    
    /// Save Reminders configuration to reminders.plist
    public func saveRemindersConfig(_ config: RemindersInstanceConfig) throws {
        let url = configDirectory.appendingPathComponent("reminders.plist")
        try saveConfig(config, to: url)
        remindersConfig = config
        logger.info("Reminders configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - Schedules Configuration
    
    /// Load schedules configuration from schedules.plist
    public func loadSchedulesConfig() throws -> CollectorSchedulesConfig {
        if let cached = schedulesConfig {
            return cached
        }
        
        let url = configDirectory.appendingPathComponent("schedules.plist")
        let config = try loadConfig(from: url, type: CollectorSchedulesConfig.self, default: CollectorSchedulesConfig())
        schedulesConfig = config
        return config
    }
    
    /// Save schedules configuration to schedules.plist
    public func saveSchedulesConfig(_ config: CollectorSchedulesConfig) throws {
        let url = configDirectory.appendingPathComponent("schedules.plist")
        try saveConfig(config, to: url)
        schedulesConfig = config
        logger.info("Schedules configuration saved", metadata: ["path": url.path])
    }
    
    // MARK: - Cache Management
    
    /// Clear all cached configurations to force reload from disk
    /// Call this after saving configurations to ensure fresh loads
    public func clearCache() {
        systemConfig = nil
        emailConfig = nil
        filesConfig = nil
        icloudDriveConfig = nil
        contactsConfig = nil
        imessageConfig = nil
        remindersConfig = nil
        schedulesConfig = nil
        logger.info("Configuration cache cleared")
    }
    
    // MARK: - Load All
    
    /// Load all configuration files
    public func loadAll() throws {
        _ = try loadSystemConfig()
        _ = try loadEmailConfig()
        _ = try loadFilesConfig()
        _ = try loadICloudDriveConfig()
        _ = try loadContactsConfig()
        _ = try loadIMessageConfig()
        _ = try loadRemindersConfig()
        _ = try loadSchedulesConfig()
    }
    
    // MARK: - Initialize Defaults
    
    /// Initialize default configuration files if they don't exist
    /// This should be called on first run of Haven.App
    public func initializeDefaultsIfNeeded() throws {
        // Check if any config file exists - if so, assume already initialized
        let systemURL = configDirectory.appendingPathComponent("system.plist")
        if FileManager.default.fileExists(atPath: systemURL.path) {
            logger.info("Configuration files already exist, skipping initialization")
            return
        }
        
        logger.info("Initializing default configuration files on first run")
        
        // Create default SystemConfig matching default-config.yaml values
        let defaultSystemConfig = SystemConfig(
            service: SystemServiceConfig(
                port: 7090,
                auth: SystemAuthConfig(
                    header: "X-Haven-Key",
                    secret: "changeme"
                )
            ),
            api: SystemApiConfig(
                responseTimeoutMs: 2000,
                statusTtlMinutes: 1440
            ),
            gateway: SystemGatewayConfig(
                baseUrl: "http://localhost:8085",
                ingestPath: "/v1/ingest",
                ingestFilePath: "/v1/ingest/file",
                timeoutMs: 30000,
                batchSize: 200
            ),
            logging: SystemLoggingConfig(
                level: "info",
                format: "json",
                paths: SystemLoggingPathsConfig(
                    app: HavenFilePaths.logFile("hostagent.log").path,
                    error: nil,
                    access: HavenFilePaths.logFile("hostagent_access.log").path
                )
            ),
            modules: ModulesEnablementConfig(
                imessage: true,
                ocr: true,
                entity: true,
                face: true,
                fswatch: true,
                localfs: true,
                contacts: true,
                mail: true,
                reminders: true
            ),
            advanced: AdvancedModuleSettings(
                enrichmentConcurrency: 4,
                ocr: OCRModuleSettings(
                    languages: ["en"],
                    timeoutMs: 15000,
                    recognitionLevel: "accurate",
                    includeLayout: false
                ),
                entity: EntityModuleSettings(
                    types: ["person", "organization", "place"],
                    minConfidence: 0.6
                ),
                face: FaceModuleSettings(
                    minFaceSize: 0.01,
                    minConfidence: 0.7,
                    includeLandmarks: false
                ),
                caption: CaptionModuleSettings(
                    enabled: true,
                    method: "ollama",
                    timeoutMs: 60000,
                    model: "llava:7b"
                ),
                fswatch: FSWatchModuleSettings(
                    eventQueueSize: 1024,
                    debounceMs: 500
                ),
                localfs: LocalFSModuleSettings(
                    maxFileBytes: 104857600  // 100MB
                ),
                debug: DebugSettings(
                    enabled: false,
                    outputPath: HavenFilePaths.debugFile("debug_documents.jsonl").path
                )
            )
        )
        
        // Save all default configs
        try saveSystemConfig(defaultSystemConfig)
        try saveEmailConfig(EmailInstancesConfig())
        try saveFilesConfig(FilesInstancesConfig())
        try saveICloudDriveConfig(ICloudDriveInstancesConfig())
        try saveContactsConfig(ContactsInstancesConfig())
        try saveIMessageConfig(IMessageInstanceConfig())
        try saveSchedulesConfig(CollectorSchedulesConfig())
        
        logger.info("Default configuration files initialized successfully")
    }
    
    // MARK: - Validation
    
    /// Validate system configuration
    public func validateSystemConfig(_ config: SystemConfig) throws {
        // Validate port range
        if config.service.port < 1024 || config.service.port > 65535 {
            throw ConfigError.validationError("Port must be between 1024 and 65535")
        }
        
        // Validate gateway URL
        if config.gateway.baseUrl.isEmpty {
            throw ConfigError.validationError("Gateway base URL cannot be empty")
        }
        
        if config.maxConcurrentEnrichments < 1 || config.maxConcurrentEnrichments > 16 {
            throw ConfigError.validationError("Max concurrent enrichments must be between 1 and 16")
        }

        // Validate auth secret
        if config.service.auth.secret.isEmpty || config.service.auth.secret == "changeme" {
            logger.warning("Using default auth secret - this is insecure!")
        }
    }
    
    // MARK: - Private Helpers
    
    /// Load configuration from plist file
    private func loadConfig<T: Codable>(from url: URL, type: T.Type, default defaultValue: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("Configuration file not found, using defaults", metadata: ["path": url.path])
            return defaultValue
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            return try decoder.decode(type, from: data)
        } catch {
            logger.error("Failed to load configuration", metadata: [
                "path": url.path,
                "error": error.localizedDescription
            ])
            // Return defaults on error
            return defaultValue
        }
    }
    
    /// Save configuration to plist file atomically
    private func saveConfig<T: Codable>(_ config: T, to url: URL) throws {
        // Create temporary file
        let tempURL = url.appendingPathExtension("tmp")
        
        // Encode to plist
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml  // Use XML format for readability
        let data = try encoder.encode(config)
        
        // Write to temp file
        try data.write(to: tempURL)
        
        // Atomically replace original file
        try FileManager.default.replaceItem(at: url, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: nil)
        
        logger.info("Configuration saved atomically", metadata: ["path": url.path])
    }
}

// MARK: - Errors

public enum ConfigError: LocalizedError {
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
