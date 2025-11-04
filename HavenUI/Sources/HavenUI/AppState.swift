import Foundation
import Observation

@Observable
final class AppState {
    var status: AppStatus = .red
    var processState: ProcessState = .unknown
    var healthResponse: HealthResponse?
    var lastHealthCheckTime: Date?
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
    
    // MARK: - Initialization
    
    init() {
        // Initial state is red until we can determine otherwise
    }
    
    // MARK: - Status Updates
    
    func updateHealthStatus(response: HealthResponse?) {
        healthResponse = response
        lastHealthCheckTime = Date()
        
        if response != nil {
            // Successfully got health response
            status = .green
            processState = .running
        } else {
            // Failed to get health but might still be running
            // This will be updated by launchctl status checks
            if processState == .running {
                status = .yellow
            } else {
                status = .red
            }
        }
    }
    
    func updateProcessState(_ state: ProcessState) {
        processState = state
        
        switch state {
        case .running:
            // If running, status is either green (if health check succeeds)
            // or yellow (if health check is pending/failing)
            if status == .red {
                status = .yellow
            }
        case .stopped:
            status = .red
            healthResponse = nil
        case .unknown:
            // Keep current status
            break
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
    
    func updateCollectorState(_ collectorId: String, with state: CollectorStateResponse) {
        if var collector = collectorsList.first(where: { $0.id == collectorId }) {
            // Parse last_run_time if available
            var lastRunTime: Date?
            if let lastRunTimeStr = state.lastRunTime {
                let formatter = ISO8601DateFormatter()
                lastRunTime = formatter.date(from: lastRunTimeStr)
                collector.lastRunTime = lastRunTime
            }
            collector.lastRunStatus = state.lastRunStatus
            collector.lastError = state.lastRunError
            
            // Persist the updated state
            persistCollectorState(collectorId: collectorId, lastRunTime: lastRunTime, lastRunStatus: state.lastRunStatus, lastError: state.lastRunError)
            
            // Update in list
            if let index = collectorsList.firstIndex(where: { $0.id == collectorId }) {
                collectorsList[index] = collector
            }
        }
    }
    
    // MARK: - Collector State Persistence
    
    private func persistCollectorState(collectorId: String, lastRunTime: Date?, lastRunStatus: String?, lastError: String?) {
        let key = "collector_last_run_\(collectorId)"
        
        var dict: [String: Any] = [:]
        
        if let lastRunTime = lastRunTime {
            let formatter = ISO8601DateFormatter()
            dict["lastRunTime"] = formatter.string(from: lastRunTime)
        }
        
        if let lastRunStatus = lastRunStatus {
            dict["lastRunStatus"] = lastRunStatus
        }
        
        if let lastError = lastError {
            dict["lastError"] = lastError
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
