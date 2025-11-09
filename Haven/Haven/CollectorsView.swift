//
//  CollectorsView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI
import AppKit
import Combine
import UserNotifications
import HostAgentEmail

struct CollectorsView: View {
    var appState: AppState
    var hostAgentController: HostAgentController
    @ObservedObject var viewModel: CollectorsViewModel
    var filterText: String
    var onAddCollector: () -> Void
    @AppStorage("collectors.selectedId") private var persistedCollectorId: String = ""
    
    @State private var runBuilderViewModel: CollectorRunRequestBuilderViewModel?
    @State private var showingRunConfiguration = false
    @State private var errorMessage: String?
    @State private var collectorToReset: CollectorInfo?
    @State private var showingResetConfirmation = false
    
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                // Sidebar
                CollectorListSidebar(
                    collectors: $viewModel.collectors,
                    selectedCollectorId: $viewModel.selectedCollectorId,
                    filterText: filterText,
                    isCollectorRunning: { collectorId in
                        appState.isCollectorRunning(collectorId)
                    },
                    onRunAll: {
                        Task {
                            await runAllCollectors()
                        }
                    },
                    onAddCollector: onAddCollector,
                    isLoading: viewModel.isLoading
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
            } detail: {
                // Detail panel
                if let collector = viewModel.getSelectedCollector() {
                    // Get active job progress for this collector
                    let activeJob = appState.activeJobs.values.first { $0.collectorId == collector.id && $0.status == .running }
                    let jobProgress = activeJob?.progress
                    
                    CollectorDetailView(
                        collector: collector,
                        isRunning: appState.isCollectorRunning(collector.id),
                        lastRunStats: viewModel.collectorStates[collector.id],
                        jobProgress: jobProgress,
                        onRunNow: {
                            runCollectorNow(collector)
                        },
                        onRunWithOptions: {
                            showRunConfiguration(collector)
                        },
                        onViewHistory: {
                            // TODO: Implement history view
                            errorMessage = "History view not yet implemented"
                        },
                        onCancel: {
                            cancelCollector(collector)
                        },
                        onReset: {
                            collectorToReset = collector
                            showingResetConfirmation = true
                        }
                    )
                } else {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        
                        Text("Select a collector")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        Text("Choose a collector from the sidebar to view details and run configuration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            
            // Full disk access banner
            if !appState.fullDiskAccessGranted {
                FullDiskAccessBanner()
            }
        }
        .sheet(isPresented: $showingRunConfiguration) {
            if let collector = viewModel.getSelectedCollector(),
               let runBuilderVM = runBuilderViewModel {
                RunConfigurationSheet(
                    collector: collector,
                    viewModel: runBuilderVM,
                    onRun: {
                        // Dismiss modal immediately when run button is clicked
                        showingRunConfiguration = false
                        runBuilderViewModel = nil
                        runCollectorWithConfiguration(collector, viewModel: runBuilderVM)
                    },
                    onCancel: {
                        showingRunConfiguration = false
                        runBuilderViewModel = nil
                    }
                )
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") {
                errorMessage = nil
            }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Reset Collector",
            isPresented: $showingResetConfirmation,
            presenting: collectorToReset
        ) { collector in
            Button("Reset", role: .destructive) {
                resetCollector(collector)
            }
            Button("Cancel", role: .cancel) {
                collectorToReset = nil
            }
        } message: { collector in
            Text("This will remove all state files and fences for \(collector.displayName). The collector will return to a fresh, never-run state. This action cannot be undone.")
        }
        .onAppear {
            if !persistedCollectorId.isEmpty {
                viewModel.selectCollector(persistedCollectorId)
            }
            viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsConfigSaved)) { _ in
            // Refresh collectors immediately when settings are saved
            viewModel.refreshCollectors()
        }
        .onChange(of: viewModel.selectedCollectorId) { _, newValue in
            persistedCollectorId = newValue ?? ""
        }
    }
    
    // MARK: - Actions
    
    private func runCollectorNow(_ collector: CollectorInfo) {
        // Prevent running disabled collectors
        guard collector.enabled else {
            let message: String
            switch collector.id {
            case "email_imap":
                message = "IMAP collector is disabled. Please configure at least one IMAP source to enable it."
            case "contacts":
                message = "Contacts collector is disabled. Please configure at least one contacts instance to enable it."
            case "localfs":
                message = "Files collector is disabled. Please configure at least one files instance to enable it."
            default:
                message = "Collector is disabled and cannot be run."
            }
            errorMessage = message
            return
        }
        
        Task {
            do {
                // Create default request with collector-specific defaults
                var request: HostAgentEmail.CollectorRunRequest? = nil
                if collector.id == "imessage" || collector.id == "email_imap" {
                    request = HostAgentEmail.CollectorRunRequest(
                        mode: nil,
                        limit: nil,
                        order: .desc,
                        concurrency: nil,
                        dateRange: nil,
                        timeWindow: nil,
                        batch: true,
                        batchSize: 200,
                        redactionOverride: nil,
                        filters: nil,
                        scope: nil
                    )
                }
                
                let response = try await hostAgentController.runCollector(id: collector.id, request: request)
                
                // Save last run information
                let lastRunTime = ISO8601DateFormatter().date(from: response.started_at) ?? Date()
                savePersistedLastRunInfo(
                    for: collector.id,
                    lastRunTime: lastRunTime,
                    lastRunStatus: response.status.rawValue,
                    lastError: response.errors.isEmpty ? nil : response.errors.joined(separator: "; ")
                )
                
                // Refresh collectors list
                await viewModel.loadCollectors()
                
                // Show notification
                showNotification(
                    title: collector.displayName,
                    message: "Collector run completed"
                )
            } catch {
                errorMessage = "Failed to run collector: \(error.localizedDescription)"
                appState.setError(error.localizedDescription)
                
                // Save error information
                savePersistedLastRunInfo(
                    for: collector.id,
                    lastRunTime: Date(),
                    lastRunStatus: "error",
                    lastError: error.localizedDescription
                )
                
                // Refresh collectors list
                await viewModel.loadCollectors()
            }
        }
    }
    
