//
//  JobModels.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HostAgentEmail

// MARK: - Job Status

public enum JobStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

// MARK: - Job Progress

public struct JobProgress: Codable {
    public var scanned: Int = 0
    public var matched: Int = 0
    public var submitted: Int = 0
    public var skipped: Int = 0
    public var errors: Int = 0  // Number of errors encountered
    public var total: Int?  // Total number of items to process (for progress calculation)
    public var currentPhase: String?  // e.g., "Scanning messages", "Submitting documents"
    public var phaseProgress: Double?  // 0.0-1.0 for current phase
    
    // Granular state tracking for iMessage collector
    public var found: Int = 0  // Found in initial query
    public var queued: Int = 0  // Extracted from chat.db, queued for enrichment
    public var enriched: Int = 0  // Enrichment complete
    
    public init(
        scanned: Int = 0,
        matched: Int = 0,
        submitted: Int = 0,
        skipped: Int = 0,
        errors: Int = 0,
        total: Int? = nil,
        currentPhase: String? = nil,
        phaseProgress: Double? = nil,
        found: Int = 0,
        queued: Int = 0,
        enriched: Int = 0
    ) {
        self.scanned = scanned
        self.matched = matched
        self.submitted = submitted
        self.skipped = skipped
        self.errors = errors
        self.total = total
        self.currentPhase = currentPhase
        self.phaseProgress = phaseProgress
        self.found = found
        self.queued = queued
        self.enriched = enriched
    }
    
    /// Calculate overall progress as a percentage (0.0-1.0)
    public var overallProgress: Double? {
        guard let total = total, total > 0 else { return nil }
        return Double(submitted) / Double(total)
    }
}

// MARK: - Collector Job

public struct CollectorJob: Identifiable, Codable {
    public let id: String
    public let collectorId: String
    public var status: JobStatus
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public let request: HostAgentEmail.CollectorRunRequest?
    public var response: HostAgentEmail.RunResponse?
    public var error: String?
    public var progress: JobProgress
    
    public init(
        id: String,
        collectorId: String,
        status: JobStatus = .pending,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        request: HostAgentEmail.CollectorRunRequest? = nil,
        response: HostAgentEmail.RunResponse? = nil,
        error: String? = nil,
        progress: JobProgress = JobProgress()
    ) {
        self.id = id
        self.collectorId = collectorId
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.request = request
        self.response = response
        self.error = error
        self.progress = progress
    }
}

