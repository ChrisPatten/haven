//
//  HostAgentController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import SwiftUI
import Combine
import HavenCore
import CollectorHandlers
import HostAgentEmail
import OCR
import Entity
import Face
import Caption

/// Main orchestration controller for HostAgent
@MainActor
public class HostAgentController: ObservableObject {
    private let serviceController: ServiceController
    private var statusController: StatusController?
    private var collectors: [String: any CollectorController] = [:]
    private var config: HavenConfig?
    private var isRunning: Bool = false
    private let logger = HavenLogger(category: "hostagent-controller")
    private let jobManager: JobManager
    
    @Published public var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
        self.serviceController = ServiceController()
        self.jobManager = JobManager(appState: appState)
        // StatusController will be initialized after config is loaded
    }
    
    // MARK: - Lifecycle
    
    /// Start HostAgent - initialize services and collectors
    public func start() async throws {
        guard !isRunning else {
            logger.warning("HostAgent already running")
            return
        }
        
        logger.info("Starting HostAgent")
        appState.setStarting(true)
        defer { appState.setStarting(false) }
        
        do {
            // Load configuration
            let config = try await serviceController.loadConfig()
            self.config = config
            
            // Initialize services
            try await serviceController.initializeServices()
            
            // Initialize status controller with config
            let startTime = Date()
            let statusController = StatusController(config: config, startTime: startTime)
            self.statusController = statusController
            
            // Initialize collectors
            try await initializeCollectors(config: config)
            
            isRunning = true
            appState.updateProcessState(.running)
            appState.status = .green
            appState.clearError()
            
            logger.info("HostAgent started successfully")
        } catch {
            logger.error("Failed to start HostAgent", metadata: ["error": error.localizedDescription])
            appState.setError(error.localizedDescription)
            appState.updateProcessState(.stopped)
            appState.status = .red
            throw error
        }
    }
    
    /// Stop HostAgent - shutdown services
    public func stop() async throws {
        guard isRunning else {
            logger.warning("HostAgent not running")
            return
        }
        
        logger.info("Stopping HostAgent")
        appState.setStopping(true)
        defer { appState.setStopping(false) }
        
        // Shutdown services
        await serviceController.shutdownServices()
        
        // Clear collectors
        collectors.removeAll()
        
        isRunning = false
        appState.updateProcessState(.stopped)
        appState.status = .red
        appState.clearError()
        
        logger.info("HostAgent stopped successfully")
    }
    
    // MARK: - Collector Management
    
    /// Ensure a specific collector is initialized (lazy initialization)
    private func ensureCollectorInitialized(id: String) async throws {
        // Always reload config to pick up any changes from settings
            config = try await serviceController.loadConfig()
        
        guard let config = config else {
            throw HostAgentError.collectorErrors(["Failed to load configuration"])
        }
        
        logger.info("Loaded configuration for collector initialization", metadata: [
            "collector": id,
            "debug_enabled": String(config.debug.enabled),
            "debug_output_path": config.debug.outputPath
        ])
        
        // Load enrichment configuration and create shared submitter
        let enrichmentConfigManager = EnrichmentConfigManager()
        let enrichmentConfig = enrichmentConfigManager.loadEnrichmentConfig()
        let sharedSubmitter = try await createDocumentSubmitter(config: config)
        
        // Initialize the specific collector (all modules are enabled, check instances instead)
        // Always re-initialize to pick up config changes (especially debug mode)
        switch id {
        case "imessage":
            // iMessage doesn't require instances, always initialize if requested
                let skipEnrichment = enrichmentConfig.getSkipEnrichment(for: "imessage")
                let orchestrator = skipEnrichment ? nil : createEnrichmentOrchestrator(config: config)
                let controller = try await IMessageController(
                    config: config,
                    serviceController: serviceController,
                    enrichmentOrchestrator: orchestrator,
                    submitter: sharedSubmitter,
                    skipEnrichment: skipEnrichment
                )
                collectors[id] = controller
                logger.info("Initialized collector", metadata: ["collector": id])
        case "contacts":
            // Contacts requires instances - check if any are configured
            // Contacts always skip enrichment (hardcoded)
            let hasContactsInstances = await hasContactsInstancesConfigured()
            if hasContactsInstances && collectors[id] == nil {
                let controller = try await ContactsController(
                    config: config,
                    serviceController: serviceController,
                    enrichmentOrchestrator: nil,
                    submitter: sharedSubmitter,
                    skipEnrichment: true // Contacts always skip enrichment
                )
                collectors[id] = controller
                logger.info("Initialized collector", metadata: ["collector": id])
            }
        case "localfs":
            // Files requires instances - check if any are configured
            let hasFilesInstances = await hasFilesInstancesConfigured()
            if hasFilesInstances && collectors[id] == nil {
                let skipEnrichment = enrichmentConfig.getSkipEnrichment(for: "localfs")
                let orchestrator = skipEnrichment ? nil : createEnrichmentOrchestrator(config: config)
                let controller = try await LocalFSController(
                    config: config,
                    serviceController: serviceController,
                    enrichmentOrchestrator: orchestrator,
                    submitter: sharedSubmitter,
                    skipEnrichment: skipEnrichment
                )
                collectors[id] = controller
                logger.info("Initialized collector", metadata: ["collector": id])
            }
        case "email_imap":
            // IMAP requires instances - check if any are configured
            let hasImapSources = await hasImapSourcesConfigured()
            if hasImapSources && collectors[id] == nil {
                let skipEnrichment = enrichmentConfig.getSkipEnrichment(for: "email_imap")
                let orchestrator = skipEnrichment ? nil : createEnrichmentOrchestrator(config: config)
                let controller = try await EmailController(
                    config: config,
                    serviceController: serviceController,
                    enrichmentOrchestrator: orchestrator,
                    submitter: sharedSubmitter,
                    skipEnrichment: skipEnrichment
                )
                collectors[id] = controller
                logger.info("Initialized collector", metadata: ["collector": id])
            }
        default:
            throw HostAgentError.collectorNotFound(id)
        }
    }
    
    /// Ensure all collectors are initialized (lazy initialization)
    private func ensureAllCollectorsInitialized() async throws {
        // Load config if not already loaded
        if config == nil {
            config = try await serviceController.loadConfig()
        }
        
        guard let config = config else {
            throw HostAgentError.collectorErrors(["Failed to load configuration"])
        }
        
        // Load enrichment configuration and create shared submitter
        let enrichmentConfigManager = EnrichmentConfigManager()
        let enrichmentConfig = enrichmentConfigManager.loadEnrichmentConfig()
        let sharedSubmitter = try await createDocumentSubmitter(config: config)
        
        // Initialize all collectors that have instances configured (all modules are enabled)
        if collectors["imessage"] == nil {
            let skipEnrichment = enrichmentConfig.getSkipEnrichment(for: "imessage")
            let orchestrator = skipEnrichment ? nil : createEnrichmentOrchestrator(config: config)
            let controller = try await IMessageController(
                config: config,
                serviceController: serviceController,
                enrichmentOrchestrator: orchestrator,
                submitter: sharedSubmitter,
                skipEnrichment: skipEnrichment
            )
            collectors["imessage"] = controller
        }
        
        let hasContactsInstances = await hasContactsInstancesConfigured()
        if hasContactsInstances && collectors["contacts"] == nil {
            let controller = try await ContactsController(
                config: config,
                serviceController: serviceController,
                enrichmentOrchestrator: nil,
                submitter: sharedSubmitter,
                skipEnrichment: true // Contacts always skip enrichment
            )
            collectors["contacts"] = controller
        }
        
        let hasFilesInstances = await hasFilesInstancesConfigured()
        if hasFilesInstances && collectors["localfs"] == nil {
            let skipEnrichment = enrichmentConfig.getSkipEnrichment(for: "localfs")
            let orchestrator = skipEnrichment ? nil : createEnrichmentOrchestrator(config: config)
            let controller = try await LocalFSController(
                config: config,
                serviceController: serviceController,
                enrichmentOrchestrator: orchestrator,
                submitter: sharedSubmitter,
                skipEnrichment: skipEnrichment
            )
            collectors["localfs"] = controller
        }
        
        let hasImapSources = await hasImapSourcesConfigured()
        if hasImapSources && collectors["email_imap"] == nil {
            let skipEnrichment = enrichmentConfig.getSkipEnrichment(for: "email_imap")
            let orchestrator = skipEnrichment ? nil : createEnrichmentOrchestrator(config: config)
            let controller = try await EmailController(
                config: config,
                serviceController: serviceController,
                enrichmentOrchestrator: orchestrator,
                submitter: sharedSubmitter,
                skipEnrichment: skipEnrichment
            )
            collectors["email_imap"] = controller
        }
        
        logger.info("Ensured all collectors initialized", metadata: ["count": String(collectors.count)])
    }
    
    /// Initialize collectors (used by start() method for backward compatibility)
    private func initializeCollectors(config: HavenConfig) async throws {
        // Load enrichment configuration
        let enrichmentConfigManager = EnrichmentConfigManager()
        let enrichmentConfig = enrichmentConfigManager.loadEnrichmentConfig()
        
        // Create shared document submitter (can be shared across all collectors)
        let sharedSubmitter = try await createDocumentSubmitter(config: config)
        
        // Initialize iMessage collector (always available, no instances needed)
        let skipIMessageEnrichment = enrichmentConfig.getSkipEnrichment(for: "imessage")
        let imessageOrchestrator = skipIMessageEnrichment ? nil : createEnrichmentOrchestrator(config: config)
        let controller = try await IMessageController(
            config: config,
            serviceController: serviceController,
            enrichmentOrchestrator: imessageOrchestrator,
            submitter: sharedSubmitter,
            skipEnrichment: skipIMessageEnrichment
        )
        collectors["imessage"] = controller
        
        // Initialize Contacts collector if instances are configured
        // Contacts always skip enrichment (hardcoded)
        let hasContactsInstances = await hasContactsInstancesConfigured()
        if hasContactsInstances {
            let contactsController = try await ContactsController(
                config: config,
                serviceController: serviceController,
                enrichmentOrchestrator: nil,
                submitter: sharedSubmitter,
                skipEnrichment: true // Contacts always skip enrichment
            )
            collectors["contacts"] = contactsController
        }
        
        // Initialize LocalFS collector if instances are configured
        let hasFilesInstances = await hasFilesInstancesConfigured()
        if hasFilesInstances {
            let skipLocalFSEnrichment = enrichmentConfig.getSkipEnrichment(for: "localfs")
            let localfsOrchestrator = skipLocalFSEnrichment ? nil : createEnrichmentOrchestrator(config: config)
            let localfsController = try await LocalFSController(
                config: config,
                serviceController: serviceController,
                enrichmentOrchestrator: localfsOrchestrator,
                submitter: sharedSubmitter,
                skipEnrichment: skipLocalFSEnrichment
            )
            collectors["localfs"] = localfsController
        }
        
        // Initialize Email collector if instances are configured
        let hasImapSources = await hasImapSourcesConfigured()
        if hasImapSources {
            let skipEmailEnrichment = enrichmentConfig.getSkipEnrichment(for: "email_imap")
            let emailOrchestrator = skipEmailEnrichment ? nil : createEnrichmentOrchestrator(config: config)
            let emailController = try await EmailController(
                config: config,
                serviceController: serviceController,
                enrichmentOrchestrator: emailOrchestrator,
                submitter: sharedSubmitter,
                skipEnrichment: skipEmailEnrichment
            )
            collectors["email_imap"] = emailController
        }
        
        logger.info("Initialized collectors", metadata: ["count": String(collectors.count)])
    }
    
    /// Create document submitter based on debug mode configuration
    private func createDocumentSubmitter(config: HavenConfig) async throws -> any DocumentSubmitter {
        // Check if debug mode is enabled
        if config.debug.enabled {
            logger.info("Debug mode enabled - using DebugDocumentSubmitter", metadata: [
                "output_path": config.debug.outputPath
            ])
            return DebugDocumentSubmitter(outputPath: config.debug.outputPath)
        } else {
            // Normal mode - use BatchDocumentSubmitter with gateway client
            let gatewaySubmissionClient = GatewaySubmissionClient(
                config: config.gateway,
                authToken: config.service.auth.secret
            )
            return BatchDocumentSubmitter(gatewayClient: gatewaySubmissionClient)
        }
    }
    
    /// Create enrichment orchestrator from config
    private func createEnrichmentOrchestrator(config: HavenConfig) -> DocumentEnrichmentOrchestrator {
        let ocrService = config.modules.ocr.enabled ? OCRService(
            timeoutMs: config.modules.ocr.timeoutMs,
            languages: config.modules.ocr.languages,
            recognitionLevel: config.modules.ocr.recognitionLevel,
            includeLayout: config.modules.ocr.includeLayout
        ) : nil
        
        let faceService = config.modules.face.enabled ? FaceService(
            minFaceSize: config.modules.face.minFaceSize,
            minConfidence: config.modules.face.minConfidence,
            includeLandmarks: config.modules.face.includeLandmarks
        ) : nil
        
        let entityService = config.modules.entity.enabled ? EntityService(
            enabledTypes: config.modules.entity.types.compactMap { EntityType(rawValue: $0) },
            minConfidence: config.modules.entity.minConfidence
        ) : nil
        
        // Log caption configuration for debugging
        logger.info("Caption configuration", metadata: [
            "enabled": String(config.modules.caption.enabled),
            "method": config.modules.caption.method,
            "timeout_ms": String(config.modules.caption.timeoutMs),
            "model": config.modules.caption.model ?? "nil"
        ])
        
        let captionService = config.modules.caption.enabled ? CaptionService(
            method: config.modules.caption.method,
            timeoutMs: config.modules.caption.timeoutMs,
            model: config.modules.caption.model
        ) : nil
        
        if captionService == nil {
            logger.warning("CaptionService not created - caption module is disabled in config")
        } else {
            logger.info("CaptionService created successfully")
        }
        
        return DocumentEnrichmentOrchestrator(
            ocrService: ocrService,
            faceService: faceService,
            entityService: entityService,
            captionService: captionService,
            ocrConfig: config.modules.ocr,
            faceConfig: config.modules.face,
            entityConfig: config.modules.entity,
            captionConfig: config.modules.caption
        )
    }
    
    /// Extract base collector ID and instance ID from instance-specific collector ID
    /// Format: "collector_type:instance_id" (e.g., "email_imap:FE9CF2BB-B07D-49B0-B11A-084C2ED68468")
    /// Returns: (baseCollectorId, instanceId) where instanceId is nil if not instance-specific
    private func extractCollectorIdAndInstance(_ collectorId: String) -> (String, String?) {
        if let colonIndex = collectorId.firstIndex(of: ":") {
            let baseId = String(collectorId[..<colonIndex])
            let instanceId = String(collectorId[collectorId.index(after: colonIndex)...])
            return (baseId, instanceId)
        } else {
            return (collectorId, nil)
        }
    }
    
    /// Run a specific collector
    /// Collectors run independently - no need for HostAgent to be "started"
    public func runCollector(id: String, request: HostAgentEmail.CollectorRunRequest?) async throws -> HostAgentEmail.RunResponse {
        // Extract base collector ID and instance ID for instance-specific collectors
        // Format: "collector_type:instance_id" (e.g., "email_imap:FE9CF2BB-B07D-49B0-B11A-084C2ED68468")
        let (baseCollectorId, instanceId) = extractCollectorIdAndInstance(id)
        
        // Ensure collector is initialized (lazy initialization) - use base collector ID
        if collectors[baseCollectorId] == nil {
            try await ensureCollectorInitialized(id: baseCollectorId)
        }
        
        guard let collector = collectors[baseCollectorId] else {
            throw HostAgentError.collectorNotFound(baseCollectorId)
        }
        
        // If this is an instance-specific collector, add instance ID to scope
        var finalRequest = request
        if let instanceId = instanceId {
            // Extract existing scope dictionary if present, or start with empty dict
            var scopeDict: [String: HostAgentEmail.AnyCodable] = [:]
            
            // Try to extract dictionary from existing scope if it exists
            if let existingScope = request?.scope {
                // AnyCodable wraps the value - try to extract dictionary
                // We'll decode it by encoding and decoding, or check if it's a dictionary
                // For now, we'll start fresh and add our instance ID
                // TODO: Merge with existing scope if needed
            }
            
            // For IMAP collectors, use "account_id" in scope
            if baseCollectorId == "email_imap" {
                scopeDict["account_id"] = HostAgentEmail.AnyCodable(instanceId)
            } else {
                // For other collectors, use "instance_id"
                scopeDict["instance_id"] = HostAgentEmail.AnyCodable(instanceId)
            }
            
            // Wrap dictionary in AnyCodable
            let scopeValue = HostAgentEmail.AnyCodable(scopeDict)
            
            // Create new request with updated scope
            finalRequest = HostAgentEmail.CollectorRunRequest(
                mode: request?.mode,
                limit: request?.limit,
                order: request?.order,
                concurrency: request?.concurrency,
                dateRange: request?.dateRange,
                timeWindow: request?.timeWindow,
                batch: request?.batch,
                batchSize: request?.batchSize,
                redactionOverride: request?.redactionOverride,
                filters: request?.filters,
                scope: scopeValue
            )
        }
        
        // Dispatch job via JobManager - use original ID for tracking, but base ID for collector lookup
        let job = try await jobManager.dispatchJob(
            collectorId: id,  // Keep original ID for tracking/display
            request: finalRequest,
            collector: collector
        ) { [weak self] progress in
            // Update app state with progress
            // Capture jobId as a local variable to avoid potential issues with captured job reference
            let capturedJobId = job.id
            Task { @MainActor [weak self] in
                guard let appState = self?.appState else { return }
                appState.updateJobProgress(jobId: capturedJobId, progress: progress)
            }
        }
        
        // Wait for job to complete and get response
        // Poll job status until it's no longer running
        var currentJob = job
        while currentJob.status == .running || currentJob.status == .pending {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            if let updatedJob = jobManager.getJob(jobId: job.id) {
                currentJob = updatedJob
                if updatedJob.status == .completed, let response = updatedJob.response {
                    // Update app state with activity
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    let activity = CollectorActivity(
                        id: job.id,
                        collector: id,
                        timestamp: updatedJob.startedAt ?? Date(),
                        status: response.status.rawValue,
                        scanned: response.stats.scanned,
                        submitted: response.stats.submitted,
                        errors: response.errors
                    )
                    appState.addActivity(activity)
                    
                    // Update collector state
                    let state = await collector.getState()
                    appState.updateCollectorState(id, state: state)
                    
                    return response
                } else if updatedJob.status == .failed || updatedJob.status == .cancelled {
                    if let errorMsg = updatedJob.error {
                        appState.setError("Collector \(id) failed: \(errorMsg)")
                        throw HostAgentError.collectorErrors([errorMsg])
                    }
                }
            }
        }
        
        // If we get here, job completed - return the response
        if let response = currentJob.response {
            return response
        } else {
            throw HostAgentError.collectorErrors(["Job completed but no response available"])
        }
    }
    
    /// Run all collectors
    /// Collectors run independently - no need for HostAgent to be "started"
    public func runAllCollectors() async throws {
        // Ensure all collectors are initialized
        try await ensureAllCollectorsInitialized()
        
        appState.setRunningAllCollectors(true)
        defer { appState.setRunningAllCollectors(false) }
        
        logger.info("Running all collectors", metadata: ["count": String(collectors.count)])
        
        var errors: [String] = []
        
        for (id, collector) in collectors {
            do {
                // Dispatch via JobManager for each collector
                let job = try await jobManager.dispatchJob(
                    collectorId: id,
                    request: nil,
                    collector: collector
                ) { progress in
                    // Progress updates for run all collectors
                }
                // Wait for job to complete by polling
                var currentJob = job
                while currentJob.status == .running || currentJob.status == .pending {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    if let updatedJob = jobManager.getJob(jobId: job.id) {
                        currentJob = updatedJob
                        if updatedJob.status == .completed || updatedJob.status == .failed || updatedJob.status == .cancelled {
                            break
                        }
                    }
                }
            } catch {
                let errorMsg = "\(id): \(error.localizedDescription)"
                errors.append(errorMsg)
                logger.error("Collector failed", metadata: ["collector": id, "error": error.localizedDescription])
            }
        }
        
        if !errors.isEmpty {
            appState.setError("Some collectors failed: \(errors.joined(separator: "; "))")
            throw HostAgentError.collectorErrors(errors)
        }
        
        logger.info("All collectors completed")
    }
    
    /// Get collector state
    public func getCollectorState(id: String) async -> CollectorStateResponse? {
        // Extract base collector ID for instance-specific collectors
        let (baseCollectorId, _) = extractCollectorIdAndInstance(id)
        
        // Ensure collector is initialized (lazy initialization) - use base collector ID
        if collectors[baseCollectorId] == nil {
            do {
                try await ensureCollectorInitialized(id: baseCollectorId)
            } catch {
                logger.error("Failed to initialize collector for state", metadata: ["collector": baseCollectorId, "error": error.localizedDescription])
                return nil
            }
        }
        
        guard let collector = collectors[baseCollectorId] else {
            return nil
        }
        
        return await collector.getState()
    }
    
    /// Get status response
    public func getStatus() async -> StatusResponse? {
        guard isRunning else {
            return nil
        }
        
        guard let statusController = statusController else {
            return nil
        }
        return await statusController.getStatus()
    }
    
    /// Check if HostAgent is running
    public func isHostAgentRunning() -> Bool {
        return isRunning
    }
    
    /// Cancel a running collector job
    /// - Parameter collectorId: The collector identifier to cancel
    public func cancelCollector(id collectorId: String) async {
        // Find active jobs for this collector
        let activeJobs = jobManager.getActiveJobs(for: collectorId)
        
        // Cancel all active jobs for this collector
        for job in activeJobs {
            if job.status == .running || job.status == .pending {
                await jobManager.cancelJob(jobId: job.id)
                logger.info("Cancelled collector job", metadata: ["collector": collectorId, "job_id": job.id])
            }
        }
        
        // Update app state to reflect cancellation
        appState.setCollectorRunning(collectorId, running: false)
    }
    
    /// Reset a collector - removes state files and fences to return to fresh state
    /// - Parameter collectorId: The collector identifier to reset
    public func resetCollector(id collectorId: String) async throws {
        // Extract base collector ID for instance-specific collectors
        let (baseCollectorId, _) = extractCollectorIdAndInstance(collectorId)
        
        // Ensure collector is initialized - use base collector ID
        if collectors[baseCollectorId] == nil {
            try await ensureCollectorInitialized(id: baseCollectorId)
        }
        
        guard let collector = collectors[baseCollectorId] else {
            throw HostAgentError.collectorNotFound(baseCollectorId)
        }
        
        // Check if collector is running
        let currentlyRunning = await collector.isRunning()
        guard !currentlyRunning else {
            throw HostAgentError.collectorErrors(["Cannot reset collector while it is running"])
        }
        
        // Call reset on the collector
        try await collector.reset()
        
        // Clear persisted last run info from UserDefaults
        let key = "collector_last_run_\(collectorId)"
        UserDefaults.standard.removeObject(forKey: key)
        
        // Refresh collector state
        if let state = await collector.getState() {
            appState.updateCollectorState(collectorId, state: state)
        }
        
        logger.info("Reset collector", metadata: ["collector": collectorId])
    }
    
    /// Check if any IMAP collector instances are configured
    /// - Returns: true if at least one enabled IMAP source is configured, false otherwise
    public func hasImapSourcesConfigured() async -> Bool {
        // Load config if not already loaded
        if config == nil {
            do {
                config = try await serviceController.loadConfig()
            } catch {
                logger.error("Failed to load config for IMAP source check", metadata: ["error": error.localizedDescription])
                return false
            }
        }
        
        guard let config = config else {
            return false
        }
        
        // Check if mail module has IMAP sources (module is always enabled)
        guard let sources = config.modules.mail.sources else {
            return false
        }
        
        // Check if any IMAP source is enabled
        return sources.contains { source in
            source.type == "imap" && source.enabled
        }
    }
    
    /// Check if any contacts collector instances are configured
    /// - Returns: true if at least one enabled contacts instance is configured, false otherwise
    public func hasContactsInstancesConfigured() async -> Bool {
        do {
            let configManager = ConfigManager()
            let contactsConfig = try await configManager.loadContactsConfig()
            return contactsConfig.instances.contains { $0.enabled }
        } catch {
            logger.error("Failed to load contacts config for instance check", metadata: ["error": error.localizedDescription])
            return false
        }
    }
    
    /// Check if any files collector instances are configured
    /// - Returns: true if at least one enabled files instance is configured, false otherwise
    public func hasFilesInstancesConfigured() async -> Bool {
        do {
            let configManager = ConfigManager()
            let filesConfig = try await configManager.loadFilesConfig()
            return filesConfig.instances.contains { $0.enabled }
        } catch {
            logger.error("Failed to load files config for instance check", metadata: ["error": error.localizedDescription])
            return false
        }
    }
    
    /// Check if iMessage collector module is enabled
    /// - Returns: always true since all modules are enabled
    public func isIMessageModuleEnabled() async -> Bool {
        // All modules are always enabled - collectors are conditionally enabled based on instances
        return true
    }
    
    /// Get all enabled IMAP email instances
    /// - Returns: Array of enabled IMAP email instances
    public func getImapInstances() async -> [EmailInstance] {
        do {
            // Load email config directly from plist file (this is the source of truth for the app)
            // Create a new ConfigManager instance to ensure we get fresh data (not cached)
            let configManager = ConfigManager()
            
            // Force reload by reading directly from disk (bypass cache)
            // We do this by creating a new instance which has empty cache
            let emailConfig = try await configManager.loadEmailConfig()
            
            // Filter for enabled IMAP instances
            let imapInstances = emailConfig.instances.filter { instance in
                instance.type == "imap" && instance.enabled
            }
            
            return imapInstances
        } catch {
            logger.error("Failed to load IMAP instances", metadata: ["error": error.localizedDescription])
            return []
        }
    }
    
    /// Get all enabled contacts instances
    /// - Returns: Array of enabled contacts instances
    public func getContactsInstances() async -> [ContactsInstance] {
        do {
            let configManager = ConfigManager()
            let contactsConfig = try await configManager.loadContactsConfig()
            return contactsConfig.instances.filter { $0.enabled }
        } catch {
            logger.error("Failed to load contacts instances", metadata: ["error": error.localizedDescription])
            return []
        }
    }
    
    /// Get all enabled files instances
    /// - Returns: Array of enabled files instances
    public func getFilesInstances() async -> [FilesInstance] {
        do {
            let configManager = ConfigManager()
            let filesConfig = try await configManager.loadFilesConfig()
            return filesConfig.instances.filter { $0.enabled }
        } catch {
            logger.error("Failed to load files instances", metadata: ["error": error.localizedDescription])
            return []
        }
    }
}

// MARK: - Errors

public enum HostAgentError: LocalizedError {
    case notRunning
    case collectorNotFound(String)
    case collectorErrors([String])
    
    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "HostAgent is not running"
        case .collectorNotFound(let id):
            return "Collector not found: \(id)"
        case .collectorErrors(let errors):
            return "Collector errors: \(errors.joined(separator: "; "))"
        }
    }
}

