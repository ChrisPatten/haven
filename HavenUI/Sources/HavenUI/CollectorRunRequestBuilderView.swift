import SwiftUI
import Foundation
import Yams

/// Collector Run Request Builder - v2 UI for building CollectorRunRequest with scope, filters, and redaction_override
/// Uses ViewModel pattern to separate business logic from view
struct CollectorRunRequestBuilderView: View {
    let collector: CollectorInfo
    let collectorService: CollectorService
    let onSave: () -> Void
    let onCancel: () -> Void
    
    @StateObject private var viewModel: CollectorRunRequestBuilderViewModel
    @State private var selectedTab: CollectorTab = .run
    @State private var isRunning = false
    @State private var errorMessage: String?
    
    init(collector: CollectorInfo, collectorService: CollectorService, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.collector = collector
        self.collectorService = collectorService
        self.onSave = onSave
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: CollectorRunRequestBuilderViewModel(collector: collector, collectorService: collectorService))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure \(collector.displayName)")
                        .font(.headline)
                    Text("Build collector run request")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.controlBackgroundColor))
            
            Divider()
            
            // Tabs
            HStack(spacing: 0) {
                TabButton(title: "Run", isSelected: selectedTab == .run) {
                    selectedTab = .run
                }
                TabButton(title: "Scope", isSelected: selectedTab == .scope) {
                    selectedTab = .scope
                }
                TabButton(title: "Preview", isSelected: selectedTab == .preview) {
                    selectedTab = .preview
                    viewModel.updatePreview()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .run:
                        RunPanelView(
                            mode: $viewModel.mode,
                            order: $viewModel.order,
                            limit: $viewModel.limit,
                            concurrency: $viewModel.concurrency,
                            batch: $viewModel.batch,
                            batchSize: $viewModel.batchSize,
                            useDateRange: $viewModel.useDateRange,
                            sinceDate: $viewModel.sinceDate,
                            untilDate: $viewModel.untilDate,
                            useTimeWindow: $viewModel.useTimeWindow,
                            timeWindow: $viewModel.timeWindow,
                            showFilters: $viewModel.showFilters,
                            filterCombinationMode: $viewModel.filterCombinationMode,
                            filterDefaultAction: $viewModel.filterDefaultAction,
                            filterInline: $viewModel.filterInline,
                            filterFiles: $viewModel.filterFiles,
                            filterEnvVar: $viewModel.filterEnvVar,
                            showRedaction: $viewModel.showRedaction,
                            redactionOverrides: $viewModel.redactionOverrides,
                            waitForCompletion: $viewModel.waitForCompletion,
                            timeoutMs: $viewModel.timeoutMs
                        )
                        
                    case .scope:
                        ScopePanelView(
                            collector: collector,
                            scopeData: $viewModel.scopeData,
                            modulesResponse: viewModel.modulesResponse
                        )
                        
                    case .preview:
                        PreviewPanelView(previewJSON: viewModel.previewJSON)
                    }
                    
                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(20)
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Save") {
                    viewModel.saveSettings()
                    onSave()
                }
                .buttonStyle(.bordered)
                
                Button("Save & Run") {
                    viewModel.saveSettings()
                    runCollector()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.controlBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(.controlBackgroundColor))
        .task {
            await viewModel.loadModules()
            viewModel.loadPersistedSettings()
        }
    }
    
    private func runCollector() {
        isRunning = true
        errorMessage = nil
        Task {
            do {
                _ = try await viewModel.runCollector()
                onSave()
            } catch {
                errorMessage = "Failed to run collector: \(error.localizedDescription)"
            }
            isRunning = false
        }
            }
        }
        
// MARK: - Supporting Views

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Run Panel

