import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var client: HostAgentClient?
    var poller: HealthPoller?
    var launchAgentManager: LaunchAgentManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState = appState else { return }
        
        let newClient = HostAgentClient()
        let newPoller = HealthPoller(client: newClient, appState: appState)
        let newLaunchAgentManager = LaunchAgentManager()
        
        self.client = newClient
        self.poller = newPoller
        self.launchAgentManager = newLaunchAgentManager
        
        Task {
            ensureLogsDirectory()
            newPoller.startPolling()
            
            let state = await newLaunchAgentManager.getProcessState()
            appState.updateProcessState(state)
        }
    }
    
    private func ensureLogsDirectory() {
        let fileManager = FileManager.default
        let logsPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Haven")
        
        try? fileManager.createDirectory(
            at: logsPath,
            withIntermediateDirectories: true
        )
    }
}

@main
struct HavenUIApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var launchAgentManager: LaunchAgentManager?
    
    var body: some Scene {
        MenuBarExtra("Haven", systemImage: "circle.fill") {
            MenuContent(
                appState: appState,
                startAction: startHostAgent,
                stopAction: stopHostAgent
            )
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                // Placeholder for custom menu if needed
            }
        }
        .onChange(of: appState.status) { _, _ in
            // Ensure delegate has access to app state
            appDelegate.appState = appState
            if launchAgentManager == nil {
                launchAgentManager = appDelegate.launchAgentManager
            }
        }
    }
    
    private func startHostAgent() async {
        guard let manager = appDelegate.launchAgentManager else { return }
        
        appState.setStarting(true)
        defer { appState.setStarting(false) }
        
        do {
            try await manager.startHostAgent()
            appState.updateProcessState(.running)
            appState.clearError()
        } catch {
            appState.setError("Failed to start: \(error.localizedDescription)")
            appState.updateProcessState(.unknown)
        }
    }
    
    private func stopHostAgent() async {
        guard let manager = appDelegate.launchAgentManager else { return }
        
        appState.setStopping(true)
        defer { appState.setStopping(false) }
        
        do {
            try await manager.stopHostAgent()
            appState.updateProcessState(.stopped)
            appState.clearError()
        } catch {
            appState.setError("Failed to stop: \(error.localizedDescription)")
            appState.updateProcessState(.unknown)
        }
    }
}

// Separate view for menu content
struct MenuContent: View {
    var appState: AppState
    let startAction: () async -> Void
    let stopAction: () async -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            // Status Section
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(statusColor)
                Text(appState.status.description)
                    .font(.system(.body, design: .default))
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(4)
            
            Divider()
            
            // Start/Stop Controls
            HStack(spacing: 12) {
                Button(action: {
                    Task {
                        await startAction()
                    }
                }) {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(appState.status == .green || appState.isLoading())
                
                Button(action: {
                    Task {
                        await stopAction()
                    }
                }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(appState.status == .red || appState.isLoading())
            }
            .padding(4)
            
            Divider()
            
            // Error Display
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(4)
            }
            
            Divider()
            
            // Quit
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit", systemImage: "xmark")
            }
        }
        .padding(8)
        .frame(minWidth: 250)
    }
    
    private var statusColor: Color {
        switch appState.status {
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .red:
            return .red
        }
    }
}
