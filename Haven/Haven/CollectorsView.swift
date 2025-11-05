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
    
    @State private var collectors: [CollectorInfo] = []
    @State private var isLoading = false
    @State private var refreshTimer: Timer?
    @State private var errorMessage: String?
    @State private var editingCollector: String?
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(statusColor)
                    .font(.system(size: 12))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collectors")
                        .font(.headline)
                    Text("Manage data collection sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: refreshCollectors) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .help("Refresh collector status")
                .disabled(isLoading)
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoading && collectors.isEmpty {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading collectors...")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(12)
                    } else if collectors.isEmpty {
                        Text("No collectors available")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        // Table header
                        HStack(spacing: 0) {
                            Text("Collector")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                            
                            Text("Enabled")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 60, alignment: .center)
                            
                            Text("Status")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 70, alignment: .center)
                            
                            Text("Last Run")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 80, alignment: .center)
                            
                            Text("Options")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 30, alignment: .center)
                            
                            Text("Action")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 70, alignment: .center)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color(.controlBackgroundColor))
                        
                        Divider()
                        
                        ForEach(collectors) { collector in
                            CollectorRowView(
                                collector: collector,
                                isRunning: appState.isCollectorRunning(collector.id),
                                onRun: { runCollector(collector) },
                                onToggleEnabled: { toggleCollectorEnabled(collector) },
                                onEditPayload: { editPayload(collector) }
                            )
                            Divider()
                        }
                    }
                    
                    // Error banner
                    if let error = errorMessage {
                        ErrorBannerView(message: error)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .background(Color(.controlBackgroundColor))
        .onAppear {
            loadCollectors()
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
        }
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
    
    private func loadCollectors() {
        Task {
            isLoading = true
            defer { isLoading = false }
            
            // For now, load from supported collectors
            // This will be replaced with actual API calls when HostAgent is integrated
            var loadedCollectors: [CollectorInfo] = []
            
            for (_, baseInfo) in CollectorInfo.supportedCollectors {
                var info = baseInfo
                
                // Load persisted last run info
                loadPersistedLastRunInfo(for: &info)
                
                loadedCollectors.append(info)
            }
            
            collectors = loadedCollectors.sorted { $0.displayName < $1.displayName }
            appState.updateCollectorsList(collectors)
            errorMessage = nil
        }
    }
    
    private func refreshCollectors() {
        loadCollectors()
    }
    
    private func runCollector(_ collector: CollectorInfo) {
        Task {
            do {
                // Parse payload if available
                var request: CollectorRunRequest? = nil
                if let payloadData = collector.payload.data(using: .utf8) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    request = try? decoder.decode(CollectorRunRequest.self, from: payloadData)
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
                
                // Update local collectors list
                loadCollectors()
                
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
                
                // Update local collectors list
                loadCollectors()
            }
        }
    }
    
    private func toggleCollectorEnabled(_ collector: CollectorInfo) {
        // TODO: Implement YAML config file read/write
        // For now, show a placeholder message
        errorMessage = "Enable/disable configuration not yet implemented"
    }
    
    private func editPayload(_ collector: CollectorInfo) {
        // TODO: Implement payload editor
        editingCollector = collector.id
        errorMessage = "Payload editor not yet implemented"
    }
    
    // MARK: - Persistence Helpers
    
    // Load persisted last run information from UserDefaults
    private func loadPersistedLastRunInfo(for collector: inout CollectorInfo) {
        let key = "collector_last_run_\(collector.id)"
        
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        // Load last run time
        if let lastRunTimeStr = dict["lastRunTime"] as? String {
            let formatter = ISO8601DateFormatter()
            collector.lastRunTime = formatter.date(from: lastRunTimeStr)
        }
        
        // Load last run status
        if let lastRunStatus = dict["lastRunStatus"] as? String {
            collector.lastRunStatus = lastRunStatus
        }
        
        // Load last error
        if let lastError = dict["lastError"] as? String {
            collector.lastError = lastError
        }
    }
    
    // Save persisted last run information to UserDefaults
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
    
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
            loadCollectors()
        }
    }
    
    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
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

// MARK: - Collector Row View

struct CollectorRowView: View {
    let collector: CollectorInfo
    let isRunning: Bool
    let onRun: () -> Void
    let onToggleEnabled: () -> Void
    let onEditPayload: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // Collector name and description
            VStack(alignment: .leading, spacing: 2) {
                Text(collector.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                
                Text(collector.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            
            // Enabled toggle
            Toggle("", isOn: .constant(collector.enabled))
                .labelsHidden()
                .frame(width: 60, alignment: .center)
                .disabled(true)  // Disable until config implementation
            
            // Status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(collector.statusDescription())
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: 70, alignment: .center)
            
            // Last run time
            Text(collector.lastRunDescription())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .center)
            
            // Edit Payload button (gear icon)
            Button(action: onEditPayload) {
                Image(systemName: "gear")
                    .font(.caption)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Edit collector options")
            .frame(width: 30, alignment: .center)
            
            // Run Now button
            Button(action: onRun) {
                if isRunning {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Running")
                            .font(.caption2)
                    }
                } else {
                    Label("Run", systemImage: "play.fill")
                        .font(.caption2)
                }
            }
            .disabled(isRunning || !collector.enabled)
            .frame(width: 70, alignment: .center)
        }
        .padding(.vertical, 6)
    }
    
    private var statusColor: Color {
        if isRunning {
            return .yellow
        }
        switch collector.lastRunStatus?.lowercased() {
        case "ok":
            return .green
        case "error":
            return .red
        case "partial":
            return .yellow
        default:
            return .gray
        }
    }
}

