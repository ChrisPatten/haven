//
//  CollectorRunRequestBuilderViewModel.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import Combine
import HostAgentEmail

/// View model for managing collector run request configuration state
@MainActor
class CollectorRunRequestBuilderViewModel: ObservableObject {
    let collector: CollectorInfo
    let hostAgentController: HostAgentController
    
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
        
        // Set collector-specific defaults
        if collector.id == "imessage" || collector.id == "email_imap" {
            batch = true
            batchSize = "200"
            order = .desc
        }
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
            // No persisted settings - use collector-specific defaults (already set in init)
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
    
    func buildPayload() -> HostAgentEmail.CollectorRunRequest {
        // Convert to HostAgentEmail.CollectorRunRequest using initializer
        
        // Mode
        let modeEnum: HostAgentEmail.CollectorRunRequest.Mode? = HostAgentEmail.CollectorRunRequest.Mode(rawValue: mode.rawValue)
        
        // Order
        let orderEnum: HostAgentEmail.CollectorRunRequest.Order? = HostAgentEmail.CollectorRunRequest.Order(rawValue: order.rawValue)
        
        // Limit and concurrency
        let limitValue = Int(limit).flatMap { $0 > 0 ? $0 : nil }
        let concurrencyValue = Int(concurrency).flatMap { $0 > 0 ? min(max($0, 1), 12) : nil }
        
        // Date range or time window
        var dateRangeValue: HostAgentEmail.CollectorRunRequest.DateRange? = nil
        var timeWindowValue: String? = nil
        if useDateRange {
            dateRangeValue = HostAgentEmail.CollectorRunRequest.DateRange(since: sinceDate, until: untilDate)
        } else if useTimeWindow, !timeWindow.isEmpty {
            timeWindowValue = timeWindow
        }
        
        // Filters
        var filterConfigValue: HostAgentEmail.CollectorRunRequest.FiltersConfig? = nil
        if showFilters {
            var inlineArray: [HostAgentEmail.AnyCodable]? = nil
            if !filterInline.isEmpty {
                // Convert inline filter string to AnyCodable array
                if let data = filterInline.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data),
                   let array = json as? [Any] {
                    inlineArray = array.map { HostAgentEmail.AnyCodable($0) }
                }
            }
            filterConfigValue = HostAgentEmail.CollectorRunRequest.FiltersConfig(
                combinationMode: filterCombinationMode,
                defaultAction: filterDefaultAction,
                inline: inlineArray,
                files: filterFiles.isEmpty ? nil : filterFiles,
                environmentVariable: filterEnvVar.isEmpty ? nil : filterEnvVar
            )
        }
        
        // Redaction override
        let redactionOverrideValue: HostAgentEmail.CollectorRunRequest.RedactionOverride? = showRedaction && !redactionOverrides.isEmpty ? HostAgentEmail.CollectorRunRequest.RedactionOverride(raw: redactionOverrides) : nil
        
        // Scope - convert from Haven.AnyCodable to HostAgentEmail.AnyCodable
        var scopeValue: HostAgentEmail.AnyCodable? = nil
        if !scopeData.isEmpty {
            var scopeDict: [String: HostAgentEmail.AnyCodable] = [:]
            for (key, value) in scopeData {
                switch value {
                case .string(let s):
                    scopeDict[key] = HostAgentEmail.AnyCodable(s)
                case .int(let i):
                    scopeDict[key] = HostAgentEmail.AnyCodable(i)
                case .double(let d):
                    scopeDict[key] = HostAgentEmail.AnyCodable(d)
                case .bool(let b):
                    scopeDict[key] = HostAgentEmail.AnyCodable(b)
                case .null:
                    scopeDict[key] = HostAgentEmail.AnyCodable(NSNull())
                }
            }
            scopeValue = HostAgentEmail.AnyCodable(scopeDict)
        }
        
        // Build request using initializer
        return HostAgentEmail.CollectorRunRequest(
            mode: modeEnum,
            limit: limitValue,
            order: orderEnum,
            concurrency: concurrencyValue,
            dateRange: dateRangeValue,
            timeWindow: timeWindowValue,
            batch: batch ? batch : nil,
            batchSize: Int(batchSize).flatMap { $0 > 0 ? $0 : nil },
            redactionOverride: redactionOverrideValue,
            filters: filterConfigValue,
            scope: scopeValue
        )
    }
    
    func updatePreview() {
        let request = buildPayload()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(request),
           let jsonString = String(data: data, encoding: .utf8) {
            previewJSON = jsonString
        } else {
            previewJSON = "{}"
        }
    }
    
    // MARK: - Run Collector
    
    func runCollector() async throws -> HostAgentEmail.RunResponse {
        let request = buildPayload()
        return try await hostAgentController.runCollector(id: collector.id, request: request)
    }
}

