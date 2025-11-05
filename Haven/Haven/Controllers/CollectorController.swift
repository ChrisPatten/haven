//
//  CollectorController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation

/// Protocol defining common collector interface
public protocol CollectorController {
    /// Get the collector ID
    var collectorId: String { get }
    
    /// Run the collector with optional request
    func run(request: CollectorRunRequest?) async throws -> RunResponse
    
    /// Get current collector state
    func getState() async -> CollectorStateResponse?
    
    /// Check if collector is currently running
    func isRunning() async -> Bool
}

/// Base implementation providing common functionality
/// Note: This is a regular class, not an actor, to allow direct access from actor controllers
/// Marked as nonisolated to prevent main actor isolation warnings
public nonisolated class BaseCollectorController {
    public var isRunning: Bool = false
    public var lastRunTime: Date?
    public var lastRunStatus: String?
    public var lastRunStats: [String: Any]?
    public var lastRunError: String?
    
    public init() {}
    
    /// Build collector state response from current state
    public func buildStateResponse() -> CollectorStateResponse? {
        guard let lastRunTime = lastRunTime else {
            return nil
        }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        return CollectorStateResponse(
            isRunning: isRunning,
            lastRunStatus: lastRunStatus,
            lastRunTime: formatter.string(from: lastRunTime),
            lastRunStats: nil, // Will be populated by subclasses if needed
            lastRunError: lastRunError
        )
    }
    
    /// Update state from run response
    /// Note: Uses snake_case properties to match real RunResponse from hostagent
    public func updateState(from response: RunResponse) {
        isRunning = false
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lastRunTime = formatter.date(from: response.started_at)
        lastRunStatus = response.status.rawValue
        lastRunError = response.errors.isEmpty ? nil : response.errors.joined(separator: "; ")
        
        // Convert stats to dictionary
        var statsDict: [String: Any] = [
            "scanned": response.stats.scanned,
            "matched": response.stats.matched,
            "submitted": response.stats.submitted,
            "skipped": response.stats.skipped,
            "batches": response.stats.batches
        ]
        if let earliest = response.stats.earliest_touched {
            statsDict["earliest_touched"] = earliest
        }
        if let latest = response.stats.latest_touched {
            statsDict["latest_touched"] = latest
        }
        lastRunStats = statsDict
    }
}

