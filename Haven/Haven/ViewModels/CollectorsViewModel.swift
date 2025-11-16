//
//  CollectorsViewModel.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import Combine

/// View model for managing collectors list state and polling
@MainActor
class CollectorsViewModel: ObservableObject {
    private let hostAgentController: HostAgentController
    private let appState: AppState
    
    @Published var collectors: [CollectorInfo] = []
    @Published var selectedCollectorId: String?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    @Published var collectorStates: [String: CollectorStateResponse] = [:]
    
    private var refreshTimer: Timer?
    private var isPolling: Bool = false
    
    init(hostAgentController: HostAgentController, appState: AppState) {
        self.hostAgentController = hostAgentController
        self.appState = appState
    }
    
    // MARK: - Lifecycle
    
    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        
        // Initial load
        Task {
            await loadCollectors()
        }
        
        // Poll every 5 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.loadCollectors()
            }
        }
    }
    
    func stopPolling() {
        isPolling = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // MARK: - Load Collectors
    
    func loadCollectors() async {
        isLoading = true
        defer { isLoading = false }
        
        var loadedCollectors: [CollectorInfo] = []
        
        // Check if instances are configured for collectors that require them
        let hasImapSources = await hostAgentController.hasImapSourcesConfigured()
        let hasContactsInstances = await hostAgentController.hasContactsInstancesConfigured()
        let hasFilesInstances = await hostAgentController.hasFilesInstancesConfigured()
        let hasICloudDriveInstances = await hostAgentController.hasICloudDriveInstancesConfigured()
        let isIMessageEnabled = await hostAgentController.isIMessageModuleEnabled()
        let isRemindersEnabled = await hostAgentController.isRemindersModuleEnabled()
        
        // Load instances for collectors that support them
        let imapInstances = await hostAgentController.getImapInstances()
        let contactsInstances = await hostAgentController.getContactsInstances()
        let filesInstances = await hostAgentController.getFilesInstances()
        let icloudDriveInstances = await hostAgentController.getICloudDriveInstances()
        
        // Load from supported collectors
        for (_, baseInfo) in CollectorInfo.supportedCollectors {
            // Handle iMessage (no instances)
            if baseInfo.id == "imessage" {
                var info = baseInfo
                info.enabled = isIMessageEnabled
                loadPersistedLastRunInfo(for: &info)
                
                // Load state from API if available
                if CollectorInfo.hasStateEndpoint(info.id) {
                    if let state = await hostAgentController.getCollectorState(id: info.id) {
                        collectorStates[info.id] = state
                        if let lastRunTimeStr = state.lastRunTime {
                            let formatter = ISO8601DateFormatter()
                            formatter.formatOptions = [.withInternetDateTime]
                            info.lastRunTime = formatter.date(from: lastRunTimeStr)
                        }
                        info.lastRunStatus = state.lastRunStatus
                        info.isRunning = state.isRunning ?? false
                        info.lastError = state.lastRunError
                    }
                }
                
                info.isRunning = appState.isCollectorRunning(info.id)
                loadedCollectors.append(info)
            }
            // Handle IMAP - create entry for each enabled instance
            else if baseInfo.id == "email_imap" {
                for instance in imapInstances {
                    // Create instance-specific collector ID
                    let instanceId = "email_imap:\(instance.id)"
                    // Set display name to instance name or fallback to account ID
                    let displayName = instance.displayName ?? instance.id
                    
                    var info = CollectorInfo(
                        id: instanceId,
                        displayName: displayName,
                        description: baseInfo.description,
                        category: baseInfo.category,
                        enabled: instance.enabled,
                        lastRunTime: nil,
                        lastRunStatus: nil,
                        isRunning: false,
                        lastError: nil,
                        payload: baseInfo.payload,
                        imapAccountId: instance.id
                    )
                    
                    loadPersistedLastRunInfo(for: &info)
                    
                    // Load state from API if available (use base collector ID for state)
                    if CollectorInfo.hasStateEndpoint(baseInfo.id) {
                        if let state = await hostAgentController.getCollectorState(id: baseInfo.id) {
                            collectorStates[info.id] = state
                            if let lastRunTimeStr = state.lastRunTime {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime]
                                info.lastRunTime = formatter.date(from: lastRunTimeStr)
                            }
                            info.lastRunStatus = state.lastRunStatus
                            info.isRunning = state.isRunning ?? false
                            info.lastError = state.lastRunError
                        }
                    }
                    
                    info.isRunning = appState.isCollectorRunning(info.id)
                    loadedCollectors.append(info)
                }
            }
            // Handle Contacts - create entry for each enabled instance
            else if baseInfo.id == "contacts" {
                for instance in contactsInstances {
                    // Create instance-specific collector ID
                    let instanceId = "contacts:\(instance.id)"
                    // Set display name to instance name
                    let displayName = instance.name.isEmpty ? "Contacts (\(instance.id))" : instance.name
                    
                    var info = CollectorInfo(
                        id: instanceId,
                        displayName: displayName,
                        description: baseInfo.description,
                        category: baseInfo.category,
                        enabled: instance.enabled,
                        lastRunTime: nil,
                        lastRunStatus: nil,
                        isRunning: false,
                        lastError: nil,
                        payload: baseInfo.payload,
                        imapAccountId: nil
                    )
                    
                    loadPersistedLastRunInfo(for: &info)
                    
                    // Load state from API if available (use base collector ID for state)
                    if CollectorInfo.hasStateEndpoint(baseInfo.id) {
                        if let state = await hostAgentController.getCollectorState(id: baseInfo.id) {
                            collectorStates[info.id] = state
                            if let lastRunTimeStr = state.lastRunTime {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime]
                                info.lastRunTime = formatter.date(from: lastRunTimeStr)
                            }
                            info.lastRunStatus = state.lastRunStatus
                            info.isRunning = state.isRunning ?? false
                            info.lastError = state.lastRunError
                        }
                    }
                    
                    info.isRunning = appState.isCollectorRunning(info.id)
                    loadedCollectors.append(info)
                }
            }
            // Handle Files - create entry for each enabled instance
            else if baseInfo.id == "localfs" {
                for instance in filesInstances {
                    // Create instance-specific collector ID
                    let instanceId = "localfs:\(instance.id)"
                    // Set display name to instance name
                    let displayName = instance.name.isEmpty ? "Local Files (\(instance.id))" : instance.name
                    
                    var info = CollectorInfo(
                        id: instanceId,
                        displayName: displayName,
                        description: baseInfo.description,
                        category: baseInfo.category,
                        enabled: instance.enabled,
                        lastRunTime: nil,
                        lastRunStatus: nil,
                        isRunning: false,
                        lastError: nil,
                        payload: baseInfo.payload,
                        imapAccountId: nil
                    )
                    
                    loadPersistedLastRunInfo(for: &info)
                    
                    // Load state from API if available (use base collector ID for state)
                    if CollectorInfo.hasStateEndpoint(baseInfo.id) {
                        if let state = await hostAgentController.getCollectorState(id: baseInfo.id) {
                            collectorStates[info.id] = state
                            if let lastRunTimeStr = state.lastRunTime {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime]
                                info.lastRunTime = formatter.date(from: lastRunTimeStr)
                            }
                            info.lastRunStatus = state.lastRunStatus
                            info.isRunning = state.isRunning ?? false
                            info.lastError = state.lastRunError
                        }
                    }
                    
                    info.isRunning = appState.isCollectorRunning(info.id)
                    loadedCollectors.append(info)
                }
            }
            // Handle iCloud Drive - create entry for each enabled instance
            else if baseInfo.id == "icloud_drive" {
                for instance in icloudDriveInstances {
                    // Create instance-specific collector ID
                    let instanceId = "icloud_drive:\(instance.id)"
                    // Set display name to instance name
                    let displayName = instance.name.isEmpty ? "iCloud Drive (\(instance.id))" : instance.name
                    
                    var info = CollectorInfo(
                        id: instanceId,
                        displayName: displayName,
                        description: baseInfo.description,
                        category: baseInfo.category,
                        enabled: instance.enabled,
                        lastRunTime: nil,
                        lastRunStatus: nil,
                        isRunning: false,
                        lastError: nil,
                        payload: baseInfo.payload,
                        imapAccountId: nil
                    )
                    
                    loadPersistedLastRunInfo(for: &info)
                    
                    // Load state from API if available (use base collector ID for state)
                    if CollectorInfo.hasStateEndpoint(baseInfo.id) {
                        if let state = await hostAgentController.getCollectorState(id: baseInfo.id) {
                            collectorStates[info.id] = state
                            if let lastRunTimeStr = state.lastRunTime {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime]
                                info.lastRunTime = formatter.date(from: lastRunTimeStr)
                            }
                            info.lastRunStatus = state.lastRunStatus
                            info.isRunning = state.isRunning ?? false
                            info.lastError = state.lastRunError
                        }
                    }
                    
                    info.isRunning = appState.isCollectorRunning(info.id)
                    loadedCollectors.append(info)
                }
            }
            // Handle Reminders (no instances, single collector like iMessage)
            else if baseInfo.id == "reminders" {
                var info = baseInfo
                info.enabled = isRemindersEnabled
                loadPersistedLastRunInfo(for: &info)
                
                // Load state from API if available
                if CollectorInfo.hasStateEndpoint(info.id) {
                    if let state = await hostAgentController.getCollectorState(id: info.id) {
                        collectorStates[info.id] = state
                        if let lastRunTimeStr = state.lastRunTime {
                            let formatter = ISO8601DateFormatter()
                            formatter.formatOptions = [.withInternetDateTime]
                            info.lastRunTime = formatter.date(from: lastRunTimeStr)
                        }
                        info.lastRunStatus = state.lastRunStatus
                        info.isRunning = state.isRunning ?? false
                        info.lastError = state.lastRunError
                    }
                }
                
                info.isRunning = appState.isCollectorRunning(info.id)
                loadedCollectors.append(info)
            }
        }
        
        collectors = loadedCollectors.sorted { $0.displayName < $1.displayName }
        appState.updateCollectorsList(collectors)
        errorMessage = nil
    }
    
    func refreshCollectors() {
        Task {
            await loadCollectors()
        }
    }
    
    // MARK: - Selection
    
    func selectCollector(_ collectorId: String?) {
        selectedCollectorId = collectorId
    }
    
    func getSelectedCollector() -> CollectorInfo? {
        guard let id = selectedCollectorId else { return nil }
        return collectors.first { $0.id == id }
    }
    
    // MARK: - Helper Methods
    
    private func loadPersistedLastRunInfo(for collector: inout CollectorInfo) {
        let key = "collector_last_run_\(collector.id)"
        
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        if let lastRunTimeStr = dict["lastRunTime"] as? String {
            let formatter = ISO8601DateFormatter()
            collector.lastRunTime = formatter.date(from: lastRunTimeStr)
        }
        
        if let lastRunStatus = dict["lastRunStatus"] as? String {
            collector.lastRunStatus = lastRunStatus
        }
        
        if let lastError = dict["lastError"] as? String {
            collector.lastError = lastError
        }
    }
}

