//
//  MainWindowView.swift
//  Haven
//
//  Created by Codex on 11/8/25.
//

import SwiftUI
import AppKit

struct MainWindowView: View {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard
        case collectors
        case permissions
        case logs
        case settings
        
        var id: String { rawValue }
        
        var label: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .collectors: return "Collectors"
            case .permissions: return "Permissions"
            case .logs: return "Logs"
            case .settings: return "Settings"
            }
        }
        
        var icon: String {
            switch self {
            case .dashboard: return "sprout.fill"
            case .collectors: return "tray.full.fill"
            case .permissions: return "lock.shield"
            case .logs: return "text.alignleft"
            case .settings: return "gearshape.fill"
            }
        }
    }
    
    var appState: AppState
    var hostAgentController: HostAgentController
    
    @StateObject private var collectorsViewModel: CollectorsViewModel
    @SceneStorage("haven.main.selectedSection") private var storedSection: String = Section.dashboard.rawValue
    @SceneStorage("haven.main.sidebarWidth") private var sidebarWidth: Double = 250
    @State private var searchText = ""
    @State private var showingCollectorWizard = false
    @State private var wizardErrorMessage: String?
    
    init(appState: AppState, hostAgentController: HostAgentController) {
        self.appState = appState
        self.hostAgentController = hostAgentController
        _collectorsViewModel = StateObject(
            wrappedValue: CollectorsViewModel(
                hostAgentController: hostAgentController,
                appState: appState
            )
        )
    }
    
    private var selectedSection: Section {
        get { Section(rawValue: storedSection) ?? .dashboard }
        set { storedSection = newValue.rawValue }
    }
    
    private var sectionBinding: Binding<Section> {
        Binding(
            get: { selectedSection },
            set: { storedSection = $0.rawValue }
        )
    }
    
    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: sidebarWidth)
                .navigationSplitViewColumnWidth(min: 220, ideal: sidebarWidth, max: 320)
        } detail: {
            detailView(for: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ToggleSidebarButton()
            }
            
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Haven")
                        .font(.headline)
                    Text(toolbarSubtitle)
                        .font(.caption)
                        .foregroundStyle(HavenColors.textSecondary)
                }
            }
            
            ToolbarItemGroup(placement: .automatic) {
                toolbarActions(for: selectedSection)
                searchField
            }
        }
        .sheet(isPresented: $showingCollectorWizard) {
            CollectorWizardView(
                onComplete: { result in
                    showingCollectorWizard = false
                    wizardErrorMessage = nil
                    Task {
                        await collectorsViewModel.loadCollectors()
                        collectorsViewModel.selectCollector(result.collectorId)
                    }
                },
                onCancel: {
                    showingCollectorWizard = false
                },
                onError: { error in
                    wizardErrorMessage = error
                }
            )
            .frame(minWidth: 520, minHeight: 480)
        }
        .alert("Collector Wizard", isPresented: .constant(wizardErrorMessage != nil), presenting: wizardErrorMessage) { _ in
            Button("OK") {
                wizardErrorMessage = nil
            }
        } message: { message in
            Text(message)
        }
        .onAppear {
            collectorsViewModel.startPolling()
        }
        .onDisappear {
            collectorsViewModel.stopPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMainSection)) { notification in
            if let section = notification.object as? Section {
                storedSection = section.rawValue
            }
        }
    }
    
    private var sidebar: some View {
        List(selection: sectionBinding) {
            Section {
                statusCard
            }
            .listRowInsets(EdgeInsets())
            .padding(.bottom, 8)
            
            ForEach(Section.allCases) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
    }
    
    private var statusCard: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(HavenColors.status(appState.status))
                    .frame(width: 14, height: 14)
                Circle()
                    .stroke(HavenColors.status(appState.status).opacity(0.4), lineWidth: 8)
                    .frame(width: 22, height: 22)
            }
            .shadow(color: HavenColors.accentGlow.opacity(0.3), radius: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.status.description)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(appState.processState == .running ? "HostAgent running" : "HostAgent idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.controlBackgroundColor).opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(HavenColors.neutralChrome.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal, 4)
    }
    
    @ViewBuilder
    private func detailView(for section: Section) -> some View {
        switch section {
        case .dashboard:
            DashboardView(
                appState: appState,
                startAction: startHostAgent,
                stopAction: stopHostAgent,
                runAllAction: runAllCollectors
            )
            .padding()
        case .collectors:
            CollectorsView(
                appState: appState,
                hostAgentController: hostAgentController,
                viewModel: collectorsViewModel,
                filterText: searchText,
                onAddCollector: { showingCollectorWizard = true }
            )
        case .permissions:
            PermissionsDetailView(appState: appState)
                .padding()
        case .logs:
            LogsDetailView()
                .padding()
        case .settings:
            SettingsSummaryView()
                .padding()
        }
    }
    
    @ViewBuilder
    private func toolbarActions(for section: Section) -> some View {
        switch section {
        case .dashboard:
            Button {
                Task { await runAllCollectors() }
            } label: {
                Label("Run All", systemImage: "play.fill")
            }
            .disabled(appState.isLoading())
            
            Button {
                appState.clearError()
            } label: {
                Label("Dismiss Alerts", systemImage: "checkmark.circle")
            }
            .disabled(appState.errorMessage == nil)
        case .collectors:
            Button {
                collectorsViewModel.refreshCollectors()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(collectorsViewModel.isLoading)
            
            Button {
                Task { await runAllCollectors() }
            } label: {
                Label("Run All", systemImage: "play.circle.fill")
            }
            .disabled(collectorsViewModel.isLoading || collectorsViewModel.collectors.isEmpty)
            
            Button {
                showingCollectorWizard = true
            } label: {
                Label("New", systemImage: "plus")
            }
        case .permissions:
            Button {
                openPermissionsSettings()
            } label: {
                Label("Open Privacy Settings", systemImage: "lock.open")
            }
        case .logs:
            Button {
                openLogsFolder()
            } label: {
                Label("Open Logs Folder", systemImage: "folder")
            }
        case .settings:
            Button {
                NotificationCenter.default.post(name: .openSettingsToSection, object: SettingsWindow.SettingsSection.general)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
        }
    }
    
    private var searchField: some View {
        TextField("Search", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
            .accessibilityLabel("Search")
    }
    
    private var toolbarSubtitle: String {
        switch selectedSection {
        case .dashboard:
            return "Status \(appState.status.description)"
        case .collectors:
            let count = collectorsViewModel.collectors.count
            return "\(count) collectors configured"
        case .permissions:
            return appState.fullDiskAccessGranted ? "All permissions granted" : "Permissions required"
        case .logs:
            return "Local logs viewer"
        case .settings:
            return "Review Haven settings"
        }
    }
    
    // MARK: - Actions
    
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
    
    private func openPermissionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openLogsFolder() {
        let logsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Haven")
        NSWorkspace.shared.open(logsPath)
    }
}

// MARK: - Detail Views

private struct PermissionsDetailView: View {
    var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2)
                .fontWeight(.semibold)
            
            permissionRow(
                title: "Full Disk Access",
                description: "Required to scan local files, mail, and Messages database.",
                granted: appState.fullDiskAccessGranted,
                actionTitle: "Open Settings",
                action: openFullDiskAccess
            )
            
            permissionRow(
                title: "Contacts",
                description: "Used to resolve people, enrich search, and show avatars.",
                granted: appState.contactsPermissionGranted,
                actionTitle: "Request Access",
                action: requestContacts
            )
            
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func permissionRow(title: String, description: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(granted ? HavenGradients.primaryGradient : LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(Color.white)
                    .font(.title3)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if !granted {
                Button(actionTitle, action: action)
                    .buttonStyle(HavenSecondaryButtonStyle())
            } else {
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.textBackgroundColor).opacity(0.6))
        )
    }
    
    private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func requestContacts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct LogsDetailView: View {
    @State private var filterText: String = ""
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Haven/haven.log")
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Logs")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Quickly open the live Haven log file or tail output from Terminal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Button("Open Log File") {
                    NSWorkspace.shared.open(logURL)
                }
                .buttonStyle(HavenSecondaryButtonStyle())
                
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
                .buttonStyle(HavenSecondaryButtonStyle())
            }
            
            Divider()
            
            Text("Filters")
                .font(.headline)
            TextField("Search log lines…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .disabled(true)
                .overlay(alignment: .trailing) {
                    Text("Coming soon")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSummaryView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Review configuration changes, open the full settings window, or jump directly to a section.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Button("Open Settings") {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                .buttonStyle(HavenPrimaryButtonStyle())
                
                Button("Collectors") {
                    NotificationCenter.default.post(name: .openSettingsToSection, object: SettingsWindow.SettingsSection.email)
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                .buttonStyle(HavenSecondaryButtonStyle())
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
