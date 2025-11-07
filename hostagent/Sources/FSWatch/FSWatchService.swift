import Foundation
import HavenCore

/// Callback type for handling new files detected by fswatch
public typealias FileIngestionHandler = (String) async -> Void

/// File system watch service for monitoring directories and emitting change events
public actor FSWatchService {
    private let config: FSWatchModuleConfig
    private let logger = HavenLogger(category: "fswatch")
    
    // Active file system watchers
    private var watchers: [String: FileSystemWatcher] = [:]
    
    // Event queue
    private var eventQueue: [FileSystemEvent] = []
    private let maxQueueSize: Int
    
    // Optional callback for auto-ingesting files
    private var fileIngestionHandler: FileIngestionHandler?
    
    public init(config: FSWatchModuleConfig, maxQueueSize: Int = 1000) {
        self.config = config
        self.maxQueueSize = maxQueueSize
    }
    
    /// Set a callback handler for auto-ingesting detected files
    public func setFileIngestionHandler(_ handler: FileIngestionHandler?) {
        self.fileIngestionHandler = handler
    }
    
    /// Start watching configured directories
    public func start() async throws {
        // Module always enabled
        
        logger.info("Starting file system watchers", metadata: ["count": config.watches.count])
        
        for watchEntry in config.watches {
            try await addWatch(entry: watchEntry)
        }
    }
    
    /// Stop all watchers
    public func stop() async {
        logger.info("Stopping file system watchers", metadata: ["count": watchers.count])
        
        for (id, watcher) in watchers {
            watcher.stop()
            logger.debug("Stopped watcher", metadata: ["id": id])
        }
        
        watchers.removeAll()
    }
    
    /// Add a new watch
    public func addWatch(entry: FSWatchEntry) async throws {
        // Validate path exists
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
            throw FSWatchError.pathNotFound(entry.path)
        }
        
        guard isDirectory.boolValue else {
            throw FSWatchError.notADirectory(entry.path)
        }
        
        // Check if already watching
        if watchers[entry.id] != nil {
            throw FSWatchError.duplicateWatch(entry.id)
        }
        
        // Create watcher
        let watcher = try FileSystemWatcher(
            id: entry.id,
            path: entry.path,
            glob: entry.glob,
            onEvent: { [weak self] event in
                Task { await self?.enqueueEvent(event) }
            }
        )
        
        watcher.start()
        watchers[entry.id] = watcher
        
        logger.info("Added file system watch", metadata: [
            "id": entry.id,
            "path": entry.path,
            "glob": entry.glob ?? "all"
        ])
    }
    
    /// Remove a watch
    public func removeWatch(id: String) async throws {
        guard let watcher = watchers[id] else {
            throw FSWatchError.watchNotFound(id)
        }
        
        watcher.stop()
        watchers.removeValue(forKey: id)
        
        logger.info("Removed file system watch", metadata: ["id": id])
    }
    
    /// List all active watches
    public func listWatches() async -> [FSWatchEntry] {
        return Array(config.watches.filter { watchers[$0.id] != nil })
    }
    
    /// Poll events from the queue
    public func pollEvents(limit: Int = 100, since: Date? = nil) async -> [FileSystemEvent] {
        var filtered = eventQueue
        
        if let since = since {
            filtered = filtered.filter { $0.timestamp > since }
        }
        
        let result = Array(filtered.prefix(limit))
        return result
    }
    
    /// Acknowledge and remove events from the queue
    public func acknowledgeEvents(eventIds: [String]) async {
        eventQueue.removeAll { eventIds.contains($0.id) }
        logger.debug("Acknowledged events", metadata: ["count": eventIds.count])
    }
    
    /// Clear all events from the queue
    public func clearEvents() async {
        let count = eventQueue.count
        eventQueue.removeAll()
        logger.info("Cleared event queue", metadata: ["count": count])
    }
    
    /// Get queue statistics
    public func getStats() async -> FSWatchStats {
        return FSWatchStats(
            activeWatches: watchers.count,
            queuedEvents: eventQueue.count,
            maxQueueSize: maxQueueSize
        )
    }
    
    /// Health check
    public func healthCheck() async -> String {
        // Module always enabled
        return watchers.isEmpty ? "idle" : "watching"
    }
    
    // MARK: - Private
    
    private func enqueueEvent(_ event: FileSystemEvent) {
        // Check queue size
        if eventQueue.count >= maxQueueSize {
            // Remove oldest event
            eventQueue.removeFirst()
            logger.warning("Event queue full, dropping oldest event")
        }
        
        eventQueue.append(event)
        
        logger.debug("Enqueued file system event", metadata: [
            "id": event.id,
            "type": event.type.rawValue,
            "path": event.path
        ])
        
        // If a file ingestion handler is registered and this is a "created" event,
        // call it to auto-ingest the file
        if let handler = fileIngestionHandler, event.type == .created {
            logger.info("Calling ingestion handler for file", metadata: ["path": event.path])
            Task {
                await handler(event.path)
            }
        }
    }
}

