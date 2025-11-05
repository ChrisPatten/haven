//
//  ConfigManager.swift
//  Haven
//
//  Main configuration manager for loading/saving plist files
//  Handles atomic writes and validation
//

import Foundation

/// Main configuration manager actor
/// Handles loading and saving all configuration files atomically
public actor ConfigManager {
    private let configDirectory: URL
    private let logger = StubLogger(category: "config-manager")
    
    // Cached configurations
    private var systemConfig: SystemConfig?
    private var emailConfig: EmailInstancesConfig?
    private var filesConfig: FilesInstancesConfig?
    private var contactsConfig: ContactsInstancesConfig?
    private var imessageConfig: IMessageInstanceConfig?
    private var schedulesConfig: CollectorSchedulesConfig?
    
    public init(configDirectory: URL? = nil) {
        // Default to ~/.haven
        if let directory = configDirectory {
            self.configDirectory = directory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.configDirectory = home.appendingPathComponent(".haven", isDirectory: true)
        }
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: self.configDirectory, withIntermediateDirectories: true)
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
    
    // MARK: - Load All
    
    /// Load all configuration files
    public func loadAll() throws {
        _ = try loadSystemConfig()
        _ = try loadEmailConfig()
        _ = try loadFilesConfig()
        _ = try loadContactsConfig()
        _ = try loadIMessageConfig()
        _ = try loadSchedulesConfig()
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

