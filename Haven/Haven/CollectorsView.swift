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

struct CollectorsView: View {
    var appState: AppState
    var hostAgentController: HostAgentController
    
    @StateObject private var viewModel: CollectorsViewModel
    
    @State private var runBuilderViewModel: CollectorRunRequestBuilderViewModel?
    @State private var showingRunConfiguration = false
    @State private var errorMessage: String?
    
    init(appState: AppState, hostAgentController: HostAgentController) {
        self.appState = appState
        self.hostAgentController = hostAgentController
        
        let vm = CollectorsViewModel(hostAgentController: hostAgentController, appState: appState)
        _viewModel = StateObject(wrappedValue: vm)
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            CollectorListSidebar(
                collectors: $viewModel.collectors,
                selectedCollectorId: $viewModel.selectedCollectorId,
                isCollectorRunning: { collectorId in
                    appState.isCollectorRunning(collectorId)
                },
                onRunAll: {
                    Task {
                        await runAllCollectors()
                    }
                },
                isLoading: viewModel.isLoading
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            // Detail panel
            if let collector = viewModel.getSelectedCollector() {
                CollectorDetailView(
                    collector: collector,
                    isRunning: appState.isCollectorRunning(collector.id),
                    lastRunStats: viewModel.collectorStates[collector.id],
                    onRunNow: {
                        runCollectorNow(collector)
                    },
                    onRunWithOptions: {
                        showRunConfiguration(collector)
                    },
                    onViewHistory: {
                        // TODO: Implement history view
                        errorMessage = "History view not yet implemented"
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
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: {
                    viewModel.refreshCollectors()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                
                Button(action: {
                    Task {
                        await runAllCollectors()
                    }
                }) {
                    Label("Run All", systemImage: "play.fill")
                }
                .disabled(viewModel.isLoading || viewModel.collectors.isEmpty)
            }
        }
        .sheet(isPresented: $showingRunConfiguration) {
            if let collector = viewModel.getSelectedCollector(),
               let runBuilderVM = runBuilderViewModel {
                RunConfigurationSheet(
                    collector: collector,
                    viewModel: runBuilderVM,
                    onRun: {
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
        .onAppear {
            viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
    }
    
    // MARK: - Actions
    
    private func runCollectorNow(_ collector: CollectorInfo) {
        Task {
            do {
                let response = try await hostAgentController.runCollector(id: collector.id, request: nil)
                
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
                
                // Close sheet
                showingRunConfiguration = false
                
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
