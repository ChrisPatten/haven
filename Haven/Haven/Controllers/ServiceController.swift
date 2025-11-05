//
//  ServiceController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation

/// Manages shared services and configuration for all collectors
public actor ServiceController {
    private var config: HavenConfig?
    private var configManager: ConfigManager
    private var gatewayClient: GatewayClient?
    private var ocrService: OCRService?
    private var entityService: EntityService?
    private var fsWatchService: FSWatchService?
    private let logger = StubLogger(category: "service-controller")
    
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
        if let envLevel = ProcessInfo.processInfo.environment["HAVEN_LOG_LEVEL"] {
            StubLogger.setMinimumLevel(envLevel)
        }
        if let envFormat = ProcessInfo.processInfo.environment["HAVEN_LOG_FORMAT"] {
            StubLogger.setOutputFormat(envFormat)
        }
        StubLogger.setMinimumLevel(config.logging.level)
        StubLogger.setOutputFormat(config.logging.format)
        StubLogger.enableDirectFileLogging()
        
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
    
    // MARK: - Gateway Client
    
    /// Initialize gateway client
    public func initializeGatewayClient() throws {
        let config = try getConfig()
        gatewayClient = GatewayClient(config: config.gateway, authToken: config.service.auth.secret)
        logger.info("Gateway client initialized")
    }
    
    /// Get gateway client
    public func getGatewayClient() throws -> GatewayClient {
        guard let client = gatewayClient else {
            throw ServiceError.gatewayNotInitialized
        }
        return client
    }
    
    // MARK: - OCR Service
    
    /// Initialize OCR service if enabled
    public func initializeOCRService() throws {
        let config = try getConfig()
        guard config.modules.ocr.enabled else {
            logger.info("OCR service disabled in configuration")
            return
        }
        
        ocrService = OCRService(
            timeoutMs: config.modules.ocr.timeoutMs,
            languages: config.modules.ocr.languages,
            recognitionLevel: config.modules.ocr.recognitionLevel,
            includeLayout: config.modules.ocr.includeLayout,
            maxImageDimension: config.modules.ocr.maxImageDimension
        )
        logger.info("OCR service initialized")
    }
    
    /// Get OCR service if available
    public func getOCRService() -> OCRService? {
        return ocrService
    }
    
    // MARK: - Entity Service
    
    /// Initialize entity service if enabled
    public func initializeEntityService() throws {
        let config = try getConfig()
        guard config.modules.entity.enabled else {
            logger.info("Entity service disabled in configuration")
            return
        }
        
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
    
    /// Initialize FSWatch service if enabled
    public func initializeFSWatchService() throws {
        let config = try getConfig()
        guard config.modules.fswatch.enabled else {
            logger.info("FSWatch service disabled in configuration")
            return
        }
        
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

