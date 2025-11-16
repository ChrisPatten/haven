//
//  CollectorEnrichmentConfig.swift
//  Haven
//
//  Created on 12/28/24.
//

import Foundation

/// Configuration for per-collector enrichment settings
public struct CollectorEnrichmentConfig: Codable {
    /// Per-collector skip enrichment flags
    public var collectors: [String: CollectorEnrichmentSettings]
    
    public init(collectors: [String: CollectorEnrichmentSettings] = [:]) {
        self.collectors = collectors
    }
    
    /// Get skip enrichment flag for a collector
    public func getSkipEnrichment(for collectorId: String) -> Bool {
        return collectors[collectorId]?.skipEnrichment ?? false
    }
    
    /// Set skip enrichment flag for a collector
    public mutating func setSkipEnrichment(for collectorId: String, skip: Bool) {
        if collectors[collectorId] == nil {
            collectors[collectorId] = CollectorEnrichmentSettings()
        }
        collectors[collectorId]?.skipEnrichment = skip
    }
}

/// Settings for a single collector's enrichment
public struct CollectorEnrichmentSettings: Codable {
    public var skipEnrichment: Bool
    
    public init(skipEnrichment: Bool = false) {
        self.skipEnrichment = skipEnrichment
    }
}

