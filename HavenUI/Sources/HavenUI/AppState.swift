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
        return isStarting || isStopping
    }
}