struct RunPanelView: View {
    @Binding var mode: RunMode
    @Binding var order: RunOrder
    @Binding var limit: String
    @Binding var concurrency: String
    @Binding var batch: Bool
    @Binding var batchSize: String
    @Binding var useDateRange: Bool
    @Binding var sinceDate: Date?
    @Binding var untilDate: Date?
    @Binding var useTimeWindow: Bool
    @Binding var timeWindow: String
    @Binding var showFilters: Bool
    @Binding var filterCombinationMode: String
    @Binding var filterDefaultAction: String
    @Binding var filterInline: String
    @Binding var filterFiles: [String]
    @Binding var filterEnvVar: String
    @Binding var showRedaction: Bool
    @Binding var redactionOverrides: [String: Bool]
    @Binding var waitForCompletion: Bool
    @Binding var timeoutMs: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Basic settings
            VStack(alignment: .leading, spacing: 12) {
                Text("Basic Settings")
                    .font(.headline)
                
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $mode) {
                            Text("Simulate").tag(RunMode.simulate)
                            Text("Real").tag(RunMode.real)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Order")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $order) {
                            Text("Ascending").tag(RunOrder.asc)
                            Text("Descending").tag(RunOrder.desc)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Limit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", text: $limit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Concurrency (1-12)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", text: $concurrency)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }
            }
            
            Divider()
            
            // Batch settings
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("Batch Mode", isOn: $batch)
                    Spacer()
                }
                
                if batch {
                    HStack {
                        Text("Batch Size")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", text: $batchSize)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }
            }
            
            Divider()
            
            // Date range / Time window
            VStack(alignment: .leading, spacing: 12) {
                Text("Time Filter")
                    .font(.headline)
                
                Toggle("Use Date Range", isOn: Binding(
                    get: { useDateRange },
                    set: { newValue in
                        useDateRange = newValue
                        if newValue {
                            useTimeWindow = false
                            // Set default dates if they're nil when enabling date range
                            if sinceDate == nil {
                                sinceDate = Date()
                            }
                            if untilDate == nil {
                                untilDate = Date()
                            }
                        }
                    }
                ))
                
                if useDateRange {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Since")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(action: { sinceDate = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(sinceDate != nil ? Color.secondary : Color.secondary.opacity(0.5))
                                        .font(.caption)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help(sinceDate != nil ? "Clear date" : "Set date to null")
                            }
                            if let date = sinceDate {
                                DatePicker("", selection: Binding(
                                    get: { date },
                                    set: { sinceDate = $0 }
                                ), displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                            } else {
                                HStack {
                                    Text("No date set")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Set Date") {
                                        sinceDate = Date()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Until")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(action: { untilDate = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(untilDate != nil ? Color.secondary : Color.secondary.opacity(0.5))
                                        .font(.caption)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help(untilDate != nil ? "Clear date" : "Set date to null")
                            }
                            if let date = untilDate {
                                DatePicker("", selection: Binding(
                                    get: { date },
                                    set: { untilDate = $0 }
                                ), displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                            } else {
                                HStack {
                                    Text("No date set")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Set Date") {
                                        untilDate = Date()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                
                Toggle("Use Time Window (ISO-8601)", isOn: Binding(
                    get: { useTimeWindow },
                    set: { newValue in
                        useTimeWindow = newValue
                        if newValue {
                            useDateRange = false
                        }
                    }
                ))
                
                if useTimeWindow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duration (e.g., PT24H)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("PT24H", text: $timeWindow)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            
            Divider()
            
            // Filters (Advanced)
            DisclosureGroup("Filters (Advanced)", isExpanded: $showFilters) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Combination Mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $filterCombinationMode) {
                            Text("All").tag("all")
                            Text("Any").tag("any")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    
                    HStack {
                        Text("Default Action")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $filterDefaultAction) {
                            Text("Include").tag("include")
                            Text("Exclude").tag("exclude")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inline Filters (JSON)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $filterInline)
                            .frame(height: 80)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    // TODO: Add filter files and env var fields
                }
                .padding(.top, 8)
            }
            
            Divider()
            
            // Redaction Override (Advanced)
            DisclosureGroup("Redaction Override (Advanced)", isExpanded: $showRedaction) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Override module-level redaction defaults")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    // TODO: Add PII type toggles
                }
                .padding(.top, 8)
            }
            
            Divider()
            
            // Response settings
            VStack(alignment: .leading, spacing: 12) {
                Text("Response Settings")
                    .font(.headline)
                
                Toggle("Wait for Completion", isOn: $waitForCompletion)
                
                if !waitForCompletion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timeout (ms)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", text: $timeoutMs)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                }
            }
        }
    }
}

// MARK: - Scope Panel

struct ScopePanelView: View {
    let collector: CollectorInfo
    @Binding var scopeData: [String: AnyCodable]
    let modulesResponse: ModulesResponse?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Collector-Specific Scope")
                .font(.headline)
            
            let baseCollectorId = extractBaseCollectorId(collector.id)
            
