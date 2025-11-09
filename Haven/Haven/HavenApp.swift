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
    static let openMainSection = Notification.Name("openMainSection")
}

// Static flag to track if we've opened collectors window on launch
private var hasOpenedCollectorsOnLaunch = false

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    private var initialized = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard appState != nil, !initialized else { return }
        initialized = true
        
        NSApplication.shared.setActivationPolicy(.regular)
        
        Task { @MainActor in
            await checkFullDiskAccess()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NotificationCenter.default.post(name: .openCollectorsWindowOnLaunch, object: nil)
        }
    }
    
    @MainActor
    private func checkFullDiskAccess() async {
        let hasAccess = await Task.detached(priority: .userInitiated) {
            FullDiskAccessChecker.checkFullDiskAccess()
        }.value
        
        appState?.setFullDiskAccessGranted(hasAccess)
    }
}

@main
struct HavenApp: App {
    @State private var appState = AppState()
    @StateObject private var hostAgentController: HostAgentController
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var hasOpenedMainOnLaunch = false

    init() {
        let appState = AppState()
        let controller = HostAgentController(appState: appState)
        _appState = State(initialValue: appState)
        _hostAgentController = StateObject(wrappedValue: controller)
        appDelegate.appState = appState
        
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
                openDashboard: { openMain(section: .dashboard) },
                openCollectors: { openMain(section: .collectors) },
                openSettings: { openSettingsWindow() },
                startAction: startHostAgent,
                stopAction: stopHostAgent,
                runAllAction: runAllCollectors
            )
            .background(
                Color.clear
                    .task {
                        for await _ in NotificationCenter.default.notifications(named: .openCollectorsWindowOnLaunch) {
                            guard !hasOpenedMainOnLaunch else { continue }
                            hasOpenedMainOnLaunch = true
                            openMain(section: .collectors)
                            break
                        }
                    }
            )
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToSection)) { notification in
                if let section = notification.object as? SettingsWindow.SettingsSection {
                    openSettingsWindow(to: section)
                }
            }
        } label: {
            Image(systemName: "circle.fill")
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.palette)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            
            CommandMenu("Navigate") {
                Button("Dashboard") {
                    openMain(section: .dashboard)
                }
                .keyboardShortcut("1", modifiers: [.command])
                
                Button("Collectors") {
                    openMain(section: .collectors)
                }
                .keyboardShortcut("2", modifiers: [.command])
                
                Button("Permissions") {
                    openMain(section: .permissions)
                }
                .keyboardShortcut("3", modifiers: [.command])
            }
            
            CommandMenu("Actions") {
                Button("Run All Collectors") {
                    Task { await runAllCollectors() }
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                
                Button("New Collector") {
                    openMain(section: .collectors)
                    NotificationCenter.default.post(name: .openMainSection, object: MainWindowView.Section.collectors)
                }
                .keyboardShortcut("N", modifiers: [.command])
            }
        }

        WindowGroup("Haven", id: "main") {
            MainWindowView(
                appState: appState,
                hostAgentController: hostAgentController
            )
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1120, height: 720)
        
        Settings {
            SettingsWindow()
                .frame(minWidth: 800, minHeight: 600)
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
    
    private func openMain(section: MainWindowView.Section) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openMainSection, object: section)
        
        if let existingWindow = NSApplication.shared.windows.first(where: { window in
            window.identifier?.rawValue == "main" || window.title == "Haven"
        }) {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            existingWindow.makeMain()
        } else {
            openWindow(id: "main")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let newWindow = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    newWindow.makeKeyAndOrderFront(nil)
                    newWindow.orderFrontRegardless()
                    newWindow.makeMain()
                }
            }
        }
    }
    
    private func openSettingsWindow(to section: SettingsWindow.SettingsSection? = nil) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let section = section {
            NotificationCenter.default.post(name: .openSettingsToSection, object: section)
        }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    private func openSettingsWindow() {
        openSettingsWindow(to: nil)
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
