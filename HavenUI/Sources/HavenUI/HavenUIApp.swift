import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var client: HostAgentClient?
    private var poller: HealthPoller?
    var processManager: HostAgentProcessManager?
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
        let newProcessManager = HostAgentProcessManager()

        self.client = newClient
        self.poller = newPoller
        self.processManager = newProcessManager

        Task {
            // Auto-start hostagent as a child process
            do {
                try await newProcessManager.startHostAgent()
                print("✓ Started hostagent process on launch")
                appState.updateProcessState(.running)
                
                // Give hostagent a moment to initialize before polling
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            } catch {
                print("⚠️ Failed to start hostagent on launch: \(error.localizedDescription)")
                appState.setError("Failed to start: \(error.localizedDescription)")
                appState.updateProcessState(.stopped)
            }
            
            // Start health polling after starting hostagent
            newPoller.startPolling()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Stop hostagent child process when the UI app exits
        guard let manager = processManager else { return }

        // Block the terminating thread until we finish shutdown (max 3s)
        let deadline = Date().addingTimeInterval(3.0)
        var stopped = false

        // Because this is an actor, perform a synchronous hop via Task and wait.
        let group = DispatchGroup()
        group.enter()
        Task {
            do {
                try await manager.stopHostAgent()
                print("✓ Stopped hostagent on exit")
                stopped = true
            } catch {
                print("⚠️ Failed graceful stop: \(error.localizedDescription)")
            }
            group.leave()
        }
        while group.wait(timeout: .now() + 0.05) == .timedOut && Date() < deadline { /* spin */ }

        if !stopped {
            // Fallback force kill
            Task { await manager.forceStop() }
            // Give a brief moment
            usleep(150_000)
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
                openDashboard: { openOrFocusDashboard() },
                openCollectors: { openOrFocusCollectors() },
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
                .background(WindowFocusHelper())
            } else {
                // Fallback when client isn't available yet
                Text("Loading...")
                    .frame(minWidth: 500, minHeight: 400)
            }
        }
        .keyboardShortcut("1", modifiers: [.command])
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 600, height: 500)
        
        WindowGroup("Haven Collectors", id: "collectors") {
            if let client = appDelegate.client {
                CollectorsView(
                    appState: appState,
                    client: client
                )
                .background(WindowFocusHelper())
            } else {
                // Fallback when client isn't available yet
                Text("Loading...")
                    .frame(minWidth: 700, minHeight: 400)
            }
        }
        .keyboardShortcut("2", modifiers: [.command])
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

    private func openOrFocusDashboard() {
        // Activate the app first to ensure it comes to foreground
        // This must happen before opening the window
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // Check if dashboard window already exists
        if let existingWindow = NSApplication.shared.windows.first(where: { window in
            window.identifier?.rawValue == "dashboard" ||
            window.title == "Haven Dashboard"
        }) {
            // Bring existing window to front
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            existingWindow.makeMain()
        } else {
            // Open new dashboard window
            openWindow(id: "dashboard")
            
            // Ensure the new window is focused when it appears
            // Use multiple attempts to catch window creation
            func bringWindowToFront() {
                if let newWindow = NSApplication.shared.windows.first(where: { window in
                    window.identifier?.rawValue == "dashboard" ||
                    window.title == "Haven Dashboard"
                }) {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    newWindow.makeKeyAndOrderFront(nil)
                    newWindow.orderFrontRegardless()
                    newWindow.makeMain()
                }
            }
            
            // Try immediately
            DispatchQueue.main.async {
                bringWindowToFront()
            }
            
            // Try after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                bringWindowToFront()
            }
            
            // Try after longer delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                bringWindowToFront()
            }
        }
    }
    
    private func openOrFocusCollectors() {
        // Activate the app first to ensure it comes to foreground
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // Check if collectors window already exists
        if let existingWindow = NSApplication.shared.windows.first(where: { window in
            window.identifier?.rawValue == "collectors" ||
            window.title == "Haven Collectors"
        }) {
            // Bring existing window to front
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            existingWindow.makeMain()
        } else {
            // Open new collectors window
            openWindow(id: "collectors")
            
            // Ensure the new window is focused when it appears
            // Use multiple attempts to catch window creation
            func bringWindowToFront() {
                if let newWindow = NSApplication.shared.windows.first(where: { window in
                    window.identifier?.rawValue == "collectors" ||
                    window.title == "Haven Collectors"
                }) {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    newWindow.makeKeyAndOrderFront(nil)
                    newWindow.orderFrontRegardless()
                    newWindow.makeMain()
                }
            }
            
            // Try immediately
            DispatchQueue.main.async {
                bringWindowToFront()
            }
            
            // Try after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                bringWindowToFront()
            }
            
            // Try after longer delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                bringWindowToFront()
            }
        }
    }

    private func startHostAgent() async {
        guard let manager = appDelegate.processManager else { return }
        
        appState.setStarting(true)
        defer { appState.setStarting(false) }
        
        do {
            try await manager.startHostAgent()
            appState.updateProcessState(.running)
            appState.clearError()
            
            // Give it a moment to initialize
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        } catch {
            appState.setError("Failed to start: \(error.localizedDescription)")
            appState.updateProcessState(.stopped)
        }
    }
    
    private func stopHostAgent() async {
        guard let manager = appDelegate.processManager else { return }
        
        appState.setStopping(true)
        defer { appState.setStopping(false) }
        
        do {
            try await manager.stopHostAgent()
            appState.updateProcessState(.stopped)
            appState.clearError()
        } catch {
            appState.setError("Failed to stop: \(error.localizedDescription)")
            let state = await manager.getProcessState()
            appState.updateProcessState(state)
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
                    
                    // Persist last run information
                    persistCollectorRunInfo(collectorId: collector, response: response)
                    
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
                    // Persist error state
                    persistCollectorRunError(collectorId: collector, error: error.localizedDescription)
                    
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
        // Check if we're running in a proper bundle context
        // UNUserNotificationCenter requires a valid bundle to work
        guard Bundle.main.bundleIdentifier != nil else {
            // Running in debug/script mode without proper bundle
            // Just log to console instead
            print("📣 \(title): \(message)")
            return
        }
        
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
            } else {
                // Permission denied or error, fallback to console
                print("📣 \(title): \(message)")
            }
        }
    }
    
    // MARK: - Collector State Persistence
    
    private func persistCollectorRunInfo(collectorId: String, response: RunResponse) {
        let key = "collector_last_run_\(collectorId)"
        
        var dict: [String: Any] = [:]
        
        // Save current time as last run time
        let formatter = ISO8601DateFormatter()
        dict["lastRunTime"] = formatter.string(from: Date())
        dict["lastRunStatus"] = response.status
        
        if !response.errors.isEmpty {
            dict["lastError"] = response.errors.joined(separator: "; ")
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    private func persistCollectorRunError(collectorId: String, error: String) {
        let key = "collector_last_run_\(collectorId)"
        
        var dict: [String: Any] = [:]
        
        // Save current time as last run time
        let formatter = ISO8601DateFormatter()
        dict["lastRunTime"] = formatter.string(from: Date())
        dict["lastRunStatus"] = "error"
        dict["lastError"] = error
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// Separate view for menu content
struct MenuContent: View {
    var appState: AppState
    let openDashboard: () -> Void
    let openCollectors: () -> Void
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
            
            // Collectors Button
            Button(action: { openCollectors() }) {
                Label("Collectors", systemImage: "list.bullet")
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