            switch baseCollectorId {
            case "imessage":
                IMessageScopeView(
                    scopeData: $scopeData,
                    ocrEnabled: modulesResponse?.ocr.enabled ?? false,
                    entityEnabled: false // TODO: Add entity module to ModulesResponse
                )
                
            case "email_imap":
                ImapScopeView(
                    collector: collector,
                    scopeData: $scopeData
                )
                
            case "localfs":
                LocalfsScopeView(scopeData: $scopeData)
                
            case "contacts":
                ContactsScopeView(scopeData: $scopeData)
                
            default:
                Text("Scope configuration not available for this collector")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func extractBaseCollectorId(_ collectorId: String) -> String {
        if let colonIndex = collectorId.firstIndex(of: ":") {
            return String(collectorId[..<colonIndex])
        }
        return collectorId
    }
}

// MARK: - iMessage Scope

struct IMessageScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    let ocrEnabled: Bool
    let entityEnabled: Bool
    
    @State private var includeChats: [String] = []
    @State private var excludeChats: [String] = []
    @State private var includeAttachments: Bool = false
    @State private var useOcrOnAttachments: Bool = false
    @State private var extractEntities: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat Filters")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                // TODO: Add chat selector UI
                Text("Chat selection UI coming soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Include Attachments", isOn: $includeAttachments)
                
                Toggle("Use OCR on Attachments", isOn: $useOcrOnAttachments)
                    .disabled(!ocrEnabled)
                    .help(ocrEnabled ? "" : "Enable OCR module in Settings")
                
                Toggle("Extract Entities", isOn: $extractEntities)
                    .disabled(!entityEnabled)
                    .help(entityEnabled ? "" : "Enable Entity module in Settings")
            }
        }
        .onAppear {
            // Initialize state variables from scopeData binding
            if let includeAttachmentsVal = scopeData["include_attachments"], case .bool(let val) = includeAttachmentsVal {
                includeAttachments = val
            }
            if let useOcrVal = scopeData["use_ocr_on_attachments"], case .bool(let val) = useOcrVal {
                useOcrOnAttachments = val
            }
            if let extractEntitiesVal = scopeData["extract_entities"], case .bool(let val) = extractEntitiesVal {
                extractEntities = val
            }
            // TODO: Load include_chats and exclude_chats arrays when implemented
            
            // Ensure scopeData is synced with current state values
            updateScope()
        }
        .onChange(of: includeChats) { _, _ in updateScope() }
        .onChange(of: excludeChats) { _, _ in updateScope() }
        .onChange(of: includeAttachments) { _, _ in updateScope() }
        .onChange(of: useOcrOnAttachments) { _, _ in updateScope() }
        .onChange(of: extractEntities) { _, _ in updateScope() }
    }
    
    private func updateScope() {
        var scope: [String: Any] = [:]
        
        if !includeChats.isEmpty {
            scope["include_chats"] = includeChats
        }
        if !excludeChats.isEmpty {
            scope["exclude_chats"] = excludeChats
        }
        scope["include_attachments"] = includeAttachments
        scope["use_ocr_on_attachments"] = useOcrOnAttachments
        scope["extract_entities"] = extractEntities
        
        // Store scope as JSON string for now (will be properly parsed in buildJSONPayload)
        // The scope is built directly in buildJSONPayload from scopeData
        // For now, we'll store the key values directly
        scopeData["include_attachments"] = .bool(includeAttachments)
        scopeData["use_ocr_on_attachments"] = .bool(useOcrOnAttachments)
        scopeData["extract_entities"] = .bool(extractEntities)
        
        // Note: Arrays need special handling - for now we'll handle them in buildJSONPayload
        // by checking the raw scopeData structure
    }
}

// MARK: - IMAP Scope

struct ImapScopeView: View {
    let collector: CollectorInfo
    @Binding var scopeData: [String: AnyCodable]
    
