import Foundation
import Yams

/// View model for CollectorRunRequestBuilderView
/// Handles all state management and payload construction, separating it from the view
@MainActor
class CollectorRunRequestBuilderViewModel: ObservableObject {
    let collector: CollectorInfo
    private let collectorService: CollectorService
    
    // Tab selection
    @Published var selectedTab: CollectorTab = .run
    
    // Run settings
    @Published var mode: RunMode = .real
    @Published var order: RunOrder = .desc
    @Published var limit: String = ""
    @Published var concurrency: String = ""
    @Published var batch: Bool = false
    @Published var batchSize: String = ""
    
    // Date range
    @Published var useDateRange: Bool = false
    @Published var sinceDate: Date? = nil
    @Published var untilDate: Date? = nil
    
    // Time window (ISO-8601 duration)
    @Published var useTimeWindow: Bool = false
    @Published var timeWindow: String = ""
    
    // Filters
    @Published var showFilters: Bool = false
    @Published var filterCombinationMode: String = "all"
    @Published var filterDefaultAction: String = "include"
    @Published var filterInline: String = ""
    @Published var filterFiles: [String] = []
    @Published var filterEnvVar: String = ""
    
    // Redaction override
    @Published var showRedaction: Bool = false
    @Published var redactionOverrides: [String: Bool] = [:]
    
    // Response
    @Published var waitForCompletion: Bool = true
    @Published var timeoutMs: String = ""
    
    // Collector-specific scope
    @Published var scopeData: [String: AnyCodable] = [:]
    
    // Preview
    @Published var previewJSON: String = ""
    
    // Module capabilities
    @Published var modulesResponse: ModulesResponse?
    
    init(collector: CollectorInfo, collectorService: CollectorService) {
        self.collector = collector
        self.collectorService = collectorService
    }
    
    // MARK: - Load Settings
    
    func loadModules() async {
        do {
            modulesResponse = try await collectorService.getModules()
        } catch {
            print("Failed to load modules: \(error)")
        }
    }
    
