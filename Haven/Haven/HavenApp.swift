//
//  HavenApp.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI
import AppKit

extension Notification.Name {
    static let openCollectorsWindowOnLaunch = Notification.Name("openCollectorsWindowOnLaunch")
    static let openSettingsToSection = Notification.Name("openSettingsToSection")
    static let settingsConfigSaved = Notification.Name("settingsConfigSaved")
}

// Static flag to track if we've opened collectors window on launch
private var hasOpenedCollectorsOnLaunch = false

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    private var initialized = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard appState != nil, !initialized else {
            return
        }

        initialized = true
        
        // Set activation policy to regular so app appears in dock
        NSApplication.shared.setActivationPolicy(.regular)
        
        // Check for full disk access on startup
        Task { @MainActor in
            await checkFullDiskAccess()
        }
        
        // Open collectors window after delay using notification
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NotificationCenter.default.post(name: .openCollectorsWindowOnLaunch, object: nil)
        }
    }
    
    @MainActor
    private func checkFullDiskAccess() async {
        // Run the check on a background queue to avoid blocking
        let hasAccess = await Task.detached(priority: .userInitiated) {
            FullDiskAccessChecker.checkFullDiskAccess()
        }.value
        
        appState?.setFullDiskAccessGranted(hasAccess)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup will be handled here in future iterations
    }
}

@main
struct HavenApp: App {
    @State private var appState = AppState()
    @StateObject private var hostAgentController: HostAgentController
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var hasOpenedCollectorsWindowOnLaunch = false

    init() {
        let appState = AppState()
        let controller = HostAgentController(appState: appState)
        _appState = State(initialValue: appState)
        _hostAgentController = StateObject(wrappedValue: controller)
        // Pass appState to delegate
        appDelegate.appState = appState
        
        // Initialize default configuration files on first run
        Task {
            do {
                let configManager = ConfigManager()
                try await configManager.initializeDefaultsIfNeeded()
            } catch {
                print("Warning: Failed to initialize default configuration: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                appState: appState,
                openDashboard: { openOrFocusDashboard() },
                openCollectors: { openOrFocusCollectors() },
                openSettings: { openOrFocusSettings() },
                startAction: startHostAgent,
                stopAction: stopHostAgent,
                runAllAction: runAllCollectors
            )
            .background(
                // Hidden view that listens for launch notification
                Color.clear
                    .task {
                        // Listen for the notification and open collectors window
                        for await _ in NotificationCenter.default.notifications(named: .openCollectorsWindowOnLaunch) {
                            guard !hasOpenedCollectorsOnLaunch else {
                                continue
                            }
                            hasOpenedCollectorsOnLaunch = true
                            openOrFocusCollectors()
                            // Only open once, then break
                            break
                        }
                    }
            )
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToSection)) { notification in
                if let section = notification.object as? SettingsWindow.SettingsSection {
                    openOrFocusSettings(to: section)
                }
            }
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
            DashboardView(
                appState: appState,
                startAction: startHostAgent,
                stopAction: stopHostAgent,
                runAllAction: runAllCollectors
            )
        }
        .keyboardShortcut("1", modifiers: [.command])
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 600, height: 500)
        
        WindowGroup("Haven Collectors", id: "collectors") {
            CollectorsView(
                appState: appState,
                hostAgentController: hostAgentController
            )
            .background(WindowFocusHelper())
        }
        .keyboardShortcut("2", modifiers: [.command])
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)
        
        WindowGroup("Settings", id: "settings") {
            SettingsWindow()
                .background(WindowFocusHelper())
        }
        .keyboardShortcut(",", modifiers: [.command])
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 800, height: 600)
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
    
    private func openOrFocusSettings(to section: SettingsWindow.SettingsSection? = nil) {
        // Activate the app first to ensure it comes to foreground
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // Post notification if a specific section is requested
        if let section = section {
            NotificationCenter.default.post(name: .openSettingsToSection, object: section)
        }
        
        // Check if settings window already exists
        if let existingWindow = NSApplication.shared.windows.first(where: { window in
            window.identifier?.rawValue == "settings" ||
            window.title == "Settings"
        }) {
            // Bring existing window to front
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            existingWindow.makeMain()
        } else {
            // Open new settings window
            openWindow(id: "settings")
            
            // Ensure the new window is focused when it appears
            func bringWindowToFront() {
                if let newWindow = NSApplication.shared.windows.first(where: { window in
                    window.identifier?.rawValue == "settings" ||
                    window.title == "Settings"
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
        do {
            try await hostAgentController.start()
        } catch {
            appState.setError("Failed to start HostAgent: \(error.localizedDescription)")
        }
    }
    
    private func stopHostAgent() async {
        do {
            try await hostAgentController.stop()
        } catch {
            appState.setError("Failed to stop HostAgent: \(error.localizedDescription)")
        }
    }
    
    private func runAllCollectors() async {
        do {
            try await hostAgentController.runAllCollectors()
        } catch {
            appState.setError("Failed to run all collectors: \(error.localizedDescription)")
        }
    }
}