    @State private var accountInfo: IMAPAccountInfo?
    @State private var selectedFolders: Set<String> = []
    @State private var availableFolders: [String] = []
    @State private var isLoadingFolders = false
    @State private var folderError: String?
    @State private var testConnectionError: String?
    @State private var isTestingConnection = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Account Info
            if let accountId = collector.imapAccountId {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Account")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    if let account = accountInfo {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Account ID: \(account.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if let host = account.host {
                                Text("Host: \(host)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if let username = account.username {
                                Text("Username: \(username)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                    Text("Account ID: \(accountId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            }
            
            Divider()
            
            // Folder Selection
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Folders")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button(action: loadFolders) {
                        if isLoadingFolders {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh folders")
                    .disabled(isLoadingFolders)
                }
                
                if let error = folderError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                if availableFolders.isEmpty && !isLoadingFolders {
                    Text("No folders available. Click refresh to load folders from the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(availableFolders, id: \.self) { folder in
                                HStack {
                                    Button(action: {
                                        if selectedFolders.contains(folder) {
                                            selectedFolders.remove(folder)
                                        } else {
                                            selectedFolders.insert(folder)
                                        }
                                        updateScope()
                                    }) {
                                        Image(systemName: selectedFolders.contains(folder) ? "checkmark.square" : "square")
                                            .foregroundStyle(selectedFolders.contains(folder) ? .blue : .secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    
                                    Text(folder)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            
            Divider()
            
            // Test Connection
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection Test")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                if let error = testConnectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Button(action: testConnection) {
                    HStack {
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Testing...")
                        } else {
                            Image(systemName: "network")
                            Text("Test Connection")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTestingConnection)
            }
        }
        .onAppear {
            loadAccountInfo()
            loadSelectedFolders()
        }
    }
    
    private func loadAccountInfo() {
        guard let accountId = collector.imapAccountId else { return }
        
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".haven/hostagent.yaml")
            .path
        
        guard FileManager.default.fileExists(atPath: configPath) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let decoder = YAMLDecoder()
            
            struct PartialConfig: Codable {
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
                let modules: MailModule?
            }
            
            let config = try decoder.decode(PartialConfig.self, from: data)
            
            guard let sources = config.modules?.sources else {
                return
            }
            
            if let source = sources.first(where: { $0.id == accountId && $0.type == "imap" }) {
                accountInfo = IMAPAccountInfo(
                    id: source.id,
                    username: source.username,
                    host: source.host,
                    enabled: source.enabled ?? true,
                    folders: source.folders
                )
                
                // Initialize available folders from config
                if let configFolders = source.folders, !configFolders.isEmpty {
                    availableFolders = configFolders
                }
            }
        } catch {
            print("Failed to load account info: \(error)")
        }
    }
    
    private func loadSelectedFolders() {
        // Load selected folders from scopeData
        if let foldersVal = scopeData["folders"], case .string(let foldersStr) = foldersVal {
            let folders = foldersStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            selectedFolders = Set(folders)
        } else if let accountFolders = accountInfo?.folders, !accountFolders.isEmpty {
            // If no folders selected but account has default folders, select all
            selectedFolders = Set(accountFolders)
            updateScope()
        }
    }
    
    private func loadFolders() {
        // TODO: Implement folder fetching from IMAP server
        // For now, use folders from config
        folderError = nil
        isLoadingFolders = true
        
        Task {
            // Simulate folder loading (would call hostagent API to fetch folders)
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
            } catch {
                // Ignore sleep errors
            }
            
            // For now, use folders from account config
            if let accountFolders = accountInfo?.folders, !accountFolders.isEmpty {
                availableFolders = accountFolders
            } else {
                // Default folders if none configured
                availableFolders = ["INBOX", "Sent", "Drafts", "Trash"]
            }
            
            isLoadingFolders = false
        }
    }
    
    private func testConnection() {
        testConnectionError = nil
        isTestingConnection = true
        
        Task {
            // TODO: Implement actual connection test via hostagent API
            // For now, simulate a test
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s delay
            } catch {
                // Ignore sleep errors
            }
            
            // Simulate success (would check actual connection)
            isTestingConnection = false
            testConnectionError = nil
            
            // In a real implementation, this would call the hostagent API
            // with mode=simulate to test the connection
        }
    }
    
    private func updateScope() {
        // Update scopeData with selected folders
        if !selectedFolders.isEmpty {
            let foldersStr = selectedFolders.sorted().joined(separator: ", ")
            scopeData["folders"] = .string(foldersStr)
        } else {
            scopeData.removeValue(forKey: "folders")
        }
        
        // Ensure account_id is set
        if let accountId = collector.imapAccountId {
            scopeData["account_id"] = .string(accountId)
        }
    }
}

// MARK: - LocalFS Scope

struct LocalfsScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    
    @State private var paths: [String] = []
    @State private var includeGlobs: [String] = []
    @State private var excludeGlobs: [String] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paths")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                // TODO: Add path picker/list
                Text("Path configuration UI coming soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Glob Patterns")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                // TODO: Add glob pattern inputs
                Text("Glob pattern configuration UI coming soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Contacts Scope

struct ContactsScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Contacts scope configuration")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // TODO: Add VCF directory picker
        }
    }
}

// MARK: - Preview Panel

struct PreviewPanelView: View {
    let previewJSON: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request Preview")
                .font(.headline)
            
            Text("JSON payload that will be sent to the API:")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            ScrollView {
                Text(previewJSON.isEmpty ? "{}" : previewJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
            }
        }
    }
}

