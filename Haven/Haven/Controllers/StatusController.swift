//
//  StatusController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore

/// Response structure for status information
public struct StatusResponse: Codable {
    let status: String
    let startedAt: String
    let version: String
    let uptimeSeconds: Int
    let modules: [ModuleSummary]
    
    enum CodingKeys: String, CodingKey {
        case status
        case startedAt = "started_at"
        case version
        case uptimeSeconds = "uptime_seconds"
        case modules
    }
}

/// Manages app status and module summaries
public actor StatusController {
    private let config: HavenConfig
    private let startTime: Date
    private let logger = HavenLogger(category: "status-controller")
    
    public init(config: HavenConfig, startTime: Date = Date()) {
        self.config = config
        self.startTime = startTime
    }
    
    /// Get current status response
    public func getStatus() -> StatusResponse {
        let moduleSummaries = buildModuleSummaries()
        
        return StatusResponse(
            status: "healthy",
            startedAt: ISO8601DateFormatter().string(from: startTime),
            version: "0.0.0-stub",
            uptimeSeconds: Int(Date().timeIntervalSince(startTime)),
            modules: moduleSummaries
        )
    }
    
    /// Get uptime in seconds
    public func getUptimeSeconds() -> Int {
        return Int(Date().timeIntervalSince(startTime))
    }
    
    /// Get start time
    public func getStartTime() -> Date {
        return startTime
    }
    
    /// Get module summaries
    public func getModuleSummaries() -> [ModuleSummary] {
        return buildModuleSummaries()
    }
    
    /// Get version
    public func getVersion() -> String {
        return "0.0.0-stub"
    }
    
    /// Build module summaries from config
    private func buildModuleSummaries() -> [ModuleSummary] {
        var summaries: [ModuleSummary] = []
        
        // All modules are always enabled - collectors are conditionally enabled based on instances
        // iMessage
        summaries.append(ModuleSummary(
            name: "imessage",
            enabled: true,
            status: "ready",
            extraInfo: nil
        ))
        
        // OCR
        summaries.append(ModuleSummary(
            name: "ocr",
            enabled: true,
            status: "ready",
            extraInfo: nil
        ))
        
        // FSWatch
        summaries.append(ModuleSummary(
            name: "fswatch",
            enabled: true,
            status: "ready",
            extraInfo: ["watches_count": config.modules.fswatch.watches.count]
        ))
        
        // Face detection module
        summaries.append(ModuleSummary(
            name: "face",
            enabled: true,
            status: "ready",
            extraInfo: nil
        ))
        
        // Stub and simple modules
        for name in ["contacts", "mail"] {
            summaries.append(ModuleSummary(
                name: name,
                enabled: true,
                status: "ready",
                extraInfo: nil
            ))
        }
        
        return summaries
    }
}

