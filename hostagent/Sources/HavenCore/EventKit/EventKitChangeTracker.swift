import Foundation
import EventKit

/// Tracks EventKit store changes and manages incremental sync state
public actor EventKitChangeTracker {
    private let logger = HavenLogger(category: "eventkit-change-tracker")
    
    public init() {}
    private var notificationObserver: NSObjectProtocol?
    private var lastSyncState: [String: Date] = [:] // calendarItemIdentifier -> lastModifiedDate
    private var lastSyncTimestamp: Date?
    
    /// Subscribe to EKEventStoreChangedNotification
    /// When the store changes, EventKit treats previously fetched objects as stale
    public func startObserving(store: EKEventStore, onChange: @escaping () -> Void) {
        // Remove existing observer if any
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        logger.info("Starting EventKit change observation")
        
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onChange()
            }
            // Log from within the actor
            Task { [weak self] in
                await self?.logStoreChange()
            }
        }
    }
    
    /// Stop observing changes
    public func stopObserving() {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
            Task {
                await logStopObserving()
            }
        }
    }
    
    private func logStoreChange() {
        logger.info("EventKit store changed notification received")
    }
    
    private func logStopObserving() {
        logger.info("Stopped EventKit change observation")
    }
    
    /// Load sync state from disk
    public func loadSyncState() {
        let stateFile = HavenFilePaths.stateFile("reminders_sync_state.json")
        
        guard FileManager.default.fileExists(atPath: stateFile.path),
              let data = try? Data(contentsOf: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.debug("No existing sync state found, starting fresh")
            return
        }
        
        // Load last sync timestamp
        if let lastSyncStr = json["last_sync_timestamp"] as? String,
           let lastSync = ISO8601DateFormatter().date(from: lastSyncStr) {
            lastSyncTimestamp = lastSync
        }
        
        // Load per-item modification dates
        if let items = json["items"] as? [String: String] {
            var state: [String: Date] = [:]
            let formatter = ISO8601DateFormatter()
            for (identifier, dateStr) in items {
                if let date = formatter.date(from: dateStr) {
                    state[identifier] = date
                }
            }
            lastSyncState = state
            logger.debug("Loaded sync state", metadata: [
                "item_count": String(state.count),
                "last_sync": lastSyncTimestamp?.description ?? "never"
            ])
        }
    }
    
    /// Save sync state to disk
    public func saveSyncState() {
        let stateFile = HavenFilePaths.stateFile("reminders_sync_state.json")
        
        var json: [String: Any] = [:]
        
        // Save last sync timestamp
        if let lastSync = lastSyncTimestamp {
            json["last_sync_timestamp"] = ISO8601DateFormatter().string(from: lastSync)
        }
        
        // Save per-item modification dates
        let formatter = ISO8601DateFormatter()
        var items: [String: String] = [:]
        for (identifier, date) in lastSyncState {
            items[identifier] = formatter.string(from: date)
        }
        json["items"] = items
        
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try data.write(to: stateFile)
            logger.debug("Saved sync state", metadata: [
                "item_count": String(lastSyncState.count),
                "path": stateFile.path
            ])
        } catch {
            logger.error("Failed to save sync state", metadata: ["error": error.localizedDescription])
        }
    }
    
    /// Update sync state with a reminder's modification date
    public func updateItem(identifier: String, lastModified: Date) {
        lastSyncState[identifier] = lastModified
    }
    
    /// Get last modified date for an item
    public func getLastModified(identifier: String) -> Date? {
        return lastSyncState[identifier]
    }
    
    /// Check if an item has been modified since last sync
    public func isItemModified(identifier: String, lastModified: Date) -> Bool {
        guard let cachedModified = lastSyncState[identifier] else {
            return true // New item
        }
        return lastModified > cachedModified
    }
    
    /// Update last sync timestamp
    public func updateLastSyncTimestamp(_ date: Date) {
        lastSyncTimestamp = date
    }
    
    /// Get last sync timestamp
    public func getLastSyncTimestamp() -> Date? {
        return lastSyncTimestamp
    }
    
    /// Clear sync state (for full resync)
    public func clearSyncState() {
        lastSyncState.removeAll()
        lastSyncTimestamp = nil
        logger.info("Cleared sync state")
    }
    
    /// Get all tracked identifiers
    public func getTrackedIdentifiers() -> Set<String> {
        return Set(lastSyncState.keys)
    }
}

