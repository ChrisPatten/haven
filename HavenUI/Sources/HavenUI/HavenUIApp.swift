import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var client: HostAgentClient?
    private var poller: HealthPoller?
    var launchAgentManager: LaunchAgentManager?
    private var initialized = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState = appState, !initialized else {
            return
        }

        initialized = true
        
        // Set activation policy to regular so app appears in dock
        NSApplication.shared.setActivationPolicy(.regular)
        
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
    @Environment(\.openWindow) private var openWindow

    init() {
        // Pass appState to delegate
        appDelegate.appState = appState
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                appState: appState,
                openDashboard: { openWindow(id: "dashboard") },
                startAction: startHostAgent,
                stopAction: stopHostAgent,
                runAllAction: runAllCollectors
            )
        } label: {
            // Custom colored icon instead of systemImage
            Image(systemName: "circle.fill")
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.palette)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                // Placeholder for custom menu if needed
            }
        }

        WindowGroup("Haven Dashboard", id: "dashboard") {
            if let client = appDelegate.client {
                DashboardView(
                    appState: appState,
                    client: client,
                    startAction: startHostAgent,
                    stopAction: stopHostAgent,
                    runAllAction: runAllCollectors
                )
            } else {
                // Fallback when client isn't available yet
                Text("Loading...")
                    .frame(minWidth: 500, minHeight: 400)
            }
        }
        .keyboardShortcut("1", modifiers: [.command])
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
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
    
    private func runAllCollectors() async {
        guard let client = appDelegate.client else { return }
        
        appState.setRunningAllCollectors(true)
        defer { appState.setRunningAllCollectors(false) }
        
        do {
            // Get list of modules
            let modulesResponse = try await client.getModules()
            
            // Filter to enabled collectors (we'll try common collector names)
            let commonCollectors = ["imessage", "email_imap", "localfs", "contacts"]
            let enabledCollectors = commonCollectors.filter { collector in
                modulesResponse.modules[collector]?.enabled ?? false
            }
            
            // Run each collector sequentially
            for collector in enabledCollectors {
                do {
                    let response = try await client.runCollector(collector)
                    
                    // Create activity record
                    let activity = CollectorActivity(
                        id: response.runId,
                        collector: collector,
                        timestamp: Date(),
                        status: response.status,
                        scanned: response.stats.scanned,
                        submitted: response.stats.submitted,
                        errors: response.errors
                    )
                    appState.addActivity(activity)
                    
                    // Show notification
                    showNotification(
                        title: collector.capitalized,
                        message: "Processed \(response.stats.submitted) items"
                    )
                } catch {
                    // Log error but continue with next collector
                    let activity = CollectorActivity(
                        id: UUID().uuidString,
                        collector: collector,
                        timestamp: Date(),
                        status: "error",
                        scanned: 0,
                        submitted: 0,
                        errors: [error.localizedDescription]
                    )
                    appState.addActivity(activity)
                    
                    showNotification(
                        title: collector.capitalized,
                        message: "Failed: \(error.localizedDescription)"
                    )
                }
            }
            
            appState.clearError()
        } catch {
            appState.setError("Failed to run collectors: \(error.localizedDescription)")
            showNotification(
                title: "Run All Failed",
                message: error.localizedDescription
            )
        }
    }
    
    private func showNotification(title: String, message: String) {
        let center = UNUserNotificationCenter.current()
        
        // Request permission if not already granted
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = message
                content.sound = nil
                
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                
                center.add(request) { error in
                    if let error = error {
                        print("Failed to deliver notification: \(error)")
                    }
                }
            }
        }
    }
}

// Separate view for menu content
struct MenuContent: View {
    var appState: AppState
    let openDashboard: () -> Void
    let startAction: () async -> Void
    let stopAction: () async -> Void
    let runAllAction: () async -> Void

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

            // Dashboard Button
            Button(action: openDashboard) {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
            }
            
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
            
            // Run All Button
            Button(action: {
                Task {
                    await runAllAction()
                }
            }) {
                if appState.isRunningAllCollectors {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7, anchor: .center)
                        Label("Running...", systemImage: "play.circle.fill")
                    }
                } else {
                    Label("Run All Collectors", systemImage: "play.circle.fill")
                }
            }
            .disabled(appState.status != .green || appState.isLoading())
            
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
