//
//  IMessageController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore

/// Controller for iMessage collector
public actor IMessageController: CollectorController {
    public let collectorId = "imessage"
    
    private let handler: IMessageHandler
    private let baseState: BaseCollectorController
    private let logger = StubLogger(category: "imessage-controller")
    
    public init(config: HavenConfig, serviceController: ServiceController) async throws {
        self.baseState = BaseCollectorController()
        
        let gatewayClient = try await serviceController.getGatewayClient()
        self.handler = IMessageHandler(config: config, gatewayClient: gatewayClient)
    }
    
    public func run(request: CollectorRunRequest?) async throws -> RunResponse {
        let currentlyRunning = await isRunning()
        guard !currentlyRunning else {
            throw CollectorError.alreadyRunning
        }
        
        // Mark as running
        baseState.isRunning = true
        
        do {
            // Call handler's direct Swift API - no HTTP conversion!
            let runResponse = try await handler.runCollector(request: request)
            
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
