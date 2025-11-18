//
//  JobManager.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import SwiftUI
import Combine
import HavenCore
import HostAgentEmail

/// Manages collector runs as tracked background jobs with progress monitoring, cancellation support, and job history
@MainActor
public class JobManager: ObservableObject {
    @Published public var activeJobs: [String: CollectorJob] = [:]
    @Published public var jobHistory: [CollectorJob] = []
    
    private var jobTasks: [String: Task<Void, Never>] = [:]
    private let maxHistorySize = 100
    private let logger = HavenLogger(category: "job-manager")
    private weak var appState: AppState?
    
    public init(appState: AppState? = nil) {
        self.appState = appState
    }
    
    /// Dispatch a new job for a collector run
    /// - Parameters:
    ///   - collectorId: The collector identifier
    ///   - request: Optional collector run request parameters
    ///   - collector: The collector controller to run
    ///   - onProgress: Progress callback that will be called periodically during the job
    /// - Returns: The created CollectorJob
    /// - Throws: Error if job cannot be dispatched
    public func dispatchJob(
        collectorId: String,
        request: HostAgentEmail.CollectorRunRequest?,
        collector: any CollectorController,
        onProgress: @escaping @MainActor (JobProgress) -> Void
    ) async throws -> CollectorJob {
        // Create job with unique ID
        let jobId = UUID().uuidString
        let job = CollectorJob(
            id: jobId,
            collectorId: collectorId,
            status: .pending,
            createdAt: Date(),
            request: request
        )
        
        // Add to active jobs
        activeJobs[jobId] = job
        // Sync with AppState (already on MainActor since JobManager is @MainActor)
        appState?.addJob(job)
        logger.info("Job dispatched", metadata: ["job_id": jobId, "collector": collectorId])
        
        // Create background task
        let task = Task { [weak self] in
            guard let self = self else { return }
            
            // Update job status to running
            await MainActor.run {
                self.updateJob(jobId: jobId) { job in
                    job.status = .running
                    job.startedAt = Date()
                }
                // Sync job status update to AppState
                if let updatedJob = self.activeJobs[jobId] {
                    self.appState?.activeJobs[jobId] = updatedJob
                }
                self.appState?.setCollectorRunning(collectorId, running: true)
            }
            
            do {
                // Run collector with progress callback
                let response = try await collector.run(request: request) { progress in
                    // Update job progress on MainActor
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.updateJob(jobId: jobId) { job in
                            job.progress = progress
                        }
                        // Sync progress to AppState
                        self.appState?.updateJobProgress(jobId: jobId, progress: progress)
                        // Call external progress callback
                        onProgress(progress)
                    }
                }
                
                // Check for cancellation
                try Task.checkCancellation()
                
                // Update job with successful response
                await MainActor.run {
                    self.updateJob(jobId: jobId) { job in
                        job.status = .completed
                        job.finishedAt = Date()
                        job.response = response
                        // Update progress from response stats
                        job.progress.scanned = response.stats.scanned
                        job.progress.matched = response.stats.matched
                        job.progress.submitted = response.stats.submitted
                        job.progress.skipped = response.stats.skipped
                        // Update errors from response - extract actual error count from error messages
                        // Error messages may be formatted as "X documents failed to submit"
                        var extractedErrorCount = 0
                        for errorMsg in response.errors {
                            // Try to extract number from error message (e.g., "4717 documents failed to submit")
                            if let numberRange = errorMsg.range(of: #"\d+"#, options: .regularExpression) {
                                if let count = Int(errorMsg[numberRange]) {
                                    extractedErrorCount += count
                                }
                            } else {
                                // If no number found, count each error message as 1 error
                                extractedErrorCount += 1
                            }
                        }
                        job.progress.errors = extractedErrorCount
                    }
                }
                
                logger.info("Job completed", metadata: ["job_id": jobId, "collector": collectorId])
                
            } catch is CancellationError {
                // Job was cancelled
                await MainActor.run {
                    self.updateJob(jobId: jobId) { job in
                        job.status = .cancelled
                        job.finishedAt = Date()
                        job.error = "Job was cancelled"
                    }
                }
                
                logger.info("Job cancelled", metadata: ["job_id": jobId, "collector": collectorId])
                
            } catch {
                // Job failed
                await MainActor.run {
                    self.updateJob(jobId: jobId) { job in
                        job.status = .failed
                        job.finishedAt = Date()
                        job.error = error.localizedDescription
                    }
                }
                
                logger.error("Job failed", metadata: ["job_id": jobId, "collector": collectorId, "error": error.localizedDescription])
            }
            
            // Move job to history
            await MainActor.run {
                self.moveJobToHistory(jobId: jobId)
                self.appState?.setCollectorRunning(collectorId, running: false)
                // Sync job history with AppState
                if let job = self.jobHistory.first(where: { $0.id == jobId }) {
                    self.appState?.jobHistory.insert(job, at: 0)
                    if self.appState?.jobHistory.count ?? 0 > 100 {
                        self.appState?.jobHistory = Array(self.appState?.jobHistory.prefix(100) ?? [])
                    }
                }
            }
        }
        
        // Store task for cancellation
        jobTasks[jobId] = task
        
        return job
    }
    
    /// Cancel an active job
    /// - Parameter jobId: The job identifier to cancel
    public func cancelJob(jobId: String) async {
        guard let task = jobTasks[jobId] else {
            logger.warning("Job not found for cancellation", metadata: ["job_id": jobId])
            return
        }
        
        task.cancel()
        jobTasks.removeValue(forKey: jobId)
        
        logger.info("Job cancellation requested", metadata: ["job_id": jobId])
    }
    
    /// Get a job by ID
    /// - Parameter jobId: The job identifier
    /// - Returns: The CollectorJob if found, nil otherwise
    public func getJob(jobId: String) -> CollectorJob? {
        // Check active jobs first
        if let job = activeJobs[jobId] {
            return job
        }
        // Check history
        return jobHistory.first { $0.id == jobId }
    }
    
    /// Get active jobs for a specific collector
    /// - Parameter collectorId: The collector identifier
    /// - Returns: Array of active jobs for the collector
    public func getActiveJobs(for collectorId: String) -> [CollectorJob] {
        return Array(activeJobs.values.filter { $0.collectorId == collectorId })
    }
    
    // MARK: - Private Helpers
    
    /// Update a job atomically
    private func updateJob(jobId: String, update: (inout CollectorJob) -> Void) {
        if var job = activeJobs[jobId] {
            update(&job)
            activeJobs[jobId] = job
        }
    }
    
    /// Move a job from active to history
    private func moveJobToHistory(jobId: String) {
        guard let job = activeJobs.removeValue(forKey: jobId) else {
            return
        }
        
        // Add to history
        jobHistory.insert(job, at: 0)
        
        // Limit history size
        if jobHistory.count > maxHistorySize {
            jobHistory = Array(jobHistory.prefix(maxHistorySize))
        }
        
        // Remove from AppState active jobs (already on MainActor since moveJobToHistory is @MainActor)
        appState?.removeJob(jobId)
        
        // Remove task reference
        jobTasks.removeValue(forKey: jobId)
    }
}

