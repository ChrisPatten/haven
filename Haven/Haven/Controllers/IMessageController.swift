//
//  IMessageController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore
import HostHTTP
import HostAgentEmail

/// Controller for iMessage collector
public actor IMessageController: CollectorController {
    public let collectorId = "imessage"
    
    private let handler: IMessageHandler
    private let baseState: BaseCollectorController
    private let logger = HavenLogger(category: "imessage-controller")
    
    public init(config: HavenConfig, serviceController: ServiceController) async throws {
        self.baseState = BaseCollectorController()
        
        let gatewayClient = try await serviceController.getGatewayClient()
        self.handler = IMessageHandler(config: config, gatewayClient: gatewayClient)
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
            let handlerProgress: ((Int, Int, Int, Int, Int?) -> Void)? = onProgress != nil ? { scanned, matched, submitted, skipped, total in
                Task { @MainActor in
                    let progress = JobProgress(
                        scanned: scanned,
                        matched: matched,
                        submitted: submitted,
                        skipped: skipped,
                        total: total,
                        currentPhase: "Processing messages",
                        phaseProgress: nil
                    )
                    onProgress?(progress)
                }
            } : nil
            
            // Call handler's direct Swift API with progress callback
            let runResponse = try await handler.runCollector(request: request, onProgress: handlerProgress)
            
            // Update state (types match, no conversion needed)
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
        // Call handler's direct Swift API - no HTTP conversion!
        let stateInfo = await handler.getCollectorState()
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        // Convert HavenCore.AnyCodable to Haven.AnyCodable
        // Access lastRunStats in a nonisolated context
        let stats = stateInfo.lastRunStats
        var lastRunStats: [String: AnyCodable]? = nil
        if let stats = stats {
            var dict: [String: AnyCodable] = [:]
            for (key, havenCoreValue) in stats {
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
        
        // Get cache directory (same logic as IMessageHandler)
        let cacheDir: URL
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDir = caches.appendingPathComponent("Haven", isDirectory: true)
        } else {
            // Fallback for older installations
            let raw = "~/.haven/cache"
            let expanded = NSString(string: raw).expandingTildeInPath
            cacheDir = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        
        // Delete fence state file
        let fenceFile = cacheDir.appendingPathComponent("imessage_state.json")
        if fm.fileExists(atPath: fenceFile.path) {
            try fm.removeItem(at: fenceFile)
            logger.info("Deleted iMessage fence state file", metadata: ["path": fenceFile.path])
        }
        
        // Delete handler state file
        let handlerStateFile = cacheDir.appendingPathComponent("imessage_handler_state.json")
        if fm.fileExists(atPath: handlerStateFile.path) {
            try fm.removeItem(at: handlerStateFile)
            logger.info("Deleted iMessage handler state file", metadata: ["path": handlerStateFile.path])
        }
        
        // Reset in-memory state
        baseState.lastRunTime = nil
        baseState.lastRunStatus = nil
        baseState.lastRunStats = nil
        baseState.lastRunError = nil
    }
    
}

public enum CollectorError: LocalizedError {
    case alreadyRunning
    case invalidResponse
    case notEnabled
    
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Collector is already running"
        case .invalidResponse:
            return "Invalid response from collector"
        case .notEnabled:
            return "Collector is not enabled"
        }
    }
}
