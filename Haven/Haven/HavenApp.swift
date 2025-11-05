//
//  HavenApp.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI
import AppKit

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

    init() {
        let appState = AppState()
        let controller = HostAgentController(appState: appState)
        _appState = State(initialValue: appState)
        _hostAgentController = StateObject(wrappedValue: controller)
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
