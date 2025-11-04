import Foundation
import Yams

/// Service layer for collector operations
/// Handles all business logic related to collectors, separating it from views
@MainActor
class CollectorService: ObservableObject {
    private let client: HostAgentClient
    private let appState: AppState
    
    init(client: HostAgentClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }
    
    // MARK: - Module Info
    
    /// Get available modules
    func getModules() async throws -> ModulesResponse {
        return try await client.getModules()
    }
    
    // MARK: - Run Collector
    
    /// Run a collector with default settings (or persisted settings if available)
    func runCollector(_ collector: CollectorInfo) async throws -> RunResponse {
        let baseCollectorId = extractBaseCollectorId(collector.id)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔷 CollectorService: Running collector '\(collector.displayName)'")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📌 Collector ID: \(collector.id)")
        print("📌 Base Collector ID: \(baseCollectorId)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        appState.setCollectorRunning(collector.id, running: true)
        defer { appState.setCollectorRunning(collector.id, running: false) }
        
        // Try to load persisted settings and build a payload
        let payload = loadPersistedSettingsAndBuildPayload(for: collector)
        let jsonPayload = try payload.toJSONString()
        
        let response = try await client.runCollectorWithPayload(baseCollectorId, jsonPayload: jsonPayload)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ CollectorService: Collector run completed successfully")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📊 Run ID: \(response.runId)")
        print("📊 Status: \(response.status)")
        print("📊 Stats:")
        print("   Scanned: \(response.stats.scanned)")
        print("   Matched: \(response.stats.matched)")
        print("   Submitted: \(response.stats.submitted)")
        print("   Skipped: \(response.stats.skipped)")
        print("   Batches: \(response.stats.batches)")
        if !response.errors.isEmpty {
            print("⚠️  Errors: \(response.errors.count)")
            for (index, error) in response.errors.enumerated() {
                print("   \(index + 1). \(error)")
            }
        }
        if !response.warnings.isEmpty {
            print("⚠️  Warnings: \(response.warnings.count)")
            for (index, warning) in response.warnings.enumerated() {
                print("   \(index + 1). \(warning)")
            }
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
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
        
        // Refresh collector state and persist
        if CollectorInfo.hasStateEndpoint(collector.id) {
            try await Task.sleep(nanoseconds: 500_000_000) // Wait 0.5s for state to update
            let baseCollectorId = extractBaseCollectorId(collector.id)
            if let state = try? await client.getCollectorState(baseCollectorId) {
                appState.updateCollectorState(collector.id, with: state)
            }
        } else {
            // For collectors without state endpoints (like IMAP), persist run info directly
            persistCollectorRunInfo(collectorId: collector.id, response: response)
        }
        
        return response
    }
    
    /// Run a collector with a custom JSON payload (using payload model)
    func runCollectorWithPayload(_ collector: CollectorInfo, payload: CollectorRunRequestPayload) async throws -> RunResponse {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔷 CollectorService: Building payload for collector '\(collector.displayName)' (id: \(collector.id))")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        let jsonPayload = try payload.toJSONString()
        return try await runCollectorWithJSONPayload(collector, jsonPayload: jsonPayload)
    }
    
    /// Run a collector with a JSON string payload (for backwards compatibility)
    func runCollectorWithJSONPayload(_ collector: CollectorInfo, jsonPayload: String) async throws -> RunResponse {
        let baseCollectorId = extractBaseCollectorId(collector.id)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔷 CollectorService: Running collector '\(collector.displayName)'")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📌 Collector ID: \(collector.id)")
        print("📌 Base Collector ID: \(baseCollectorId)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        appState.setCollectorRunning(collector.id, running: true)
        defer { appState.setCollectorRunning(collector.id, running: false) }
        
        let response = try await client.runCollectorWithPayload(baseCollectorId, jsonPayload: jsonPayload)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ CollectorService: Collector run completed successfully")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📊 Run ID: \(response.runId)")
        print("📊 Status: \(response.status)")
        print("📊 Stats:")
        print("   Scanned: \(response.stats.scanned)")
        print("   Matched: \(response.stats.matched)")
        print("   Submitted: \(response.stats.submitted)")
        print("   Skipped: \(response.stats.skipped)")
        print("   Batches: \(response.stats.batches)")
        if !response.errors.isEmpty {
            print("⚠️  Errors: \(response.errors.count)")
            for (index, error) in response.errors.enumerated() {
                print("   \(index + 1). \(error)")
            }
        }
        if !response.warnings.isEmpty {
            print("⚠️  Warnings: \(response.warnings.count)")
            for (index, warning) in response.warnings.enumerated() {
                print("   \(index + 1). \(warning)")
            }
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
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
        
        // Refresh collector state and persist
        if CollectorInfo.hasStateEndpoint(collector.id) {
            try await Task.sleep(nanoseconds: 500_000_000) // Wait 0.5s for state to update
            let baseCollectorId = extractBaseCollectorId(collector.id)
            if let state = try? await client.getCollectorState(baseCollectorId) {
                appState.updateCollectorState(collector.id, with: state)
            }
        } else {
            // For collectors without state endpoints (like IMAP), persist run info directly
            persistCollectorRunInfo(collectorId: collector.id, response: response)
        }
        
        return response
    }
    