    private func showRunConfiguration(_ collector: CollectorInfo) {
        // Prevent showing configuration for disabled collectors
        guard collector.enabled else {
            let message: String
            switch collector.id {
            case "email_imap":
                message = "IMAP collector is disabled. Please configure at least one IMAP source to enable it."
            case "contacts":
                message = "Contacts collector is disabled. Please configure at least one contacts instance to enable it."
            case "localfs":
                message = "Files collector is disabled. Please configure at least one files instance to enable it."
            default:
                message = "Collector is disabled and cannot be run."
            }
            errorMessage = message
            return
        }
        
        let vm = CollectorRunRequestBuilderViewModel(
            collector: collector,
            hostAgentController: hostAgentController
        )
        vm.loadPersistedSettings()
        Task {
            await vm.loadModules()
        }
        
        runBuilderViewModel = vm
        showingRunConfiguration = true
    }
    
    private func runCollectorWithConfiguration(_ collector: CollectorInfo, viewModel: CollectorRunRequestBuilderViewModel) {
        Task {
            do {
                let response = try await viewModel.runCollector()
                
                // Save configuration
                viewModel.saveSettings()
                
                // Save last run information
                let lastRunTime = ISO8601DateFormatter().date(from: response.started_at) ?? Date()
                savePersistedLastRunInfo(
                    for: collector.id,
                    lastRunTime: lastRunTime,
                    lastRunStatus: response.status.rawValue,
                    lastError: response.errors.isEmpty ? nil : response.errors.joined(separator: "; ")
                )
                
                // Refresh collectors list
                await self.viewModel.loadCollectors()
                
                // Show notification
                showNotification(
                    title: collector.displayName,
                    message: "Collector run completed"
                )
            } catch {
                errorMessage = "Failed to run collector: \(error.localizedDescription)"
                appState.setError(error.localizedDescription)
            }
        }
    }
    
    private func runAllCollectors() async {
        do {
            try await hostAgentController.runAllCollectors()
            await viewModel.loadCollectors()
        } catch {
            errorMessage = "Failed to run all collectors: \(error.localizedDescription)"
            appState.setError(error.localizedDescription)
        }
    }
    
    private func cancelCollector(_ collector: CollectorInfo) {
        Task {
            await hostAgentController.cancelCollector(id: collector.id)
            await viewModel.loadCollectors()
            
            // Show notification
            showNotification(
                title: collector.displayName,
                message: "Collector run cancelled"
            )
        }
    }
    
    private func resetCollector(_ collector: CollectorInfo) {
        Task {
            do {
                try await hostAgentController.resetCollector(id: collector.id)
                await viewModel.loadCollectors()
                
                // Show notification
                showNotification(
                    title: collector.displayName,
                    message: "Collector reset successfully"
                )
            } catch {
                errorMessage = "Failed to reset collector: \(error.localizedDescription)"
                appState.setError(error.localizedDescription)
            }
        }
    }
    
    // MARK: - Persistence Helpers
    
    private func savePersistedLastRunInfo(for collectorId: String, lastRunTime: Date?, lastRunStatus: String?, lastError: String?) {
        let key = "collector_last_run_\(collectorId)"
        
        var dict: [String: Any] = [:]
        
        if let lastRunTime = lastRunTime {
            let formatter = ISO8601DateFormatter()
            dict["lastRunTime"] = formatter.string(from: lastRunTime)
        }
        
        if let lastRunStatus = lastRunStatus {
            dict["lastRunStatus"] = lastRunStatus
        }
        
        if let lastError = lastError {
            dict["lastError"] = lastError
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    // MARK: - Notifications
    
    private func showNotification(title: String, message: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            print("📣 \(title): \(message)")
            return
        }
        
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
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
                print("📣 \(title): \(message)")
            }
        }
    }
}

// MARK: - Full Disk Access Banner

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access Required")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Text("Haven needs Full Disk Access to collect data from your Mac. Click the button below to open System Settings and grant access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                openSystemSettings()
            }) {
                Label("Open Full Disk Access Settings", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Color.orange.opacity(0.1)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }
    
    private func openSystemSettings() {
        // Deep link to Full Disk Access settings pane
        // This URL scheme works for both System Preferences (macOS Monterey and earlier)
        // and System Settings (macOS Ventura+)
        // The Privacy_AllFiles parameter opens directly to the Full Disk Access section
        
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        
        guard let url = URL(string: urlString) else {
            // Fallback: try to open System Settings app directly
            if let settingsURL = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(settingsURL)
            }
            return
        }
        
        // Open the deep link to Full Disk Access settings
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Run Configuration Sheet

struct RunConfigurationSheet: View {
    let collector: CollectorInfo
    @ObservedObject var viewModel: CollectorRunRequestBuilderViewModel
    let onRun: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            RunConfigurationView(viewModel: viewModel)
                .navigationTitle("Run Configuration: \(collector.displayName)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Run", action: onRun)
                            .buttonStyle(.borderedProminent)
                    }
                }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}
