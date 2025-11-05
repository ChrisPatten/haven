//
//  HostAgentController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import SwiftUI
import Combine

/// Main orchestration controller for HostAgent
@MainActor
public class HostAgentController: ObservableObject {
    private let serviceController: ServiceController
    private var statusController: StatusController?
    private var collectors: [String: any CollectorController] = [:]
    private var config: HavenConfig?
    private var isRunning: Bool = false
    private let logger = StubLogger(category: "hostagent-controller")
    
    @Published public var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
        self.serviceController = ServiceController()
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
        
        do {
            // Shutdown services
            await serviceController.shutdownServices()
            
            // Clear collectors
            collectors.removeAll()
            
            isRunning = false
            appState.updateProcessState(.stopped)
            appState.status = .red
            appState.clearError()
            
            logger.info("HostAgent stopped successfully")
        } catch {
            logger.error("Failed to stop HostAgent", metadata: ["error": error.localizedDescription])
            appState.setError(error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Collector Management
    
    private func initializeCollectors(config: HavenConfig) async throws {
        // Initialize iMessage collector
        if config.modules.imessage.enabled {
            let controller = try await IMessageController(config: config, serviceController: serviceController)
            collectors["imessage"] = controller
        }
        
        // Initialize Contacts collector
        if config.modules.contacts.enabled {
            let controller = try await ContactsController(config: config, serviceController: serviceController)
            collectors["contacts"] = controller
        }
        
        // Initialize LocalFS collector
        if config.modules.localfs.enabled {
            let controller = try await LocalFSController(config: config, serviceController: serviceController)
            collectors["localfs"] = controller
        }
        
        // Initialize Email collector
        if config.modules.mail.enabled {
            let controller = try await EmailController(config: config, serviceController: serviceController)
            collectors["email_imap"] = controller
        }
        
        logger.info("Initialized collectors", metadata: ["count": String(collectors.count)])
    }
    
    /// Run a specific collector
    public func runCollector(id: String, request: CollectorRunRequest?) async throws -> RunResponse {
        guard isRunning else {
            throw HostAgentError.notRunning
        }
        
        guard let collector = collectors[id] else {
            throw HostAgentError.collectorNotFound(id)
        }
        
        // Mark collector as running in app state
        appState.setCollectorRunning(id, running: true)
        defer { appState.setCollectorRunning(id, running: false) }
        
        do {
            let response = try await collector.run(request: request)
            
            // Update app state with activity
            // Note: RunResponse uses snake_case properties (started_at, run_id, etc.)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let activity = CollectorActivity(
                id: UUID().uuidString,
                collector: id,
                timestamp: formatter.date(from: response.started_at) ?? Date(),
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
        } catch {
            appState.setError("Collector \(id) failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Run all collectors
    public func runAllCollectors() async throws {
        guard isRunning else {
            throw HostAgentError.notRunning
        }
        
        appState.setRunningAllCollectors(true)
        defer { appState.setRunningAllCollectors(false) }
        
        logger.info("Running all collectors", metadata: ["count": String(collectors.count)])
        
        var errors: [String] = []
        
        for (id, collector) in collectors {
            do {
                _ = try await collector.run(request: nil)
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
        guard let collector = collectors[id] else {
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

