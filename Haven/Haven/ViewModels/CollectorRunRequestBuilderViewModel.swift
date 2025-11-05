//
//  CollectorRunRequestBuilderViewModel.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import Combine

/// View model for managing collector run request configuration state
@MainActor
class CollectorRunRequestBuilderViewModel: ObservableObject {
    let collector: CollectorInfo
    private let hostAgentController: HostAgentController
    
    // Run settings
    @Published var mode: RunMode = .real
    @Published var order: RunOrder = .desc
    @Published var limit: String = "1000"
    @Published var concurrency: String = "4"
    @Published var batch: Bool = false
    @Published var batchSize: String = "100"
    
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
    
    init(collector: CollectorInfo, hostAgentController: HostAgentController) {
        self.collector = collector
        self.hostAgentController = hostAgentController
    }
    
    // MARK: - Load Settings
    
    func loadModules() async {
        // TODO: Load modules from HostAgent API
        // For now, placeholder
        modulesResponse = ModulesResponse(
            ocr: ModulesResponse.ModuleConfig(enabled: true),
            entity: ModulesResponse.ModuleConfig(enabled: true)
        )
    }
    
    func loadPersistedSettings() {
        let key = "collector_run_settings_\(collector.id)"
        
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        // Load basic settings
        if let modeStr = dict["mode"] as? String, let modeVal = RunMode(rawValue: modeStr) {
            mode = modeVal
        }
        if let orderStr = dict["order"] as? String, let orderVal = RunOrder(rawValue: orderStr) {
            order = orderVal
        }
        if let limitVal = dict["limit"] as? Int {
            limit = String(limitVal)
        }
        if let concurrencyVal = dict["concurrency"] as? Int {
            concurrency = String(concurrencyVal)
        }
        if let batchVal = dict["batch"] as? Bool {
            batch = batchVal
        }
        if let batchSizeVal = dict["batch_size"] as? Int {
            batchSize = String(batchSizeVal)
        }
        
        // Load date range
        if let dateRange = dict["date_range"] as? [String: String] {
            useDateRange = true
            useTimeWindow = false
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            if let sinceStr = dateRange["since"] {
                sinceDate = formatter.date(from: sinceStr)
            }
            if let untilStr = dateRange["until"] {
                untilDate = formatter.date(from: untilStr)
            }
        } else if let timeWindowVal = dict["time_window"] as? String, !timeWindowVal.isEmpty {
            useTimeWindow = true
            useDateRange = false
            timeWindow = timeWindowVal
        }
        
        // Load scope
        if let scope = dict["scope"] as? [String: Any] {
            for (key, value) in scope {
                if let boolVal = value as? Bool {
                    scopeData[key] = .bool(boolVal)
                } else if let intVal = value as? Int {
                    scopeData[key] = .int(intVal)
                } else if let doubleVal = value as? Double {
                    scopeData[key] = .double(doubleVal)
                } else if let strVal = value as? String {
                    scopeData[key] = .string(strVal)
                }
            }
        }
    }
    
    // MARK: - Save Settings
    
    func saveSettings() {
        let key = "collector_run_settings_\(collector.id)"
        
        var dict: [String: Any] = [:]
        dict["mode"] = mode.rawValue
        dict["order"] = order.rawValue
        dict["limit"] = Int(limit) ?? 1000
        dict["concurrency"] = Int(concurrency) ?? 4
        dict["batch"] = batch
        dict["batch_size"] = Int(batchSize) ?? 100
        
        if useDateRange {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            var dateRange: [String: String] = [:]
            if let since = sinceDate {
                dateRange["since"] = formatter.string(from: since)
            }
            if let until = untilDate {
                dateRange["until"] = formatter.string(from: until)
            }
            if !dateRange.isEmpty {
                dict["date_range"] = dateRange
            }
        } else if useTimeWindow, !timeWindow.isEmpty {
            dict["time_window"] = timeWindow
        }
        
        // Save scope
        var scopeDict: [String: Any] = [:]
        for (key, value) in scopeData {
            switch value {
            case .string(let s):
                scopeDict[key] = s
            case .int(let i):
                scopeDict[key] = i
            case .double(let d):
                scopeDict[key] = d
            case .bool(let b):
                scopeDict[key] = b
            case .null:
                break
            }
        }
        if !scopeDict.isEmpty {
            dict["scope"] = scopeDict
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    // MARK: - Build Payload
    
    func buildPayload() -> CollectorRunRequest {
        var request = CollectorRunRequest()
        
        request.mode = mode.rawValue
        request.order = order.rawValue
        request.limit = Int(limit).flatMap { $0 > 0 ? $0 : nil }
        request.concurrency = Int(concurrency).flatMap { $0 > 0 ? min(max($0, 1), 12) : nil }
        
        // Date range or time window
        if useDateRange {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            var dateRange = CollectorRunRequest.DateRange()
            if let since = sinceDate {
                dateRange.since = formatter.string(from: since)
            }
            if let until = untilDate {
                dateRange.until = formatter.string(from: until)
            }
            if dateRange.since != nil || dateRange.until != nil {
                request.date_range = dateRange
            }
        } else if useTimeWindow, !timeWindow.isEmpty {
            request.time_window = timeWindow
        }
        
        // Filters
        if showFilters {
            var filterConfig = CollectorRunRequest.FilterConfig()
            filterConfig.combination_mode = filterCombinationMode
            filterConfig.default_action = filterDefaultAction
            if !filterInline.isEmpty {
                filterConfig.inline = filterInline
            }
            if !filterFiles.isEmpty {
                filterConfig.files = filterFiles
            }
            if !filterEnvVar.isEmpty {
                filterConfig.environment_variable = filterEnvVar
            }
            request.filters = filterConfig
        }
        
        // Redaction override
        if showRedaction, !redactionOverrides.isEmpty {
            request.redaction_override = redactionOverrides
        }
        
        // Scope
        if !scopeData.isEmpty {
            request.scope = scopeData
        }
        
        // Response settings
        request.wait_for_completion = waitForCompletion
        if let timeoutInt = Int(timeoutMs), timeoutInt > 0 {
            request.timeout_ms = timeoutInt
        }
        
        return request
    }
    
    func updatePreview() {
        let request = buildPayload()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(request),
           let jsonString = String(data: data, encoding: .utf8) {
            previewJSON = jsonString
        } else {
            previewJSON = "{}"
        }
    }
    
    // MARK: - Run Collector
    
    func runCollector() async throws -> RunResponse {
        let request = buildPayload()
        return try await hostAgentController.runCollector(id: collector.id, request: request)
    }
}

