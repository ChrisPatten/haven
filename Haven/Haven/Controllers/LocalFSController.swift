//
//  LocalFSController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore

/// Controller for LocalFS collector
public actor LocalFSController: CollectorController {
    public let collectorId = "localfs"
    
    private let handler: LocalFSHandler
    private let baseState: BaseCollectorController
    private let logger = StubLogger(category: "localfs-controller")
    
    public init(config: HavenConfig, serviceController: ServiceController) async throws {
        self.baseState = BaseCollectorController()
        
        // LocalFSHandler doesn't need gateway client, it creates its own collector
        self.handler = LocalFSHandler(config: config)
    }
    
    public func run(request: CollectorRunRequest?) async throws -> RunResponse {
        let currentlyRunning = await isRunning()
        guard !currentlyRunning else {
            throw CollectorError.alreadyRunning
        }
        
        // Mark as running
        baseState.isRunning = true
        
        do {
            // Call handler's direct Swift API - types match, no conversion needed
            let runResponse = try await handler.runCollector(request: request)
            
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
        var lastRunStats: [String: AnyCodable]? = nil
        if let stats = stateInfo.lastRunStats {
            var dict: [String: AnyCodable] = [:]
            for (key, havenCoreValue) in stats {
                switch havenCoreValue.value {
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
}
