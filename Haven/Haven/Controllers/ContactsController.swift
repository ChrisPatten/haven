//
//  ContactsController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore
import HostHTTP
import HostAgentEmail

/// Controller for Contacts collector
public actor ContactsController: CollectorController {
    public let collectorId = "contacts"
    
    private let handler: ContactsHandler
    private let baseState: BaseCollectorController
    private let logger = HavenLogger(category: "contacts-controller")
    
    public init(config: HavenConfig, serviceController: ServiceController) async throws {
        self.baseState = BaseCollectorController()
        
        let gatewayClient = try await serviceController.getGatewayClient()
        self.handler = ContactsHandler(config: config, gatewayClient: gatewayClient)
    }
    
    public func run(request: HostAgentEmail.CollectorRunRequest?, onProgress: ((JobProgress) -> Void)?) async throws -> HostAgentEmail.RunResponse {
        let currentlyRunning = await isRunning()
        guard !currentlyRunning else {
            throw CollectorError.alreadyRunning
        }
        
        // Mark as running
        baseState.isRunning = true
        
        do {
            // Bridge handler's progress callback to JobProgress
            let handlerProgress: ((Int, Int, Int, Int) -> Void)? = onProgress != nil ? { scanned, matched, submitted, skipped in
                Task { @MainActor in
                    let progress = JobProgress(
                        scanned: scanned,
                        matched: matched,
                        submitted: submitted,
                        skipped: skipped,
                        currentPhase: "Processing contacts",
                        phaseProgress: nil
                    )
                    onProgress?(progress)
                }
            } : nil
            
            // Call handler's direct Swift API with progress callback
            let runResponse = try await handler.runCollector(request: request, onProgress: handlerProgress)
            
            // Update state
            baseState.updateState(from: runResponse)
            baseState.isRunning = false
            
            return runResponse
        } catch {
            baseState.isRunning = false
            baseState.lastRunError = error.localizedDescription
            throw error
        }
    }
    
    public func getState() async -> CollectorStateResponse? {
        // Call handler's direct Swift API
        let stateInfo = await handler.getCollectorState()
        
        // Convert to Haven.app CollectorStateResponse
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        // Convert HavenCore.AnyCodable to Haven.AnyCodable
        // Access lastRunStats in a nonisolated context
        let stats = stateInfo.lastRunStats
        var lastRunStats: [String: AnyCodable]? = nil
        if let stats = stats {
            var dict: [String: AnyCodable] = [:]
            for (key, havenCoreValue) in stats {
                // Convert HavenCore.AnyCodable to Haven.AnyCodable
                // Access value in a nonisolated context
                let value = havenCoreValue.value
                switch value {
                case let str as String:
                    dict[key] = .string(str)
                case let int as Int:
                    dict[key] = .int(int)
                case let double as Double:
                    dict[key] = .double(double)
                case let bool as Bool:
                    dict[key] = .bool(bool)
                default:
                    dict[key] = .null
                }
            }
            lastRunStats = dict
        }
        
        return CollectorStateResponse(
            isRunning: stateInfo.isRunning,
            lastRunStatus: stateInfo.lastRunStatus,
            lastRunTime: stateInfo.lastRunTime.map { formatter.string(from: $0) },
            lastRunStats: lastRunStats,
            lastRunError: stateInfo.lastRunError
        )
    }
    
    public func isRunning() async -> Bool {
        return baseState.isRunning
    }
    
    public func reset() async throws {
        let fm = FileManager.default
        
        // State file path (same as ContactsHandler)
        let homeDir = fm.homeDirectoryForCurrentUser
        let havenDir = homeDir.appendingPathComponent(".haven")
        let stateFile = havenDir.appendingPathComponent("contacts_collector_state.json")
        
        // Delete state file if it exists
        if fm.fileExists(atPath: stateFile.path) {
            try fm.removeItem(at: stateFile)
            logger.info("Deleted Contacts state file", metadata: ["path": stateFile.path])
        }
        
        // Reset in-memory state
        baseState.lastRunTime = nil
        baseState.lastRunStatus = nil
        baseState.lastRunStats = nil
        baseState.lastRunError = nil
    }
}
