//
//  AppState.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import Observation

@MainActor
@Observable
public final class AppState {
    var status: AppStatus = .red
    var processState: ProcessState = .unknown
    var isStarting: Bool = false
    var isStopping: Bool = false
    var errorMessage: String?
    
    // Dashboard-related state
    var recentActivity: [CollectorActivity] = []
    var isRunningAllCollectors: Bool = false
    var collectorStates: [String: CollectorStateResponse] = [:]
    
    // Collectors panel state
    var collectorsList: [CollectorInfo] = []
    var runningCollectors: Set<String> = []
    
    // Job tracking
    var activeJobs: [String: CollectorJob] = [:]
    var jobHistory: [CollectorJob] = []
    
    // Full disk access status
    var fullDiskAccessGranted: Bool = true // Default to true, will be checked at startup
    
    // Contacts permission status
    var contactsPermissionGranted: Bool = true // Default to true, will be checked when needed
    
    // MARK: - Initialization
    
    init() {
        // Initial state is red until we can determine otherwise
    }
    
    // MARK: - Status Updates
    
    func updateProcessState(_ state: ProcessState) {
        processState = state
        
        switch state {
        case .running:
            status = .green
        case .stopped:
            status = .red
        case .unknown:
            status = .yellow
        }
    }
    
    func setError(_ message: String?) {
        errorMessage = message
    }
    
    func clearError() {
        errorMessage = nil
    }
    
    // MARK: - Action State
    
    func setStarting(_ value: Bool) {
        isStarting = value
    }
    
    func setStopping(_ value: Bool) {
        isStopping = value
    }
    
    func isLoading() -> Bool {
        return isStarting || isStopping || isRunningAllCollectors
    }
    
    // MARK: - Activity Management
    
    func addActivity(_ activity: CollectorActivity) {
        // Add to beginning and keep max 10 entries
        recentActivity.insert(activity, at: 0)
        if recentActivity.count > 10 {
            recentActivity = Array(recentActivity.prefix(10))
        }
    }
    
    func updateCollectorState(_ collector: String, state: CollectorStateResponse?) {
        if let state = state {
            collectorStates[collector] = state
        } else {
            collectorStates.removeValue(forKey: collector)
        }
    }
    
    func setRunningAllCollectors(_ running: Bool) {
        isRunningAllCollectors = running
    }
    
    // MARK: - Collector Management
    
    func updateCollectorsList(_ collectors: [CollectorInfo]) {
        collectorsList = collectors
    }
    
    func setCollectorRunning(_ collectorId: String, running: Bool) {
        if running {
            runningCollectors.insert(collectorId)
        } else {
            runningCollectors.remove(collectorId)
        }
    }
    
    func isCollectorRunning(_ collectorId: String) -> Bool {
        return runningCollectors.contains(collectorId)
    }
    
    // MARK: - Job Management
    
    @MainActor
    func updateJobProgress(jobId: String, progress: JobProgress) {
        // Update job progress if job exists
        // Defensive checks to avoid EXC_BAD_ACCESS
        guard !jobId.isEmpty else {
            return
        }
        
        // Safely access dictionary - defensive check
        guard let existingJob = activeJobs[jobId] else {
            return
        }
        
        // Create updated job
        var updatedJob = existingJob
        updatedJob.progress = progress
        
        // Update dictionary atomically
        activeJobs[jobId] = updatedJob
    }
    
    @MainActor
    func addJob(_ job: CollectorJob) {
        activeJobs[job.id] = job
    }
    
    @MainActor
    func removeJob(_ jobId: String) {
        activeJobs.removeValue(forKey: jobId)
    }
    
    // MARK: - Full Disk Access
    
    func setFullDiskAccessGranted(_ granted: Bool) {
        fullDiskAccessGranted = granted
    }
    
    // MARK: - Contacts Permission
    
    func setContactsPermissionGranted(_ granted: Bool) {
        contactsPermissionGranted = granted
    }
}