// MARK: - FileSystemWatcher

/// Individual file system watcher for a directory
private class FileSystemWatcher {
    let id: String
    let path: String
    let glob: String?
    let onEvent: (FileSystemEvent) -> Void
    
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.haven.fswatch", qos: .background)
    private let fileManager = FileManager.default
    private let logger = HavenLogger(category: "fswatch.watcher")
    
    // Debouncing
    private var debounceTimer: DispatchSourceTimer?
    private var pendingEvents: [String: FileSystemEvent] = [:]
    private let debounceInterval: TimeInterval = 0.5
    private var lastSeenFiles: Set<String> = []
    
    init(id: String, path: String, glob: String?, onEvent: @escaping (FileSystemEvent) -> Void) throws {
        self.id = id
        self.path = path
        self.glob = glob
        self.onEvent = onEvent
    }
    
    func start() {
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logger.error("Failed to open path for watching", metadata: ["path": path])
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        
        source.setEventHandler { [weak self] in
            self?.handleFileSystemEvent()
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        self.source = source
        
        // Also start a periodic poll timer as a fallback to catch events more reliably
        let pollTimer = DispatchSource.makeTimerSource(queue: queue)
        pollTimer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        pollTimer.setEventHandler { [weak self] in
            self?.handleFileSystemEvent()
        }
        pollTimer.resume()
        self.pollTimer = pollTimer
        
        logger.debug("Started watching", metadata: ["path": path])
    }
    
    func stop() {
        source?.cancel()
        source = nil
        pollTimer?.cancel()
        pollTimer = nil
        debounceTimer?.cancel()
        debounceTimer = nil
    }
    
    private func handleFileSystemEvent() {
        // Scan directory for changes
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            logger.error("Failed to read directory contents", metadata: ["path": path])
            return
        }
        
        for filename in contents {
            let filePath = (path as NSString).appendingPathComponent(filename)
            
            // Check glob pattern
            if let glob = glob, !matchesGlob(filename: filename, pattern: glob) {
                continue
            }
            
            // Get file attributes
            guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date,
                  let fileSize = attrs[.size] as? UInt64 else {
                continue
            }
            
            // Check if this is a new or modified file
            let now = Date()
            if now.timeIntervalSince(modDate) < 2.0 {  // Modified in last 2 seconds
                let event = FileSystemEvent(
                    id: UUID().uuidString,
                    watchId: id,
                    type: .created,  // Simplified - treat recent mods as creates
                    path: filePath,
                    timestamp: now,
                    sizeBytes: fileSize,
                    metadata: FileSystemEventMetadata(
                        filename: filename,
                        extension: (filename as NSString).pathExtension
                    )
                )
                
                scheduleDebouncedEvent(event)
            }
        }
    }
    
    private func scheduleDebouncedEvent(_ event: FileSystemEvent) {
        // Store pending event
        pendingEvents[event.path] = event
        
        // Reset debounce timer
        debounceTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            self?.flushPendingEvents()
        }
        timer.resume()
        debounceTimer = timer
    }
    
    private func flushPendingEvents() {
        for event in pendingEvents.values {
            onEvent(event)
        }
        pendingEvents.removeAll()
    }
    
    private func matchesGlob(filename: String, pattern: String) -> Bool {
        // Simple glob matching (supports * and ?)
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
        
        guard let regex = try? NSRegularExpression(pattern: "^" + regexPattern + "$") else {
            return true
        }
        
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        return regex.firstMatch(in: filename, range: range) != nil
    }
}

// MARK: - Models

public struct FileSystemEvent: Codable, Identifiable {
    public let id: String
    public let watchId: String
    public let type: EventType
    public let path: String
    public let timestamp: Date
    public let sizeBytes: UInt64?
    public let metadata: FileSystemEventMetadata
    
    public enum EventType: String, Codable {
        case created
        case modified
        case deleted
        case renamed
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case watchId = "watch_id"
        case type
        case path
        case timestamp
        case sizeBytes = "size_bytes"
        case metadata
    }
}

public struct FileSystemEventMetadata: Codable {
    public let filename: String
    public let `extension`: String
}

public struct FSWatchStats: Codable {
    public let activeWatches: Int
    public let queuedEvents: Int
    public let maxQueueSize: Int
    
    enum CodingKeys: String, CodingKey {
        case activeWatches = "active_watches"
        case queuedEvents = "queued_events"
        case maxQueueSize = "max_queue_size"
    }
}

// MARK: - Errors

public enum FSWatchError: Error, LocalizedError {
    case pathNotFound(String)
    case notADirectory(String)
    case duplicateWatch(String)
    case watchNotFound(String)
    case permissionDenied(String)
    
    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        case .notADirectory(let path):
            return "Not a directory: \(path)"
        case .duplicateWatch(let id):
            return "Watch already exists: \(id)"
        case .watchNotFound(let id):
            return "Watch not found: \(id)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        }
    }
}