    // MARK: - Helper Methods
    
    private func extractBaseCollectorId(_ collectorId: String) -> String {
        if let colonIndex = collectorId.firstIndex(of: ":") {
            return String(collectorId[..<colonIndex])
        }
        return collectorId
    }
    
    // Persist collector run information for collectors without state endpoints
    private func persistCollectorRunInfo(collectorId: String, response: RunResponse) {
        let key = "collector_last_run_\(collectorId)"
        
        var dict: [String: Any] = [:]
        
        // Save current time as last run time
        let formatter = ISO8601DateFormatter()
        dict["lastRunTime"] = formatter.string(from: Date())
        dict["lastRunStatus"] = response.status
        
        if !response.errors.isEmpty {
            dict["lastError"] = response.errors.joined(separator: "; ")
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    /// Load persisted settings from YAML file and build a payload
    private func loadPersistedSettingsAndBuildPayload(for collector: CollectorInfo) -> CollectorRunRequestPayload {
        var payload = CollectorRunRequestPayload()
        
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".haven/haven_ui_collectors.yaml")
            .path
        
        guard FileManager.default.fileExists(atPath: configPath) else {
            // No persisted settings, return default payload with at least order set
            payload.order = .desc
            // For IMAP account-specific collectors, ensure account_id is in scope
            if let accountId = collector.imapAccountId {
                payload.scope = ["imap": ["account_id": accountId]]
            }
            return payload
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
                // No settings for this collector, return default
                payload.order = .desc
                // For IMAP account-specific collectors, ensure account_id is in scope
                if let accountId = collector.imapAccountId {
                    payload.scope = ["imap": ["account_id": accountId]]
                }
                return payload
            }
            
            // Load settings into payload
            if let modeStr = collectorSettings.mode, let modeVal = RunMode(rawValue: modeStr) {
                payload.mode = modeVal
            }
            if let orderStr = collectorSettings.order, let orderVal = RunOrder(rawValue: orderStr) {
                payload.order = orderVal
            } else {
                payload.order = .desc // Default
            }
            
            if let limitVal = collectorSettings.limit, limitVal > 0 {
                payload.limit = limitVal
            }
            if let concurrencyVal = collectorSettings.concurrency, concurrencyVal > 0 {
                payload.concurrency = min(max(concurrencyVal, 1), 12)
            }
            
            if let batchVal = collectorSettings.batch {
                payload.batch = batchVal
            }
            if let batchSizeVal = collectorSettings.batch_size, batchSizeVal > 0 {
                payload.batchSize = batchSizeVal
            }
            
            // Date range or time window
            if let dateRange = collectorSettings.date_range {
                payload.dateRange = DateRange(since: dateRange.since, until: dateRange.until)
            } else if let timeWindowVal = collectorSettings.time_window, !timeWindowVal.isEmpty {
                payload.timeWindow = timeWindowVal
            }
            
            if let waitForCompletionVal = collectorSettings.wait_for_completion {
                payload.waitForCompletion = waitForCompletionVal
            }
            if let timeoutMsVal = collectorSettings.timeout_ms, timeoutMsVal > 0 {
                payload.timeoutMs = timeoutMsVal
            }
            
            // Load scope - convert from [String: String] to [String: Any]
            var scope: [String: Any] = [:]
            if let scopeVal = collectorSettings.scope {
                for (key, valueStr) in scopeVal {
                    if valueStr.lowercased() == "true" {
                        scope[key] = true
                    } else if valueStr.lowercased() == "false" {
                        scope[key] = false
                    } else if let intVal = Int(valueStr) {
                        scope[key] = intVal
                    } else if let doubleVal = Double(valueStr) {
                        scope[key] = doubleVal
                    } else {
                        scope[key] = valueStr
                    }
                }
            }
            
            // For IMAP account-specific collectors, ensure account_id is in scope
            if let accountId = collector.imapAccountId {
                var imapScope = scope["imap"] as? [String: Any] ?? [:]
                imapScope["account_id"] = accountId
                scope["imap"] = imapScope
            }
            
            if !scope.isEmpty {
                payload.scope = scope
            }
            
        } catch {
            // If loading fails, return default payload
            print("Failed to load persisted settings: \(error)")
            payload.order = .desc
            // For IMAP account-specific collectors, ensure account_id is in scope
            if let accountId = collector.imapAccountId {
                payload.scope = ["imap": ["account_id": accountId]]
            }
        }
        
        return payload
    }
}

