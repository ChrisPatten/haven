//
//  EnrichmentConfigManager.swift
//  Haven
//
//  Created on 12/28/24.
//

import Foundation

/// Manager for loading and saving per-collector enrichment configuration
public class EnrichmentConfigManager {
    private let configFileURL: URL
    
    public init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let havenDir = homeDir.appendingPathComponent(".haven")
        
        // Create .haven directory if it doesn't exist
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        
        self.configFileURL = havenDir.appendingPathComponent("collector_enrichment.plist")
    }
    
    /// Load enrichment configuration from plist file
    public func loadEnrichmentConfig() -> CollectorEnrichmentConfig {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            // Return default config if file doesn't exist
            return CollectorEnrichmentConfig()
        }
        
        guard let data = try? Data(contentsOf: configFileURL) else {
            return CollectorEnrichmentConfig()
        }
        
        // Try to decode as plist dictionary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return CollectorEnrichmentConfig()
        }
        
        // Convert plist dictionary to CollectorEnrichmentConfig
        var collectors: [String: CollectorEnrichmentSettings] = [:]
        
        for (collectorId, value) in plist {
            if let collectorDict = value as? [String: Any],
               let skipEnrichment = collectorDict["skipEnrichment"] as? Bool {
                collectors[collectorId] = CollectorEnrichmentSettings(skipEnrichment: skipEnrichment)
            }
        }
        
        return CollectorEnrichmentConfig(collectors: collectors)
    }
    
    /// Save enrichment configuration to plist file
    public func saveEnrichmentConfig(_ config: CollectorEnrichmentConfig) throws {
        // Convert CollectorEnrichmentConfig to plist dictionary
        var plistDict: [String: Any] = [:]
        
        for (collectorId, settings) in config.collectors {
            plistDict[collectorId] = [
                "skipEnrichment": settings.skipEnrichment
            ]
        }
        
        // Write to plist file
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: configFileURL, options: .atomic)
    }
    
    /// Get skip enrichment flag for a specific collector
    public func getSkipEnrichment(for collectorId: String) -> Bool {
        let config = loadEnrichmentConfig()
        return config.getSkipEnrichment(for: collectorId)
    }
    
    /// Set skip enrichment flag for a specific collector
    public func setSkipEnrichment(for collectorId: String, skip: Bool) throws {
        var config = loadEnrichmentConfig()
        config.setSkipEnrichment(for: collectorId, skip: skip)
        try saveEnrichmentConfig(config)
    }
}

