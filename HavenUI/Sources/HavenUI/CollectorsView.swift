import SwiftUI
import AppKit
import Combine
import UserNotifications
import Yams

struct CollectorsView: View {
    var appState: AppState
    var client: HostAgentClient
    
    @StateObject private var collectorService: CollectorService
    
    @State private var collectors: [CollectorInfo] = []
    @State private var isLoading = false
    @State private var refreshTimer: Timer?
    @State private var errorMessage: String?
    @State private var selectedCollector: String?
    @State private var editingCollector: String?
    @State private var editingPayload: String = ""
    @State private var collectorFieldValues: [String: [String: AnyCodable]] = [:]
    @State private var showingIMAPManagement = false
    
    init(appState: AppState, client: HostAgentClient) {
        self.appState = appState
        self.client = client
        _collectorService = StateObject(wrappedValue: CollectorService(client: client, appState: appState))
    }
    
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
                
                Button(action: { showingIMAPManagement = true }) {
                    Label("Manage IMAP Accounts", systemImage: "envelope.badge")
                }
                .buttonStyle(.bordered)
                .help("Manage IMAP account instances")
                
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
                    CollectorRunRequestBuilderView(
                        collector: collector,
                        collectorService: collectorService,
                        onSave: {
                            editingCollector = nil
                            refreshCollectors() // Refresh to show new IMAP accounts
                        },
                        onCancel: {
                            editingCollector = nil
                        }
                    )
                    .background(WindowFocusHelper())
                }
            }
        }
        .sheet(isPresented: $showingIMAPManagement) {
            IMAPAccountManagementView()
                .onDisappear {
                    refreshCollectors() // Refresh to show updated IMAP accounts
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
                
                // Load IMAP accounts from config file
                let imapAccounts = loadIMAPAccountsFromConfig()
                
                // Load collectors from supported set
                for (collectorId, baseInfo) in CollectorInfo.supportedCollectors {
                    // Skip generic email_imap if we have specific accounts
                    if collectorId == "email_imap" && !imapAccounts.isEmpty {
                        continue
                    }
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
                    
                    // Load persisted last run info first (as fallback)
                    loadPersistedLastRunInfo(for: &info)
                    
                    // Fetch state if available (use base collector ID for account-specific collectors)
                    if CollectorInfo.hasStateEndpoint(collectorId) && info.enabled {
                        do {
                            let baseCollectorId = extractBaseCollectorId(collectorId)
                            let state = try await client.getCollectorState(baseCollectorId)
                            
                            // Update with API state (API takes precedence)
                            if let lastRunTimeStr = state.lastRunTime {
                                let formatter = ISO8601DateFormatter()
                                info.lastRunTime = formatter.date(from: lastRunTimeStr)
                            }
                            info.lastRunStatus = state.lastRunStatus
                            info.lastError = state.lastRunError
                            
                            // Persist the state we got from API
                            savePersistedLastRunInfo(for: collectorId, lastRunTime: info.lastRunTime, lastRunStatus: info.lastRunStatus, lastError: info.lastError)
                        } catch {
                            // Continue if state fetch fails - use persisted data
                            print("Failed to fetch state for \(collectorId): \(error)")
                        }
                    }
                    
                    loadedCollectors.append(info)
                }
                
                // Add IMAP account-specific collectors
                for account in imapAccounts {
                    let accountCollectorId = "email_imap:\(account.id)"
                    
                    // Generate friendly display name from account ID
                    let friendlyProviderName = extractFriendlyProviderName(from: account.id)
                    let displayName = "IMAP \(friendlyProviderName)"
                    
                    var accountInfo = CollectorInfo(
                        id: accountCollectorId,
                        displayName: displayName,
                        description: "IMAP: \(account.host ?? "unknown host")",
                        category: "email",
                        enabled: account.enabled,
                        imapAccountId: account.id
                    )
                    
                    // Check if mail module is enabled
                    if let mailInfo = modulesResponse.modules["mail"] {
                        accountInfo.enabled = account.enabled && mailInfo.enabled
                    }
                    
                    // Load persisted last run info for this collector
                    loadPersistedLastRunInfo(for: &accountInfo)
                    
                    // Fetch state if available (email_imap doesn't have state endpoint, but we can try to persist from run responses)
                    // Note: IMAP collectors don't have /state endpoints, so we rely on persisted data
                    
                    loadedCollectors.append(accountInfo)
                }
                
                collectors = loadedCollectors.sorted { $0.displayName < $1.displayName }
                appState.updateCollectorsList(collectors)
                errorMessage = nil
            } catch {
                errorMessage = "Failed to load collectors: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Config File Loading
    
    private func loadIMAPAccountsFromConfig() -> [IMAPAccountInfo] {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".haven/hostagent.yaml")
            .path
        
        guard FileManager.default.fileExists(atPath: configPath) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let decoder = YAMLDecoder()
            
            // Partial config structure to extract just mail sources
            struct PartialConfig: Codable {
                struct Modules: Codable {
                    struct MailModule: Codable {
                        struct MailSource: Codable {
                            let id: String
                            let type: String?
                            let username: String?
                            let host: String?
                            let enabled: Bool?
                            let folders: [String]?
                        }
                        let sources: [MailSource]?
                    }
                    let mail: MailModule?
                }
                let modules: Modules?
            }
            
            let config = try decoder.decode(PartialConfig.self, from: data)
            
            guard let sources = config.modules?.mail?.sources else {
                return []
            }
            
            // Filter to IMAP sources only
            let imapSources = sources.filter { $0.type == "imap" }
            
            return imapSources.map { source in
                IMAPAccountInfo(
                    id: source.id,
                    username: source.username,
                    host: source.host,
                    enabled: source.enabled ?? true,
                    folders: source.folders
                )
            }
        } catch {
            return []
        }
    }
    
    private func refreshCollectors() {
        loadCollectors()
    }
    
    private func runCollector(_ collector: CollectorInfo) {
        Task {
            do {
                let response = try await collectorService.runCollector(collector)
                
                // Save last run information
                let now = Date()
                let status = response.status
                let error = response.errors.isEmpty ? nil : response.errors.joined(separator: "; ")
                savePersistedLastRunInfo(for: collector.id, lastRunTime: now, lastRunStatus: status, lastError: error)
                
                // Update local collectors list
                loadCollectors()
                
                // Show notification
                showNotification(
                    title: collector.displayName,
                    message: "Processed \(response.stats.submitted) items"
                )
            } catch {
                // Save error state
                let now = Date()
                savePersistedLastRunInfo(for: collector.id, lastRunTime: now, lastRunStatus: "error", lastError: error.localizedDescription)
                
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
    
    // Extract base collector ID from account-specific IDs (e.g., "email_imap" from "email_imap:personal-icloud")
    private func extractBaseCollectorId(_ collectorId: String) -> String {
        if let colonIndex = collectorId.firstIndex(of: ":") {
            return String(collectorId[..<colonIndex])
        }
        return collectorId
    }
    
    // Extract friendly provider name from account ID (e.g., "personal-icloud" -> "iCloud", "personal-gmail" -> "Gmail")
    private func extractFriendlyProviderName(from accountId: String) -> String {
        // Try to extract provider name after dash or underscore
        let separators = ["-", "_"]
        for separator in separators {
            if let range = accountId.range(of: separator) {
                let providerPart = String(accountId[range.upperBound...])
                if !providerPart.isEmpty {
                    // Capitalize first letter
                    return providerPart.prefix(1).uppercased() + providerPart.dropFirst()
                }
            }
        }
        
        // If no separator found, capitalize first letter of the whole ID
        return accountId.prefix(1).uppercased() + accountId.dropFirst()
    }
    
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
        
        Task {
            do {
                let response: RunResponse
                if !fieldValues.isEmpty {
                    let jsonPayload = try fieldValuesToJSON(fieldValues, collector: collector)
                    response = try await collectorService.runCollectorWithJSONPayload(collector, jsonPayload: jsonPayload)
                } else {
                    // For account-specific IMAP collectors, ensure account_id is included even with empty options
                    var jsonPayload = "{}"
                    if let accountId = collector.imapAccountId {
                        do {
                            var dict: [String: Any] = ["order": "desc"]
                            dict["collector_options"] = ["account_id": accountId]
                            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [])
                            jsonPayload = String(data: jsonData, encoding: .utf8) ?? "{}"
                        } catch {
                            jsonPayload = "{}"
                        }
                    }
                    response = try await collectorService.runCollectorWithJSONPayload(collector, jsonPayload: jsonPayload)
                }
                
                // Save last run information
                let now = Date()
                let status = response.status
                let error = response.errors.isEmpty ? nil : response.errors.joined(separator: "; ")
                savePersistedLastRunInfo(for: collector.id, lastRunTime: now, lastRunStatus: status, lastError: error)
                
                loadCollectors()
                showNotification(
                    title: collector.displayName,
                    message: "Processed \(response.stats.submitted) items"
                )
            } catch {
                // Save error state
                let now = Date()
                savePersistedLastRunInfo(for: collector.id, lastRunTime: now, lastRunStatus: "error", lastError: error.localizedDescription)
                
                errorMessage = "Failed to run \(collector.displayName): \(error.localizedDescription)"
                showNotification(
                    title: collector.displayName,
                    message: "Run failed: \(error.localizedDescription)"
                )
            }
        }
    }
    
    private func fieldValuesToJSON(_ fieldValues: [String: AnyCodable], collector: CollectorInfo) throws -> String {
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
        
        // For account-specific IMAP collectors, automatically include account_id if not already set
        if let accountId = collector.imapAccountId {
            if collectorOptions["account_id"] == nil {
                collectorOptions["account_id"] = accountId
            }
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