// MARK: - Collector Run Request Payload Model

/// Model representing a collector run request payload
/// This separates payload construction from the view layer
struct CollectorRunRequestPayload {
    // Run settings
    var mode: RunMode = .real
    var order: RunOrder = .desc
    var limit: Int?
    var concurrency: Int?
    
    // Batch settings
    var batch: Bool = false
    var batchSize: Int?
    
    // Time filtering
    var dateRange: DateRange? // Uses DateRange from Models.swift
    var timeWindow: String?
    
    // Filters
    var filters: FilterConfig?
    
    // Redaction override
    var redactionOverrides: [String: Bool]?
    
    // Scope (collector-specific)
    var scope: [String: Any]?
    
    // Response settings
    var waitForCompletion: Bool = true
    var timeoutMs: Int?
    
    // MARK: - JSON Conversion
    
    func toJSONString() throws -> String {
        var dict: [String: Any] = [:]
        
        // Top-level fields
        dict["mode"] = mode.rawValue
        dict["order"] = order.rawValue
        
        if let limit = limit, limit > 0 {
            dict["limit"] = limit
        }
        
        if let concurrency = concurrency, concurrency > 0 {
            dict["concurrency"] = min(max(concurrency, 1), 12) // Clamp 1-12
        }
        
        if batch {
            dict["batch"] = true
            if let batchSize = batchSize, batchSize > 0 {
                dict["batch_size"] = batchSize
            }
        }
        
        // Date range or time window (mutually exclusive)
        if let dateRange = dateRange {
            var dateRangeDict: [String: Any] = [:]
            if let since = dateRange.since {
                dateRangeDict["since"] = since
            }
            if let until = dateRange.until {
                dateRangeDict["until"] = until
            }
            if !dateRangeDict.isEmpty {
                dict["date_range"] = dateRangeDict
            }
        } else if let timeWindow = timeWindow, !timeWindow.isEmpty {
            dict["time_window"] = timeWindow
        }
        
        // Filters
        if let filters = filters {
            var filterDict: [String: Any] = [:]
            if let combinationMode = filters.combinationMode {
                filterDict["combination_mode"] = combinationMode
            }
            if let defaultAction = filters.defaultAction {
                filterDict["default_action"] = defaultAction
            }
            if let inline = filters.inline {
                filterDict["inline"] = inline
            }
            if let files = filters.files, !files.isEmpty {
                filterDict["files"] = files
            }
            if let envVar = filters.environmentVariable {
                filterDict["environment_variable"] = envVar
            }
            if !filterDict.isEmpty {
                dict["filters"] = filterDict
            }
        }
        
        // Redaction override
        if let redactionOverrides = redactionOverrides, !redactionOverrides.isEmpty {
            dict["redaction_override"] = redactionOverrides
        }
        
        // Scope
        if let scope = scope, !scope.isEmpty {
            dict["scope"] = scope
        }
        
        // Response (for async runs)
        if !waitForCompletion || timeoutMs != nil {
            var response: [String: Any] = [:]
            response["wait_for_completion"] = waitForCompletion
            if let timeoutMs = timeoutMs, timeoutMs > 0 {
                response["timeout_ms"] = timeoutMs
            }
            dict["response"] = response
        }
        
        // Convert to JSON
        let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CollectorServiceError.jsonEncodingFailed
        }
        
        return jsonString
    }
}

// MARK: - Supporting Types

struct FilterConfig {
    var combinationMode: String?
    var defaultAction: String?
    var inline: Any? // JSON object
    var files: [String]?
    var environmentVariable: String?
}

enum RunMode: String {
    case simulate = "simulate"
    case real = "real"
}

enum RunOrder: String {
    case asc = "asc"
    case desc = "desc"
}

enum CollectorServiceError: Error {
    case jsonEncodingFailed
    case invalidPayload
}

extension CollectorServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .jsonEncodingFailed:
            return "Failed to encode JSON payload"
        case .invalidPayload:
            return "Invalid collector payload"
        }
    }
}

