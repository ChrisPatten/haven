import SwiftUI
import AppKit
import Combine
import UserNotifications

struct CollectorsView: View {
    var appState: AppState
    var client: HostAgentClient
    
    @State private var collectors: [CollectorInfo] = []
    @State private var isLoading = false
    @State private var refreshTimer: Timer?
    @State private var errorMessage: String?
    @State private var selectedCollector: String?
    @State private var editingCollector: String?
    @State private var editingPayload: String = ""
    @State private var collectorFieldValues: [String: [String: AnyCodable]] = [:]
    
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
        .sheet(isPresented: .constant(editingCollector != nil)) {
            if let collectorId = editingCollector {
                if let collector = collectors.first(where: { $0.id == collectorId }) {
                    if let schema = CollectorSchema.schema(for: collectorId) {
                        ConfiguratorView(
                            schema: schema,
                            fieldValues: Binding(
                                get: { collectorFieldValues[collectorId] ?? [:] },
                                set: { newValues in
                                    collectorFieldValues[collectorId] = newValues
                                    // Persist settings when they change
                                    savePersistedSettings(for: collectorId, values: newValues)
                                }
                            ),
                            onSave: {
                                // Save settings one more time before running
                                if let fieldValues = collectorFieldValues[collectorId] {
                                    savePersistedSettings(for: collectorId, values: fieldValues)
                                }
                                saveAndRunCollector(collector)
                                editingCollector = nil
                            },
                            onCancel: {
                                editingCollector = nil
                            }
                        )
                    } else {
                        PayloadEditorView(
                            collectorName: collector.displayName,
                            payload: $editingPayload,
                            onSave: { payload in
                                runCollectorWithPayload(collector, customPayload: payload)
                                editingCollector = nil
                            },
                            onCancel: {
                                editingCollector = nil
                            }
                        )
                    }
                }
            }
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
            
            do {
                let modulesResponse = try await client.getModules()
                var loadedCollectors: [CollectorInfo] = []
                
                // Load collectors from supported set
                for (collectorId, baseInfo) in CollectorInfo.supportedCollectors {
                    var info = baseInfo
                    
                    // Map collector IDs to module names (some collectors share modules)
                    let moduleName = mapCollectorToModule(collectorId)
                    
                    // Check if enabled in modules
                    if let moduleInfo = modulesResponse.modules[moduleName] {
                        info.enabled = moduleInfo.enabled
                    } else if collectorId == "localfs" {
                        // localfs might not be in modules response, check if fswatch is enabled as fallback
                        // or default to enabled if we can't determine
                        if let fswatchInfo = modulesResponse.modules["fswatch"] {
                            info.enabled = fswatchInfo.enabled
                        } else {
                            // Default to enabled if we can't determine (localfs might be standalone)
                            info.enabled = true
                        }
                    }
                    
                    // Fetch state if available
                    if CollectorInfo.hasStateEndpoint(collectorId) && info.enabled {
                        do {
                            let state = try await client.getCollectorState(collectorId)
                            if let lastRunTimeStr = state.lastRunTime {
                                let formatter = ISO8601DateFormatter()
                                info.lastRunTime = formatter.date(from: lastRunTimeStr)
                            }
                            info.lastRunStatus = state.lastRunStatus
                            info.lastError = state.lastRunError
                        } catch {
                            // Continue if state fetch fails
                            print("Failed to fetch state for \(collectorId): \(error)")
                        }
                    }
                    
                    loadedCollectors.append(info)
                }
                
                collectors = loadedCollectors
                appState.updateCollectorsList(loadedCollectors)
                errorMessage = nil
            } catch {
                errorMessage = "Failed to load collectors: \(error.localizedDescription)"
            }
        }
    }
    
    private func refreshCollectors() {
        loadCollectors()
    }
    
    private func runCollector(_ collector: CollectorInfo) {
        Task {
            appState.setCollectorRunning(collector.id, running: true)
            defer { appState.setCollectorRunning(collector.id, running: false) }
            
            do {
                let response = try await client.runCollector(collector.id)
                
                // Create activity record
                let activity = CollectorActivity(
                    id: response.runId,
                    collector: collector.displayName,
                    timestamp: Date(),
                    status: response.status,
                    scanned: response.stats.scanned,
                    submitted: response.stats.submitted,
                    errors: response.errors
                )
                appState.addActivity(activity)
                
                // Refresh collector state
                if CollectorInfo.hasStateEndpoint(collector.id) {
                    try await Task.sleep(nanoseconds: 500_000_000) // Wait 0.5s for state to update
                    if let state = try? await client.getCollectorState(collector.id) {
                        appState.updateCollectorState(collector.id, with: state)
                    }
                }
                
                // Update local collectors list
                loadCollectors()
                
                // Show notification
                showNotification(
                    title: collector.displayName,
                    message: "Processed \(response.stats.submitted) items"
                )
            } catch {
                // Create error activity
                let activity = CollectorActivity(
                    id: UUID().uuidString,
                    collector: collector.displayName,
                    timestamp: Date(),
                    status: "error",
                    scanned: 0,
                    submitted: 0,
                    errors: [error.localizedDescription]
                )
                appState.addActivity(activity)
                
                errorMessage = "Failed to run \(collector.displayName): \(error.localizedDescription)"
                showNotification(
                    title: collector.displayName,
                    message: "Run failed: \(error.localizedDescription)"
                )
            }
        }
    }
    
    private func runCollectorWithPayload(_ collector: CollectorInfo, customPayload: String) {
        Task {
            appState.setCollectorRunning(collector.id, running: true)
            defer { appState.setCollectorRunning(collector.id, running: false) }
            
            do {
                print("DEBUG: About to send request to /v1/collectors/\(collector.id):run with payload: \(customPayload)")
                let response = try await client.runCollectorWithPayload(collector.id, jsonPayload: customPayload)
                print("DEBUG: Response received: \(response)")
                
                // Create activity record
                let activity = CollectorActivity(
                    id: response.runId,
                    collector: collector.displayName,
                    timestamp: Date(),
                    status: response.status,
                    scanned: response.stats.scanned,
                    submitted: response.stats.submitted,
                    errors: response.errors
                )
                appState.addActivity(activity)
                
                // Refresh collector state
                if CollectorInfo.hasStateEndpoint(collector.id) {
                    try await Task.sleep(nanoseconds: 500_000_000) // Wait 0.5s for state to update
                    if let state = try? await client.getCollectorState(collector.id) {
                        appState.updateCollectorState(collector.id, with: state)
                    }
                }
                
                // Update local collectors list
                loadCollectors()
                
                // Show notification
                showNotification(
                    title: collector.displayName,
                    message: "Processed \(response.stats.submitted) items"
                )
            } catch {
                print("DEBUG: Error running collector: \(error)")
                print("DEBUG: Error description: \(error.localizedDescription)")
                
                // Create error activity
                let activity = CollectorActivity(
                    id: UUID().uuidString,
                    collector: collector.displayName,
                    timestamp: Date(),
                    status: "error",
                    scanned: 0,
                    submitted: 0,
                    errors: [error.localizedDescription]
                )
                appState.addActivity(activity)
                
                errorMessage = "Failed to run \(collector.displayName): \(error.localizedDescription)"
                showNotification(
                    title: collector.displayName,
                    message: "Run failed: \(error.localizedDescription)"
                )
            }
        }
    }
    
    private func toggleCollectorEnabled(_ collector: CollectorInfo) {
        // TODO: Implement YAML config file read/write in separate task
        // For now, show a placeholder message
        errorMessage = "Enable/disable configuration not yet implemented"
    }
    
    private func editPayload(_ collector: CollectorInfo) {
        editingCollector = collector.id
        editingPayload = collector.payload
        // Load persisted field values for this collector
        if collectorFieldValues[collector.id] == nil {
            collectorFieldValues[collector.id] = loadPersistedSettings(for: collector.id)
        }
    }
    
    // MARK: - Persistence Helpers
    
    // Map collector IDs to their corresponding module names
    private func mapCollectorToModule(_ collectorId: String) -> String {
        switch collectorId {
        case "email_imap":
            return "mail"
        case "localfs":
            // Check if localfs module exists, otherwise check fswatch
            return "localfs"  // Will check if it exists in modules
        default:
            return collectorId
        }
    }
    
    private func loadPersistedSettings(for collectorId: String) -> [String: AnyCodable] {
        let key = "collector_settings_\(collectorId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        
        var result: [String: AnyCodable] = [:]
        for (key, value) in json {
            if let str = value as? String {
                result[key] = .string(str)
            } else if let int = value as? Int {
                result[key] = .int(int)
            } else if let double = value as? Double {
                result[key] = .double(double)
            } else if let bool = value as? Bool {
                result[key] = .bool(bool)
            }
        }
        return result
    }
    
    private func savePersistedSettings(for collectorId: String, values: [String: AnyCodable]) {
        var dict: [String: Any] = [:]
        for (key, value) in values {
            switch value {
            case .string(let s):
                dict[key] = s
            case .int(let i):
                dict[key] = i
            case .double(let d):
                dict[key] = d
            case .bool(let b):
                dict[key] = b
            case .null:
                break
            }
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            let key = "collector_settings_\(collectorId)"
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    private func saveAndRunCollector(_ collector: CollectorInfo) {
        // Convert field values to JSON payload
        let fieldValues = collectorFieldValues[collector.id] ?? [:]
        print("DEBUG: saveAndRunCollector for \(collector.id), fieldValues: \(fieldValues)")
        
        if !fieldValues.isEmpty {
            do {
                let jsonPayload = try fieldValuesToJSON(fieldValues)
                print("DEBUG: Generated JSON payload: \(jsonPayload)")
                runCollectorWithPayload(collector, customPayload: jsonPayload)
            } catch {
                errorMessage = "Failed to serialize configuration: \(error.localizedDescription)"
                print("DEBUG: Serialization error: \(error)")
            }
        } else {
            // Run with empty options
            print("DEBUG: No field values set, running with empty payload")
            runCollectorWithPayload(collector, customPayload: "{}")
        }
    }
    
    private func fieldValuesToJSON(_ fieldValues: [String: AnyCodable]) throws -> String {
        var dict: [String: Any] = [:]
        var dateRangeValues: [String: Any] = [:]
        
        // List of top-level fields from the OpenAPI spec
        let topLevelFields = Set(["mode", "limit", "order", "concurrency", "batch", "batch_size", "time_window", "cursor", "state_strategy", "dedupe_policy"])
        let dateRangeFields = Set(["since", "until"])
        let collectorOptionFields = Set(["thread_lookback_days", "message_lookback_days", "chat_db_path", "reset", "dry_run", "folder", "account_id", "max_limit", "watch_dir", "include", "exclude", "tags", "delete_after", "follow_symlinks"])
        
        var collectorOptions: [String: Any] = [:]
        
        for (key, value) in fieldValues {
            let anyValue: Any?
            
            // Convert AnyCodable to appropriate type
            switch value {
            case .string(let s):
                anyValue = s
            case .int(let i):
                anyValue = i
            case .double(let d):
                anyValue = d
            case .bool(let b):
                anyValue = b
            case .null:
                anyValue = NSNull()
            }
            
            guard let anyValue = anyValue else { continue }
            
            // Route to appropriate section
            if dateRangeFields.contains(key) {
                dateRangeValues[key] = anyValue
            } else if topLevelFields.contains(key) {
                dict[key] = anyValue
            } else if collectorOptionFields.contains(key) {
                collectorOptions[key] = anyValue
            }
        }
        
        // Add date_range if it has values
        if !dateRangeValues.isEmpty {
            dict["date_range"] = dateRangeValues
        }
        
        // Add collector_options if it has values
        if !collectorOptions.isEmpty {
            dict["collector_options"] = collectorOptions
        }
        
        // Ensure order is present (required by API)
        if dict["order"] == nil {
            dict["order"] = "desc"
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "JSON", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON"])
        }
        print("DEBUG: Final serialized JSON: \(jsonString)")
        return jsonString
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

struct PayloadEditorView: View {
    let collectorName: String
    @Binding var payload: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Edit Payload for \(collectorName)")
                .font(.headline)
                .padding(.bottom, 5)
            
            TextEditor(text: $payload)
                .frame(minHeight: 200)
                .padding(10)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Save") {
                    onSave(payload)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 300)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
    }
}

#Preview {
    CollectorsView(
        appState: AppState(),
        client: HostAgentClient()
    )
}
