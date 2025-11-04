import Foundation

@MainActor
final class HealthPoller {
    private var timer: Timer?
    private let client: HostAgentClient
    private let appState: AppState
    
    private let pollInterval: TimeInterval = 5.0  // Increased from 3 to 5 seconds to reduce load
    private var isPolling = false
    private var isChecking = false  // Prevent concurrent health checks
    
    init(client: HostAgentClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }
    
    // MARK: - Polling Control
    
    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        
        // Perform an immediate health check
        Task { @MainActor in
            await performHealthCheck()
        }
        
        // Set up periodic polling on main run loop
        // Create timer and add it to common run loop modes to prevent blocking during UI interactions
        timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isPolling else { return }
                
                // Only start a new check if one isn't already in progress
                guard !self.isChecking else {
                    return  // Skip this poll if a check is still running
                }
                
                await self.performHealthCheck()
            }
        }
        
        // Add timer to common run loop modes to prevent blocking during UI interactions
        if let timer = timer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    func stopPolling() {
        isPolling = false
        timer?.invalidate()
        timer = nil
        isChecking = false
    }
    
    // MARK: - Health Check

    private func performHealthCheck() async {
        // Prevent concurrent health checks
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        
        // The network call is async and will naturally run off the main thread during I/O
        // We're already on MainActor, so updating appState doesn't need MainActor.run
        do {
            let health = try await client.getHealth()
            appState.updateHealthStatus(response: health)
            appState.clearError()
        } catch let error as HostAgentClient.ClientError {
            // Handle specific client errors
            switch error {
            case .networkError(_):
                // Network errors (connection refused, timeout) indicate hostagent isn't running
                appState.updateHealthStatus(response: nil)
                // Only set error if process thinks it's running but we can't connect
                if appState.processState == .running {
                    appState.setError("Cannot connect to hostagent service")
                }
            case .httpError(let statusCode):
                if statusCode == 401 {
                    appState.setError("Authentication failed - check hostagent config")
                } else {
                    appState.updateHealthStatus(response: nil)
                }
            default:
                appState.updateHealthStatus(response: nil)
            }
        } catch {
            // Other errors - update status but don't spam error messages
            appState.updateHealthStatus(response: nil)
            // Don't set error on every poll failure to reduce noise
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}
