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
        
        // Load from supported collectors
        for (_, baseInfo) in CollectorInfo.supportedCollectors {
            var info = baseInfo
            
            // Load persisted last run info
            loadPersistedLastRunInfo(for: &info)
            
            // Load state from API if available
            if CollectorInfo.hasStateEndpoint(info.id) {
                if let state = await hostAgentController.getCollectorState(id: info.id) {
                    collectorStates[info.id] = state
                    
                    // Update info from state
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
            
            // Check if collector is running from app state
            info.isRunning = appState.isCollectorRunning(info.id)
            
            loadedCollectors.append(info)
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