    func loadPersistedSettings() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".haven/haven_ui_collectors.yaml")
            .path
        
        guard FileManager.default.fileExists(atPath: configPath) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let decoder = YAMLDecoder()
            
            struct CollectorSettingsFile: Codable {
                var collectors: [String: CollectorSettings]?
                
                struct CollectorSettings: Codable {
                    var mode: String?
                    var order: String?
                    var limit: Int?
                    var concurrency: Int?
                    var batch: Bool?
                    var batch_size: Int?
                    var date_range: DateRange?
                    var time_window: String?
                    var wait_for_completion: Bool?
                    var timeout_ms: Int?
                    var scope: [String: String]?
                    
                    struct DateRange: Codable {
                        var since: String?
                        var until: String?
                    }
                }
            }
            
            let settingsFile = try decoder.decode(CollectorSettingsFile.self, from: data)
            
            guard let collectorSettings = settingsFile.collectors?[collector.id] else {
                return
            }
            
            // Load settings
            if let modeStr = collectorSettings.mode, let modeVal = RunMode(rawValue: modeStr) {
                mode = modeVal
            }
            if let orderStr = collectorSettings.order, let orderVal = RunOrder(rawValue: orderStr) {
                order = orderVal
            }
            if let limitVal = collectorSettings.limit {
                limit = String(limitVal)
            }
            if let concurrencyVal = collectorSettings.concurrency {
                concurrency = String(concurrencyVal)
            }
            if let batchVal = collectorSettings.batch {
                batch = batchVal
            }
            if let batchSizeVal = collectorSettings.batch_size {
                batchSize = String(batchSizeVal)
            }
            
            // Load date range
            if let dateRange = collectorSettings.date_range {
                useDateRange = true
                useTimeWindow = false
                
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                if let sinceStr = dateRange.since {
                    sinceDate = formatter.date(from: sinceStr)
                } else {
                    sinceDate = nil
                }
                
                if let untilStr = dateRange.until {
                    untilDate = formatter.date(from: untilStr)
                } else {
                    untilDate = nil
                }
            } else if let timeWindowVal = collectorSettings.time_window, !timeWindowVal.isEmpty {
                useTimeWindow = true
                useDateRange = false
                timeWindow = timeWindowVal
            }
            
            if let waitForCompletionVal = collectorSettings.wait_for_completion {
                waitForCompletion = waitForCompletionVal
            }
            if let timeoutMsVal = collectorSettings.timeout_ms {
                timeoutMs = String(timeoutMsVal)
            }
            
            // Load scope - convert from [String: String] back to [String: AnyCodable]
            if let scopeVal = collectorSettings.scope {
                var loadedScope: [String: AnyCodable] = [:]
                for (key, valueStr) in scopeVal {
                    if valueStr.lowercased() == "true" {
                        loadedScope[key] = .bool(true)
                    } else if valueStr.lowercased() == "false" {
                        loadedScope[key] = .bool(false)
                    } else if let intVal = Int(valueStr) {
                        loadedScope[key] = .int(intVal)
                    } else if let doubleVal = Double(valueStr) {
                        loadedScope[key] = .double(doubleVal)
                    } else {
                        loadedScope[key] = .string(valueStr)
                    }
                }
                scopeData = loadedScope
            }
        } catch {
            // Failed to load settings, continue with defaults
        }
    }
    
    // MARK: - Save Settings
    
    func saveSettings() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".haven/haven_ui_collectors.yaml")
            .path
        
        // Ensure directory exists
        let configDir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        
        struct CollectorSettingsFile: Codable {
            var collectors: [String: CollectorSettings]?
            
            struct CollectorSettings: Codable {
                var mode: String?
                var order: String?
                var limit: Int?
                var concurrency: Int?
                var batch: Bool?
                var batch_size: Int?
                var date_range: DateRange?
                var time_window: String?
                var wait_for_completion: Bool?
                var timeout_ms: Int?
                var scope: [String: String]?
                
                struct DateRange: Codable {
                    var since: String?
                    var until: String?
                }
            }
        }
        
        // Load existing settings
        var settingsFile = CollectorSettingsFile(collectors: [:])
        
        if FileManager.default.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                let decoder = YAMLDecoder()
                settingsFile = try decoder.decode(CollectorSettingsFile.self, from: data)
            } catch {
                // Failed to load existing settings, will create new file
            }
        }
        
        // Build collector settings
        var collectorSettings = CollectorSettingsFile.CollectorSettings(
            mode: mode.rawValue,
            order: order.rawValue,
            limit: Int(limit).flatMap { $0 > 0 ? $0 : nil },
            concurrency: Int(concurrency).flatMap { $0 > 0 ? min(max($0, 1), 12) : nil },
            batch: batch ? true : nil,
            batch_size: Int(batchSize).flatMap { $0 > 0 ? $0 : nil },
            date_range: nil,
            time_window: nil,
            wait_for_completion: nil,
            timeout_ms: nil,
            scope: nil
        )
        
        // Date range
        if useDateRange {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            var dateRange = CollectorSettingsFile.CollectorSettings.DateRange(since: nil, until: nil)
            if let since = sinceDate {
                dateRange.since = formatter.string(from: since)
            }
            if let until = untilDate {
                dateRange.until = formatter.string(from: until)
            }
            if dateRange.since != nil || dateRange.until != nil {
                collectorSettings.date_range = dateRange
            }
        } else if useTimeWindow, !timeWindow.isEmpty {
            collectorSettings.time_window = timeWindow
        }
        
        if !waitForCompletion || !timeoutMs.isEmpty {
            collectorSettings.wait_for_completion = waitForCompletion
            if let timeoutInt = Int(timeoutMs), timeoutInt > 0 {
                collectorSettings.timeout_ms = timeoutInt
            }
        }
        
        // Scope - store as JSON string for now (simplified)
        if !scopeData.isEmpty {
            var scopeDict: [String: String] = [:]
            for (key, value) in scopeData {
                switch value {
                case .string(let s):
                    scopeDict[key] = s
                case .int(let i):
                    scopeDict[key] = String(i)
                case .double(let d):
                    scopeDict[key] = String(d)
                case .bool(let b):
                    scopeDict[key] = b ? "true" : "false"
                case .null:
                    break
                }
            }
            if !scopeDict.isEmpty {
                collectorSettings.scope = scopeDict
            }
        }
        
        // Update settings file
        if settingsFile.collectors == nil {
            settingsFile.collectors = [:]
        }
        settingsFile.collectors?[collector.id] = collectorSettings
        
        // Save to file
        do {
            let encoder = YAMLEncoder()
            let yamlString = try encoder.encode(settingsFile)
            try yamlString.write(toFile: configPath, atomically: true, encoding: .utf8)
        } catch {
            // Failed to save settings
        }
    }
    
    // MARK: - Build Payload
    
    func buildPayload() -> CollectorRunRequestPayload {
        var payload = CollectorRunRequestPayload()
        
        payload.mode = mode
        payload.order = order
        payload.limit = Int(limit).flatMap { $0 > 0 ? $0 : nil }
        payload.concurrency = Int(concurrency).flatMap { $0 > 0 ? min(max($0, 1), 12) : nil }
        payload.batch = batch
        payload.batchSize = Int(batchSize).flatMap { $0 > 0 ? $0 : nil }
        
        // Date range or time window
        if useDateRange {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            var sinceStr: String? = nil
            var untilStr: String? = nil
            if let since = sinceDate {
                sinceStr = formatter.string(from: since)
            }
            if let until = untilDate {
                untilStr = formatter.string(from: until)
            }
            if sinceStr != nil || untilStr != nil {
                payload.dateRange = DateRange(since: sinceStr, until: untilStr)
            }
        } else if useTimeWindow, !timeWindow.isEmpty {
            payload.timeWindow = timeWindow
        }
        
        // Filters
        if showFilters {
            var filterConfig = FilterConfig()
            if !filterCombinationMode.isEmpty {
                filterConfig.combinationMode = filterCombinationMode
            }
            if !filterDefaultAction.isEmpty {
                filterConfig.defaultAction = filterDefaultAction
            }
            if !filterInline.isEmpty {
                if let data = filterInline.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    filterConfig.inline = json
                }
            }
            if !filterFiles.isEmpty {
                filterConfig.files = filterFiles
            }
            if !filterEnvVar.isEmpty {
                filterConfig.environmentVariable = filterEnvVar
            }
            payload.filters = filterConfig
        }
        
        // Redaction override
        if showRedaction, !redactionOverrides.isEmpty {
            payload.redactionOverrides = redactionOverrides
        }
        
        // Scope (collector-specific)
        let baseCollectorId = extractBaseCollectorId(collector.id)
        var scope: [String: Any] = [:]
        
        switch baseCollectorId {
        case "imessage":
            if let includeAttachments = scopeData["include_attachments"], case .bool(let val) = includeAttachments {
                scope["include_attachments"] = val
            }
            if let useOcr = scopeData["use_ocr_on_attachments"], case .bool(let val) = useOcr {
                scope["use_ocr_on_attachments"] = val
            }
            if let extractEntities = scopeData["extract_entities"], case .bool(let val) = extractEntities {
                scope["extract_entities"] = val
            }
            // TODO: Handle include_chats and exclude_chats arrays properly
            break
            
        case "email_imap":
            // Build IMAP scope
            var imapScope: [String: Any] = [:]
            
            // Account ID (required)
            if let accountId = collector.imapAccountId {
                imapScope["account_id"] = accountId
            }
            
            // Folders (can be single folder string or array)
            if let foldersVal = scopeData["folders"], case .string(let foldersStr) = foldersVal {
                // If comma-separated, split into array
                let folders = foldersStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                if folders.count == 1 {
                    imapScope["folder"] = folders[0]
                } else if folders.count > 1 {
                    imapScope["folders"] = folders
                }
            }
            
            // Other IMAP scope fields
            if let resetVal = scopeData["reset"], case .bool(let val) = resetVal {
                imapScope["reset"] = val
            }
            if let maxLimitVal = scopeData["max_limit"], case .int(let val) = maxLimitVal {
                imapScope["max_limit"] = val
            }
            
            // Credentials (if provided in scope)
            if let secretRefVal = scopeData["secret_ref"], case .string(let val) = secretRefVal {
                var credentials: [String: Any] = [:]
                credentials["secret_ref"] = val
                if let kindVal = scopeData["auth_kind"], case .string(let kind) = kindVal {
                    credentials["kind"] = kind
                } else {
                    credentials["kind"] = "app_password"
                }
                imapScope["credentials"] = credentials
            }
            
            if !imapScope.isEmpty {
                scope["imap"] = imapScope
            }
            break
            
        case "localfs":
            // TODO: Build LocalFS scope with paths and globs
            break
            
        case "contacts":
            // TODO: Build Contacts scope
            break
            
        default:
            break
        }
        
        if !scope.isEmpty {
            payload.scope = scope
        }
        
        // Response settings
        payload.waitForCompletion = waitForCompletion
        payload.timeoutMs = Int(timeoutMs).flatMap { $0 > 0 ? $0 : nil }
        
        return payload
    }
    
    func updatePreview() {
        do {
            let payload = buildPayload()
            previewJSON = try payload.toJSONString()
        } catch {
            previewJSON = "{}"
        }
    }
    
    // MARK: - Run Collector
    
    func runCollector() async throws -> RunResponse {
        let payload = buildPayload()
        return try await collectorService.runCollectorWithPayload(collector, payload: payload)
    }
    
    // MARK: - Helper Methods
    
    private func extractBaseCollectorId(_ collectorId: String) -> String {
        if let colonIndex = collectorId.firstIndex(of: ":") {
            return String(collectorId[..<colonIndex])
        }
        return collectorId
    }
}

// MARK: - CollectorTab Enum

enum CollectorTab {
    case run
    case scope
    case preview
}

