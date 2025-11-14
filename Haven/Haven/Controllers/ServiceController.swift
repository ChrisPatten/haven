//
//  ServiceController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore
import HostAgentEmail
import OCR
import Entity
import FSWatch

/// Manages shared services and configuration for all collectors
public actor ServiceController {
    private var config: HavenConfig?
    private var configManager: ConfigManager
    private var gatewayClient: GatewayClient?
    private var ocrService: OCRService?
    private var entityService: EntityService?
    private var fsWatchService: FSWatchService?
    private let logger = HavenLogger(category: "service-controller")
    
    public init(configManager: ConfigManager? = nil) {
        self.configManager = configManager ?? ConfigManager()
    }
    
    // MARK: - Configuration
    
    /// Load configuration from plist files via ConfigManager
    public func loadConfig() async throws -> HavenConfig {
        // Load all plist configs
        let systemConfig = try await configManager.loadSystemConfig()
        let emailConfig = try await configManager.loadEmailConfig()
        let filesConfig = try await configManager.loadFilesConfig()
        let contactsConfig = try await configManager.loadContactsConfig()
        let imessageConfig = try await configManager.loadIMessageConfig()
        
        // Convert to HavenConfig for compatibility with existing code
        let config = ConfigConverter.toHavenConfig(
            systemConfig: systemConfig,
            emailConfig: emailConfig,
            filesConfig: filesConfig,
            contactsConfig: contactsConfig,
            imessageConfig: imessageConfig
        )
        
        self.config = config
        
        // Apply logging configuration
        // Environment variables take precedence over config file
        let configLevel = config.logging.level
        let envLevel = ProcessInfo.processInfo.environment["HAVEN_LOG_LEVEL"]
        let finalLevel = envLevel ?? configLevel
        
        // Diagnostic: Log what we're setting (before setting it, so we can see it)
        // Use print to bypass HavenLogger level check
        print("DIAGNOSTIC: Setting log level - env: \(envLevel ?? "nil"), config: \(configLevel), final: \(finalLevel)")
        
        HavenLogger.setMinimumLevel(finalLevel)
        
        if let envFormat = ProcessInfo.processInfo.environment["HAVEN_LOG_FORMAT"] {
            HavenLogger.setOutputFormat(envFormat)
        } else {
            HavenLogger.setOutputFormat(config.logging.format)
        }
        // Enable file logging - HavenLogger uses hardcoded paths, but we can extend it if needed
        HavenLogger.enableDirectFileLogging()
        
        logger.info("Configuration loaded from plist files", metadata: [
            "gateway_url": config.gateway.baseUrl
        ])
        
        return config
    }
    
    /// Get current configuration
    public func getConfig() throws -> HavenConfig {
        guard let config = config else {
            throw ServiceError.configurationNotLoaded
        }
        return config
    }
    
    /// Clear cached configuration and clear ConfigManager cache
    /// Call this when settings are saved to force fresh reload on next load
    public func clearConfigCache() async {
        config = nil
        await configManager.clearCache()
        logger.info("Configuration cache cleared in ServiceController")
    }
    
    // MARK: - Gateway Client
    
    /// Initialize gateway client
    public func initializeGatewayClient() throws {
        let config = try getConfig()
        gatewayClient = GatewayClient(config: config.gateway, authToken: config.service.auth.secret)
        logger.info("Gateway client initialized")
    }
    
    /// Get gateway client (auto-initializes if not already initialized)
    public func getGatewayClient() throws -> GatewayClient {
        // Auto-initialize if not already initialized
        if gatewayClient == nil {
            try initializeGatewayClient()
        }
        
        guard let client = gatewayClient else {
            throw ServiceError.gatewayNotInitialized
        }
        return client
    }
    
    // MARK: - OCR Service
    
    /// Initialize OCR service (always enabled)
    public func initializeOCRService() throws {
        let config = try getConfig()
        // All modules are always enabled
        ocrService = OCRService(
            timeoutMs: config.modules.ocr.timeoutMs,
            languages: config.modules.ocr.languages,
            recognitionLevel: config.modules.ocr.recognitionLevel,
            includeLayout: config.modules.ocr.includeLayout
        )
        logger.info("OCR service initialized")
    }
    
    /// Get OCR service if available
    public func getOCRService() -> OCRService? {
        return ocrService
    }
    
    // MARK: - Entity Service
    
    /// Initialize entity service (always enabled)
    public func initializeEntityService() throws {
        let config = try getConfig()
        // All modules are always enabled
        // Convert types array to EntityType array
        let enabledTypes = config.modules.entity.types.compactMap { typeString -> EntityType? in
            EntityType(rawValue: typeString)
        }
        entityService = EntityService(
            enabledTypes: enabledTypes.isEmpty ? EntityType.allCases : enabledTypes,
            minConfidence: config.modules.entity.minConfidence
        )
        logger.info("Entity service initialized")
    }
    
    /// Get entity service if available
    public func getEntityService() -> EntityService? {
        return entityService
    }
    
    // MARK: - FSWatch Service
    
    /// Initialize FSWatch service (always enabled)
    public func initializeFSWatchService() throws {
        let config = try getConfig()
        // All modules are always enabled
        fsWatchService = FSWatchService(
            config: config.modules.fswatch,
            maxQueueSize: config.modules.fswatch.eventQueueSize
        )
        logger.info("FSWatch service initialized")
    }
    
    /// Get FSWatch service if available
    public func getFSWatchService() -> FSWatchService? {
        return fsWatchService
    }
    
    /// Start FSWatch service if initialized
    public func startFSWatchService() async throws {
        guard let service = fsWatchService else {
            logger.info("FSWatch service not initialized")
            return
        }
        
        try await service.start()
        logger.info("FSWatch service started")
    }
    
    /// Stop FSWatch service if initialized
    public func stopFSWatchService() async {
        guard let service = fsWatchService else {
            return
        }
        
        await service.stop()
        logger.info("FSWatch service stopped")
    }
    
    // MARK: - Initialization
    
    /// Initialize all services
    public func initializeServices() async throws {
        try initializeGatewayClient()
        try initializeOCRService()
        try initializeEntityService()
        try initializeFSWatchService()
        
        // Start FSWatch if enabled
        try await startFSWatchService()
    }
    
    /// Shutdown all services
    public func shutdownServices() async {
        await stopFSWatchService()
    }
}

public enum ServiceError: LocalizedError {
    case configurationNotLoaded
    case gatewayNotInitialized
    
    public var errorDescription: String? {
        switch self {
        case .configurationNotLoaded:
            return "Configuration not loaded"
        case .gatewayNotInitialized:
            return "Gateway client not initialized"
        }
    }
}

