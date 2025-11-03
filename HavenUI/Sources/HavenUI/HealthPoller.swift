import Foundation

@MainActor
final class HealthPoller {
    private var timer: Timer?
    private let client: HostAgentClient
    private let appState: AppState
    
    private let pollInterval: TimeInterval = 3.0
    private var isPolling = false
    
    init(client: HostAgentClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }
    
    // MARK: - Polling Control
    
    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        
        // Perform an immediate health check
        Task {
            await performHealthCheck()
        }
        
        // Set up periodic polling
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task {
                await self?.performHealthCheck()
            }
        }
    }
    
    func stopPolling() {
        isPolling = false
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Health Check

    private func performHealthCheck() async {
        do {
            let health = try await client.getHealth()
            appState.updateHealthStatus(response: health)
            appState.clearError()
        } catch {
            // Health check failed - update status to yellow if process is running
            appState.updateHealthStatus(response: nil)
            // Don't set error on every poll failure to reduce noise
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}
