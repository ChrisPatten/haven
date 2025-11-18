import Foundation
import HavenCore
import HostAgentEmail
import OCR
import Entity
import SQLite3
import CommonCrypto

/// Handler for iMessage collector endpoints
public actor IMessageHandler {
    private let config: HavenConfig
    private let gatewayClient: GatewayClient
    private let ocrService: OCRService?
    private let entityService: EntityService?
    private let logger = HavenLogger(category: "imessage-handler")
    
    // Enrichment support
    private let enrichmentOrchestrator: EnrichmentOrchestrator?
    private let submitter: DocumentSubmitter?
    private let skipEnrichment: Bool
    private var enrichmentQueue: EnrichmentQueue?
    
    private enum EnrichmentCompletionResult {
        case success(EnrichedDocument)
        case failure
        
        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }
    
    // Completion queue for enriched documents: documentId -> completion result
    private var enrichmentCompletions: [String: EnrichmentCompletionResult] = [:]
    
    // State tracking
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunStats: CollectorStats?
    private var lastRunError: String?
    
    private struct CollectorStats: Codable {
        var messagesProcessed: Int
        var threadsProcessed: Int
        var attachmentsProcessed: Int
        var documentsCreated: Int
        var startTime: Date
        var endTime: Date?
        var durationMs: Int?
        // Earliest/latest message timestamps touched during this run (Apple epoch units)
        var earliestMessageTimestamp: Int64?
        var latestMessageTimestamp: Int64?
        // Granular progress tracking
        var scanned: Int = 0
        var matched: Int = 0
        var submitted: Int = 0
        var skipped: Int = 0
        var errors: Int = 0
        var total: Int? = nil
        var found: Int = 0
        var queued: Int = 0
        var enriched: Int = 0
        var toDict: [String: Any] {
            var dict: [String: Any] = [
                "messages_processed": messagesProcessed,
                "threads_processed": threadsProcessed,
                "attachments_processed": attachmentsProcessed,
                "documents_created": documentsCreated,
                "start_time": ISO8601DateFormatter().string(from: startTime)
            ]
            if let endTime = endTime {
                dict["end_time"] = ISO8601DateFormatter().string(from: endTime)
            }
            if let durationMs = durationMs {
                dict["duration_ms"] = durationMs
            }
            // Include earliest/latest touched message timestamps if present
            func formatAppleEpoch(_ timestamp: Int64) -> String {
                // Heuristic to convert Apple epoch values into seconds. The
                // chat DB stores timestamps in different units across OS
                // versions and contexts (seconds, milliseconds, microseconds,
                // or nanoseconds). Use sensible thresholds to detect units and
                // convert to seconds for Date arithmetic.
                let appleEpoch = Date(timeIntervalSince1970: 978307200) // 2001-01-01
                let seconds: TimeInterval
                // Typical ranges for 2020s:
                // seconds:   ~1e9
                // millis:    ~1e12
                // micros:    ~1e15
                // nanos:     ~1e18
                if timestamp > 1_000_000_000_000_000 {
                    // Treat as nanoseconds -> divide by 1e9
                    seconds = Double(timestamp) / 1_000_000_000.0
                } else if timestamp > 1_000_000_000_000 {
                    // Treat as microseconds -> divide by 1e6
                    seconds = Double(timestamp) / 1_000_000.0
                } else if timestamp > 1_000_000_000 {
                    // Treat as milliseconds -> divide by 1e3
                    seconds = Double(timestamp) / 1_000.0
                } else {
                    // Seconds
                    seconds = Double(timestamp)
                }
                let date = appleEpoch.addingTimeInterval(seconds)
                return ISO8601DateFormatter().string(from: date)
            }

            if let earliest = earliestMessageTimestamp {
                dict["earliest_touched_message_timestamp"] = formatAppleEpoch(earliest)
            }
            if let latest = latestMessageTimestamp {
                dict["latest_touched_message_timestamp"] = formatAppleEpoch(latest)
            }
            // Include granular progress tracking
            dict["scanned"] = scanned
            dict["matched"] = matched
            dict["submitted"] = submitted
            dict["skipped"] = skipped
            dict["errors"] = errors
            if let total = total {
                dict["total"] = total
            }
            dict["found"] = found
            dict["queued"] = queued
            dict["enriched"] = enriched
            return dict
        }
    }
    
    public init(
        config: HavenConfig,
        gatewayClient: GatewayClient,
        enrichmentOrchestrator: EnrichmentOrchestrator? = nil,
        enrichmentQueue: EnrichmentQueue? = nil,
        submitter: DocumentSubmitter? = nil,
        skipEnrichment: Bool = false
    ) {
        logger.info("IMessageHandler initialized", metadata: [
            "debug_enabled": String(config.debug.enabled),
            "debug_output_path": config.debug.outputPath
        ])
        self.config = config
        self.gatewayClient = gatewayClient
        self.enrichmentOrchestrator = enrichmentOrchestrator
        self.enrichmentQueue = enrichmentQueue
        self.submitter = submitter
        self.skipEnrichment = skipEnrichment
        
        // Initialize OCR service if enabled (for backward compatibility with existing enrichment code)
        if config.modules.ocr.enabled && config.modules.imessage.ocrEnabled {
            self.ocrService = OCRService(
                timeoutMs: config.modules.ocr.timeoutMs,
                languages: config.modules.ocr.languages,
                recognitionLevel: config.modules.ocr.recognitionLevel,
                includeLayout: config.modules.ocr.includeLayout
            )
        } else {
            self.ocrService = nil
        }
        
        // Initialize entity service if enabled (for backward compatibility with existing enrichment code)
        if config.modules.entity.enabled {
            let enabledTypes = config.modules.entity.types.compactMap { typeString -> EntityType? in
                EntityType(rawValue: typeString)
            }
            self.entityService = EntityService(
                enabledTypes: enabledTypes.isEmpty ? EntityType.allCases : enabledTypes,
                minConfidence: config.modules.entity.minConfidence
            )
        } else {
            self.entityService = nil
        }
    }
    
    // MARK: - Direct Swift APIs
    
    /// Direct Swift API for running the iMessage collector
    /// Replaces HTTP-based handleRun for in-app integration
    public func runCollector(
        request: CollectorRunRequest?,
        onProgress: ((Int, Int, Int, Int, Int?, Int, Int, Int) -> Void)? = nil
    ) async throws -> RunResponse {
        
        // Check if already running
        guard !isRunning else {
            throw CollectorError.alreadyRunning("Collector is already running")
        }
        
        // Convert CollectorRunRequest to CollectorParams
        let params = convertCollectorRunRequest(request)
        
        logger.info("Starting iMessage collector", metadata: [
            "limit": params.limit?.description ?? "unlimited",
            "thread_lookback_days": String(params.threadLookbackDays),
            "message_lookback_days": String(params.messageLookbackDays),
            "batch_mode": params.batchMode ? "true" : "false",
            "batch_size": params.batchSize.map(String.init) ?? "default"
        ])
        
        // Initialize response
        let runID = UUID().uuidString
        let startTime = Date()
        var response = RunResponse(collector: "imessage", runID: runID, startedAt: startTime)
        
        // Run collection
        isRunning = true
        lastRunTime = startTime
        lastRunStatus = "running"
        lastRunError = nil
        
        // Reset submitter stats for new run
        if let submitter = submitter {
            await submitter.reset()
        }
        
        // Clear enrichment completions from previous runs
        enrichmentCompletions.removeAll()
        
        var stats = CollectorStats(
            messagesProcessed: 0,
            threadsProcessed: 0,
            attachmentsProcessed: 0,
            documentsCreated: 0,
            startTime: startTime,
            earliestMessageTimestamp: nil,
            latestMessageTimestamp: nil
        )
        
        do {
            // Create progress callback that reports stats with total and granular states
            // Signature: (scanned, matched, submitted, skipped, total, found, queued, enriched)
            let progressCallback: ((Int, Int, Int, Int, Int?, Int, Int, Int) -> Void)? = onProgress != nil ? { scanned, matched, submitted, skipped, total, found, queued, enriched in
                onProgress?(scanned, matched, submitted, skipped, total, found, queued, enriched)
            } : nil
            
            let result = try await collectMessages(params: params, stats: &stats, onProgress: progressCallback)
            
            // Documents are posted to gateway in batches during collection
            let successCount = result.submittedCount
            let finalFences = result.fences
            let pendingTimestamps = result.pendingBatchTimestamps
            let totalCount = result.totalCount
            let scannedCount = result.scannedCount
            let skippedCount = result.skippedCount
            let errorCount = result.errorCount
            
            // Final progress callback is already called at the end of collectMessages with the latest counts
            // No need to call it again here - the UI will have the latest state from that callback
            
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "completed"
            lastRunStats = stats
            
            logger.info("iMessage collection completed", metadata: [
                "documents": String(result.documents.count),
                "posted": String(successCount),
                "duration_ms": String(stats.durationMs ?? 0)
            ])
            
            // Convert stats to RunResponse
            let earliestTouched = stats.earliestMessageTimestamp.map { appleEpochToDate($0) }
            let latestTouched = stats.latestMessageTimestamp.map { appleEpochToDate($0) }
            
            response.finish(status: .ok, finishedAt: endTime)
            response.stats = RunResponse.Stats(
                scanned: scannedCount,
                matched: scannedCount,
                submitted: successCount,
                skipped: skippedCount,
                earliest_touched: earliestTouched.map { RunResponse.iso8601UTC($0) },
                latest_touched: latestTouched.map { RunResponse.iso8601UTC($0) },
                batches: 0
            )
            response.warnings = []
            // Include error messages if there were submission failures
            // For now, just include a count if errors > 0
            // TODO: Capture actual error messages during submission for more detailed reporting
            if errorCount > 0 {
                response.errors = ["\(errorCount) documents failed to submit"]
            } else {
            response.errors = []
            }
            
            // Update state and persist
            isRunning = false
            lastRunTime = endTime
            lastRunStatus = "ok"
            lastRunStats = stats
            lastRunError = nil
            await savePersistedState()
            
            return response
            
        } catch let cancellationError as CancellationError {
            // Handle cancellation gracefully
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            // Save fences on cancellation to preserve progress
            // IMPORTANT: Gap handling on cancellation
            // When processing in descending order (newest first, default):
            // - Messages in pending batch (not yet posted) are older than the latest fence
            // - These messages are NOT in any fence, so they will be processed on the next run
            // - The fence system only skips messages WITHIN fences, not messages between fences
            // - Therefore, gaps from cancelled batches are automatically handled correctly
            //
            // Example scenario:
            // - Batch 1 (T1, newest): Posted, fence saved
            // - Batch 2 (T2, newer): Posted, fence saved  
            // - Batch 3 (T3, older): In currentBatch, NOT posted, cancelled
            // - Next run: Starts from latest fence (T2), processes backwards
            // - Messages at T3 are not in any fence, so they WILL be processed
            // Skip saving fences if debug mode is enabled
            let ignoreFences = config.debug.enabled
            if !ignoreFences {
            do {
                // Load current fences (they may have been updated during processing via periodic saves)
                var currentFences = try loadIMessageState()
                try saveIMessageState(fences: currentFences)
                logger.info("Saved fences on cancellation", metadata: [
                    "fence_count": String(currentFences.count),
                    "note": "Pending batch messages (if any) will be processed on next run - they're not in fences"
                ])
            } catch {
                logger.warning("Failed to save fences on cancellation", metadata: ["error": error.localizedDescription])
                }
            } else {
                logger.debug("Debug mode: skipping fence save on cancellation")
            }
            
            isRunning = false
            lastRunStatus = "cancelled"
            lastRunStats = stats
            lastRunError = "Collection was cancelled"
            
            // Persist state
            await savePersistedState()
            
            logger.info("iMessage collection cancelled", metadata: [
                "submitted": String(stats.documentsCreated),
                "duration_ms": String(stats.durationMs ?? 0)
            ])
            
            response.finish(status: .error, finishedAt: endTime)
            response.errors = ["Collection was cancelled"]
            
            // Re-throw cancellation error so JobManager can handle it
            throw cancellationError
        } catch {
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "failed"
            lastRunStats = stats
            lastRunError = error.localizedDescription
            
            // Persist state
            await savePersistedState()
            
            logger.error("iMessage collection failed", metadata: ["error": error.localizedDescription])
            
            response.finish(status: .error, finishedAt: endTime)
            response.errors = [error.localizedDescription]
            
            throw error
        }
    }
    
    /// Direct Swift API for getting collector state
    /// Replaces HTTP-based handleState for in-app integration
    public func getCollectorState() async -> CollectorStateInfo {
        // Load persisted state if not already loaded (lazy loading)
        if lastRunTime == nil && lastRunStatus == "idle" {
            await loadPersistedState()
        }
        
        // Convert lastRunStats to [String: HavenCore.AnyCodable]
        var statsDict: [String: HavenCore.AnyCodable]? = nil
        if let stats = lastRunStats {
            var dict: [String: HavenCore.AnyCodable] = [:]
            let statsDictAny = stats.toDict
            for (key, value) in statsDictAny {
                dict[key] = HavenCore.AnyCodable(value)
            }
            statsDict = dict
        }
        
        return CollectorStateInfo(
            isRunning: isRunning,
            lastRunTime: lastRunTime,
            lastRunStatus: lastRunStatus,
            lastRunStats: statsDict,
            lastRunError: lastRunError
        )
    }
    
    /// Helper to convert CollectorRunRequest to CollectorParams
    private func convertCollectorRunRequest(_ request: CollectorRunRequest?) -> CollectorParams {
        var params = CollectorParams()
        params.configChatDbPath = config.modules.imessage.chatDbPath
        
        guard let req = request else {
            return params
        }
        
        // Extract basic parameters
        params.limit = req.limit
        params.order = req.order?.rawValue ?? "desc"
        params.batchMode = req.batch ?? false
        params.batchSize = req.batchSize
        
        // Extract date range
        if let dateRange = req.dateRange {
            params.since = dateRange.since
            params.until = dateRange.until
        }
        
        // Extract iMessage-specific scope fields
        let scopeFields = req.getIMessageScope()
        // Note: scope fields are currently not used in CollectorParams
        // but could be added if needed for filtering
        
        return params
    }
    
    // MARK: - Collection Logic
    
    private struct CollectorParams {
        var limit: Int? = nil
        var order: String? = nil
        var since: Date? = nil
        var until: Date? = nil
        var threadLookbackDays: Int = 90
        // If zero, no implicit lookback is applied. Use explicit `since` or
        // `message_lookback_days` to constrain the query.
        var messageLookbackDays: Int = 0
        var chatDbPath: String = ""
        var configChatDbPath: String = ""
        var batchMode: Bool = false
        var batchSize: Int? = nil
        
        var resolvedChatDbPath: String {
            // Helper to get real home directory (works in sandboxed apps)
            func getRealHomeDirectory() -> String {
                // In sandboxed apps, both HOME and homeDirectoryForCurrentUser may point to container
                // Extract the actual username from the container path and construct real home
                let homeURL = FileManager.default.homeDirectoryForCurrentUser
                var homePath = homeURL.path
                
                // Check if we're in a container directory
                // Container paths look like: /Users/username/Library/Containers/app.bundle/Data
                if homePath.contains("/Library/Containers/") {
                    // Extract username from container path: /Users/username/Library/Containers/...
                    let components = homePath.components(separatedBy: "/")
                    // components will be: ["", "Users", "username", "Library", "Containers", ...]
                    if let usersIndex = components.firstIndex(of: "Users"),
                       usersIndex + 1 < components.count {
                        let username = components[usersIndex + 1]
                        // Construct real home: /Users/username
                        homePath = "/Users/\(username)"
                        return homePath
                    }
                    // Fallback: use NSUserName() which should work even in sandboxed apps
                    let username = NSUserName()
                    homePath = "/Users/\(username)"
                    return homePath
                }
                
                // Not in container, check environment variable
                if let homeEnv = ProcessInfo.processInfo.environment["HOME"],
                   !homeEnv.isEmpty,
                   !homeEnv.contains("Containers") {
                    return homeEnv
                }
                
                // Final fallback: use as-is (might already be correct)
                return homePath
            }
            
            // Helper to expand tilde paths correctly in sandboxed apps
            func expandPath(_ path: String) -> String {
                if path.hasPrefix("~/") {
                    let homeDir = getRealHomeDirectory()
                    let relativePath = String(path.dropFirst(2)) // Remove "~/"
                    return (homeDir as NSString).appendingPathComponent(relativePath)
                } else if path.hasPrefix("~") {
                    // Handle ~username paths (unlikely but possible)
                    return NSString(string: path).expandingTildeInPath
                } else {
                    // Already absolute or relative path
                    return path
                }
            }
            
            if !configChatDbPath.isEmpty {
                return expandPath(configChatDbPath)
            }
            if !chatDbPath.isEmpty {
                return expandPath(chatDbPath)
            }
            // Default: Use real home directory
            let homeDir = getRealHomeDirectory()
            return (homeDir as NSString).appendingPathComponent("Library/Messages/chat.db")
        }
    }
    
    private func collectMessages(
        params: CollectorParams,
        stats: inout CollectorStats,
        onProgress: ((Int, Int, Int, Int, Int?, Int, Int, Int) -> Void)? = nil
    ) async throws -> (documents: [[String: Any]], submittedCount: Int, fences: [FenceRange], pendingBatchTimestamps: [Date], totalCount: Int, scannedCount: Int, skippedCount: Int, errorCount: Int) {
        let chatDbPath = params.resolvedChatDbPath
        
        // Log path resolution for debugging
        let rawHomeURL = FileManager.default.homeDirectoryForCurrentUser.path
        logger.info("Resolved chat.db path", metadata: [
            "path": chatDbPath,
            "configChatDbPath": params.configChatDbPath.isEmpty ? "(empty)" : params.configChatDbPath,
            "chatDbPath": params.chatDbPath.isEmpty ? "(empty)" : params.chatDbPath,
            "rawHomeURL": rawHomeURL,
            "homeEnv": ProcessInfo.processInfo.environment["HOME"] ?? "(not set)"
        ])
        
        // Check if chat.db exists
        guard FileManager.default.fileExists(atPath: chatDbPath) else {
            throw CollectorError.chatDbNotFound(chatDbPath)
        }
        
        // Determine if we need to create a snapshot
        // If the source is already in ~/.haven/, we can use it directly (it's already a copy)
        let havenDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".haven")
        let isAlreadyDevCopy = chatDbPath.hasPrefix(havenDir.path)
        
        let dbPath: String
        if isAlreadyDevCopy {
            // Use the dev copy directly - no snapshot needed
            logger.info("Using development copy directly (no snapshot needed)", metadata: ["path": chatDbPath])
            dbPath = chatDbPath
        } else {
            // Create a safe snapshot of the system chat.db using SQLite backup API
            logger.info("Creating snapshot of system chat.db", metadata: ["source": chatDbPath])
            dbPath = try createChatDbSnapshot(sourcePath: chatDbPath)
            
            // Verify snapshot exists
            guard FileManager.default.fileExists(atPath: dbPath) else {
                throw CollectorError.snapshotFailed("Snapshot file was not created at \(dbPath)")
            }
        }
        
        logger.info("Opening database", metadata: ["path": dbPath])
        
        // Open database with appropriate flags based on mode
        var db: OpaquePointer? = nil
        var openResult: Int32
        var usingSourceFallback = false
        
        if isAlreadyDevCopy {
            // For dev copies, try different approaches to handle missing WAL files
            // Try 1: Open with nolock and immutable flags (works without WAL files)
            let noLockUri = "file:\(dbPath)?mode=ro&nolock=1&immutable=1"
            openResult = sqlite3_open_v2(noLockUri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            
            if openResult != SQLITE_OK {
                logger.warning("Dev copy open with nolock failed; trying basic readonly", metadata: ["code": String(openResult)])
                if db != nil { sqlite3_close(db); db = nil }
                // Try 2: Basic readonly open
                openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
            }
            
            if openResult != SQLITE_OK {
                logger.warning("Dev copy basic open failed; trying immutable URI", metadata: ["code": String(openResult)])
                if db != nil { sqlite3_close(db); db = nil }
                // Try 3: Immutable URI
                let immutableUri = "file:\(dbPath)?mode=ro&immutable=1"
                openResult = sqlite3_open_v2(immutableUri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            }
        } else {
            // For snapshots, prefer opening with immutable URI up-front to avoid WAL/SHM creation
            // which can cause SQLITE_CANTOPEN when the environment disallows auxiliary files.
            let immutableUri = "file:\(dbPath)?mode=ro&immutable=1"
            openResult = sqlite3_open_v2(immutableUri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)

            if openResult != SQLITE_OK {
                logger.warning("Snapshot immutable open failed; trying basic readonly", metadata: ["code": String(openResult)])
                if db != nil { sqlite3_close(db); db = nil }
                // Try a basic readonly open as a fallback
                openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
            }

            if openResult != SQLITE_OK {
                logger.warning("Snapshot basic readonly failed; retrying immutable with nolock", metadata: ["code": String(openResult)])
                if db != nil { sqlite3_close(db); db = nil }
                // As a final attempt, try immutable with nolock
                let noLockImmutable = "file:\(dbPath)?mode=ro&nolock=1&immutable=1"
                openResult = sqlite3_open_v2(noLockImmutable, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            }
        }
        
        // Final fallback: try source database directly
        if openResult != SQLITE_OK {
            logger.warning("All open attempts failed; falling back to source DB", metadata: ["code": String(openResult)])
            if db != nil { sqlite3_close(db); db = nil }
            let sourceUri = "file:\(chatDbPath)?mode=ro&nolock=1"
            openResult = sqlite3_open_v2(sourceUri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            if openResult == SQLITE_OK { usingSourceFallback = true }
        }
        
        guard openResult == SQLITE_OK else {
            var errorMsg = "Failed to open database"
            if let dbLocal = db { errorMsg += ": \(String(cString: sqlite3_errmsg(dbLocal))) (code: \(openResult))" }
            errorMsg += "\nTip: For dev mode, ensure chat.db is properly copied. Run: cp ~/Library/Messages/chat.db ~/.haven/chat.db"
            throw CollectorError.databaseOpenFailed(errorMsg)
        }
        defer { if db != nil { sqlite3_close(db) } }
        logger.info("Database open success", metadata: ["mode": usingSourceFallback ? "source_fallback" : (isAlreadyDevCopy ? "dev_copy" : "snapshot")]) 
        // Diagnostics: journal mode
        do {
            var pragmaStmt: OpaquePointer? = nil
            if sqlite3_prepare_v2(db, "PRAGMA journal_mode;", -1, &pragmaStmt, nil) == SQLITE_OK {
                if sqlite3_step(pragmaStmt) == SQLITE_ROW, let modePtr = sqlite3_column_text(pragmaStmt, 0) {
                    let journalMode = String(cString: modePtr)
                    logger.info("DB journal mode", metadata: ["journal_mode": journalMode])
                }
            }
            sqlite3_finalize(pragmaStmt)
        }
        
        // Load persisted fences (timestamp-based)
        // Skip loading fences if debug mode is enabled
        let ignoreFences = config.debug.enabled
        var fences: [FenceRange] = []
        if !ignoreFences {
        do {
            fences = try loadIMessageState()
            logger.info("Loaded iMessage fences", metadata: ["fence_count": String(fences.count)])
        } catch {
            logger.warning("Failed to load iMessage collector state", metadata: ["error": error.localizedDescription])
            }
        } else {
            logger.info("Debug mode enabled: ignoring fences")
        }

        // Detect gaps between fences that need to be processed
        // Gaps can occur when a run is cancelled mid-way, leaving messages between fences unprocessed
        // Skip gap detection if debug mode is enabled
        let gaps = ignoreFences ? [] : detectGapsBetweenFences(fences: fences)
        if !gaps.isEmpty {
            logger.info("Detected gaps between fences that need processing", metadata: [
                "gap_count": String(gaps.count),
                "gaps": gaps.map { "\(ISO8601DateFormatter().string(from: $0.earliest)) to \(ISO8601DateFormatter().string(from: $0.latest))" }.joined(separator: ", ")
            ])
        }
        
        // Get total count of messages since latest fence for progress tracking
        // This includes messages in gaps between fences
        // When debug mode is enabled, fences is empty, so this will use params-based counting
        var totalCount = try countMessagesSinceLatestFence(db: db!, params: params, fences: fences)
        
        // Add count of messages in gaps between fences
        if !gaps.isEmpty {
            var gapCount = 0
            for gap in gaps {
                let gapEarliestEpoch = dateToAppleEpoch(gap.earliest)
                let gapLatestEpoch = dateToAppleEpoch(gap.latest)
                let gapMessageCount = try countMessagesInRange(db: db!, lowerBoundEpoch: gapEarliestEpoch, upperBoundEpoch: gapLatestEpoch)
                gapCount += gapMessageCount
            }
            totalCount += gapCount
            logger.info("Added gap messages to total count", metadata: [
                "gap_count": String(gaps.count),
                "gap_messages": String(gapCount),
                "total_with_gaps": String(totalCount)
            ])
        }
        
        logger.info("Total messages to process", metadata: ["total_count": String(totalCount), "fence_count": String(fences.count), "gap_count": String(gaps.count), "debug_mode": String(ignoreFences)])

        // Retrieve candidate message ROWIDs chronologically ordered (respects params.order)
        // Default behavior: Fetches messages from newest until latest fence (when no since/until provided)
        // Also includes messages in gaps between fences
        let rowIds = try fetchMessageRowIds(db: db!, params: params, fences: fences, gaps: gaps)
        // Track total candidates
        stats.messagesProcessed = rowIds.count
        
        // Use actual rowIds count as total for progress tracking (more accurate than query-based count)
        // This represents the actual number of messages we'll process
        let actualTotalCount = rowIds.count > 0 ? rowIds.count : (totalCount > 0 ? totalCount : nil)
        
        // Initialize granular state tracking variables
        var foundCount = 0  // Found in initial query (total from rowIds)
        var queuedCount = 0  // Extracted from chat.db, queued for enrichment
        var enrichedCount = 0  // Enrichment complete
        
        // Set found count to total (all messages found in initial query)
        foundCount = rowIds.count
        
        // Report initial progress with total count immediately so UI can display it
        // This shows the user how many records will be processed right away
        onProgress?(0, 0, 0, 0, actualTotalCount, foundCount, queuedCount, enrichedCount)
        
        // Also update stats to reflect we've found the messages (for final stats)
        // Note: scannedCount will be updated as we iterate through messages

        // NOTE: Do NOT set earliest/latest here from the scanned result set.
        // earliest/latest should reflect submitted documents only. These will be
        // updated during the posting loop in `handleRun` after a document is
        // successfully submitted to the Gateway.

        // Convert optional since/until dates to Apple epoch Int64 for comparisons (used during iteration)
        let sinceEpoch: Int64? = params.since != nil ? dateToAppleEpoch(params.since!) : nil
        let untilEpoch: Int64? = params.until != nil ? dateToAppleEpoch(params.until!) : nil

        // Results are already chronologically ordered by fetchMessageRowIds
        // Fences handle deduplication, so we can use the rowIds directly
        // composeProcessingOrder is no longer needed with chronological ordering
        let orderedRowIds = rowIds

        // Process records in caller-configured batches, posting each batch to gateway
        let batchSize = max(1, params.batchSize ?? 500)
        var allDocuments: [[String: Any]] = []
        var submittedCount = 0  // Only count successfully submitted messages toward limit
        var currentBatch: [[String: Any]] = []
        var currentBatchTimestamps: [Date] = []  // Track timestamps for fence updates
        var successfulSubmissionTimestamps: [Date] = []  // Track timestamps of successfully submitted documents
        var scannedCount = 0  // Track messages actually scanned (after filtering)
        var skippedCount = 0  // Track messages skipped (in fences, etc.)
        var errorCount = 0  // Track actual submission failures (from gateway responses)
        
        // Track last fence save time for periodic updates (every 5 seconds)
        var lastFenceSaveTime: Date? = nil
        let fenceSaveInterval: TimeInterval = 5.0  // Save fences every 5 seconds
        
        // Track pending enrichments: documentId -> (baseDocument, messageDate, baseCollectorDocument)
        var pendingEnrichments: [String: ([String: Any], Date, CollectorDocument)] = [:]
        
        logger.info("Processing messages in batches of \(batchSize)", metadata: [
            "total_rows": String(orderedRowIds.count),
            "limit": params.limit?.description ?? "unlimited",
            "submission_mode": params.batchMode ? "batch" : "single",
            "existing_fences": String(fences.count),
            "enrichment_queue_enabled": self.enrichmentQueue != nil ? "true" : "false"
        ])

        // Iterate ordered rows and prepare documents in batches
        for rowId in orderedRowIds {
            // Increment scanned count for every row we check
            scannedCount += 1
            // Check if we've hit the overall limit BEFORE processing
            if let lim = params.limit, lim > 0, submittedCount >= lim {
                logger.info("Reached limit of \(lim) messages, stopping processing")
                break
            }
            
            // Fetch the message row
            guard let message = try fetchMessageByRowId(db: db!, rowId: rowId) else {
                skippedCount += 1
                logger.debug("Failed to fetch message by rowId, skipping", metadata: ["row_id": String(rowId)])
                continue
            }
            
            // Use canonical timestamp: message.date (the message's primary timestamp)
            // This is used for all comparisons, fences, and ordering - never use date_read or date_delivered
            // Convert from Apple epoch to Date for fence checking and date range comparisons
            let messageDate = appleEpochToDate(message.date)

            // Check if message timestamp is within any fence - if so, skip
            // Skip fence check if debug mode is enabled
            let ignoreFences = config.debug.enabled
            if !ignoreFences && FenceManager.isTimestampInFences(messageDate, fences: fences) {
                skippedCount += 1
                logger.debug("Skipping message within fence", metadata: [
                    "row_id": String(rowId),
                    "timestamp": ISO8601DateFormatter().string(from: messageDate),
                    "fence_count": String(fences.count)
                ])
                // Report progress even when skipping so UI stays updated
                // Use actualTotalCount instead of totalCount for accurate progress
                onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
                continue
            }
            
            if ignoreFences {
                logger.debug("Debug mode: ignoring fences, processing message", metadata: [
                    "row_id": String(rowId),
                    "timestamp": ISO8601DateFormatter().string(from: messageDate)
                ])
            }
            
            // Log when we're processing a message near fence boundaries for debugging
            if !fences.isEmpty {
                let closestFence = fences.min(by: { abs($0.earliest.timeIntervalSince(messageDate)) < abs($1.earliest.timeIntervalSince(messageDate)) })
                if let fence = closestFence {
                    let timeSinceEarliest = messageDate.timeIntervalSince(fence.earliest)
                    let timeSinceLatest = messageDate.timeIntervalSince(fence.latest)
                    if abs(timeSinceEarliest) < 60 || abs(timeSinceLatest) < 60 {
                        logger.debug("Processing message near fence boundary", metadata: [
                            "row_id": String(rowId),
                            "timestamp": ISO8601DateFormatter().string(from: messageDate),
                            "fence_earliest": ISO8601DateFormatter().string(from: fence.earliest),
                            "fence_latest": ISO8601DateFormatter().string(from: fence.latest),
                            "seconds_since_earliest": String(format: "%.3f", timeSinceEarliest),
                            "seconds_since_latest": String(format: "%.3f", timeSinceLatest)
                        ])
                    }
                }
            }

            // If date bounds are specified, check them and skip/stop based on processing order
            // All comparisons use the canonical timestamp: message.date (Apple epoch)
            // In descending order (newest first): skip messages > until, stop when < since
            // In ascending order (oldest first): skip messages < since, stop when > until
            let isDescOrder = (params.order?.lowercased() == "desc")
            if isDescOrder {
                // Descending order: process from newest to oldest
                // Compare canonical timestamp directly in Apple epoch format
                if let u = untilEpoch {
                    if message.date > u {
                        // Message is too new (after until), skip and continue to older messages
                        skippedCount += 1
                        logger.debug("Skipping message after until date", metadata: [
                            "row_id": String(rowId),
                            "message_date": String(message.date),
                            "until": String(u)
                        ])
                        continue
                    }
                }
                if let s = sinceEpoch {
                    if message.date < s {
                        // Message is too old (before since), stop processing
                        logger.info("Reached since date constraint, stopping processing")
                        break
                    }
                }
            } else {
                // Ascending order: process from oldest to newest
                // Compare canonical timestamp directly in Apple epoch format
                if let s = sinceEpoch {
                    if message.date < s {
                        // Message is too old (before since), skip and continue to newer messages
                        skippedCount += 1
                        logger.debug("Skipping message before since date", metadata: [
                            "row_id": String(rowId),
                            "message_date": String(message.date),
                            "since": String(s)
                        ])
                        continue
                    }
                }
                if let u = untilEpoch {
                    if message.date > u {
                        // Message is too new (after until), stop processing
                        logger.info("Reached until date constraint, stopping processing")
                        break
                    }
                }
            }

            // Check if message is empty (no text, no attributed body, no attachments)
            if isMessageEmpty(message: message) {
                skippedCount += 1
                logger.debug("Skipping empty message (unsent/retracted or no content)", metadata: [
                    "message_guid": message.guid,
                    "has_attributed_body": message.attributedBody != nil ? "true" : "false",
                    "attributed_body_size": String(message.attributedBody?.count ?? 0),
                    "attachment_count": String(message.attachments.count)
                ])
                continue
            }

            // Fetch thread for message
            let threads = try fetchThreads(db: db!, messageIds: Set([message.chatId]))
            guard let thread = threads.first(where: { $0.rowId == message.chatId }) else {
                skippedCount += 1
                logger.debug("No thread found for message, skipping", metadata: [
                    "row_id": String(rowId),
                    "chat_id": String(message.chatId)
                ])
                continue
            }

            // Build base document (without enrichment)
            let baseAttachments = message.attachments.map { attachment in
                [
                    "row_id": attachment.rowId,
                    "guid": attachment.guid,
                    "mime_type": attachment.mimeType ?? "application/octet-stream",
                    "size_bytes": attachment.totalBytes,
                    "filename": attachment.filename ?? ""
                ] as [String: Any]
            }
            
            let baseDocument = try buildDocument(message: message, thread: thread, attachments: baseAttachments, db: db)
            stats.attachmentsProcessed += message.attachments.count
            
            // Convert to CollectorDocument to check for images
            let collectorDocument = try convertToCollectorDocument(
                message: message,
                thread: thread,
                baseDocument: baseDocument
            )
            
            logger.info("Created CollectorDocument from message", metadata: [
                "source_id": collectorDocument.externalId,
                "image_count": String(collectorDocument.images.count),
                "has_text": !collectorDocument.content.isEmpty
            ])
            
            // Check limit before building/submitting document
            if let lim = params.limit, lim > 0, submittedCount >= lim {
                logger.info("Reached limit of \(lim) messages, stopping processing")
                break
            }
            
            let documentId = collectorDocument.externalId
            
            // Document extracted from chat.db - increment queued count
            queuedCount += 1
            
            if let queue = self.enrichmentQueue {
                // Store pending enrichment info before queuing
                pendingEnrichments[documentId] = (baseDocument, messageDate, collectorDocument)
                
                logger.info("Queuing document for enrichment", metadata: [
                    "document_id": documentId,
                    "image_count": String(collectorDocument.images.count),
                    "queue_available": "true"
                ])
                
                // Queue for enrichment with callback
                let queued = await queue.queueForEnrichment(
                    document: collectorDocument,
                    documentId: documentId
                ) { completedId, enrichedDoc in
                    Task {
                        await self.addEnrichmentCompletion(documentId: completedId, enrichedDocument: enrichedDoc)
                    }
                }
                
                if queued {
                    logger.info("Document queued successfully for enrichment", metadata: [
                        "document_id": documentId,
                        "image_count": String(collectorDocument.images.count)
                    ])
                    
                    // Process any completed enrichments
                    let (processedCount, newEnrichedCount) = await processEnrichmentCompletions(
                        pendingEnrichments: &pendingEnrichments,
                        currentBatch: &currentBatch,
                        currentBatchTimestamps: &currentBatchTimestamps,
                        allDocuments: &allDocuments,
                        stats: &stats,
                        submittedCount: &submittedCount,
                        successfulSubmissionTimestamps: &successfulSubmissionTimestamps
                    )
                    enrichedCount += newEnrichedCount
                    
                    // Sync submitter stats before reporting progress (submitter may have auto-flushed)
                    await syncSubmitterStats(submittedCount: &submittedCount, errorCount: &errorCount)
                    
                    // Report progress after queuing and processing completions
                    onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
                    continue
                } else {
                    // Failed to queue, remove from pending and fall back to synchronous enrichment
                    pendingEnrichments.removeValue(forKey: documentId)
                    logger.warning("Failed to queue document for enrichment, falling back to synchronous path", metadata: [
                        "document_id": documentId
                    ])
                }
            }
            
            // Enrichment queue unavailable - process synchronously (may skip enrichment)
            let enrichedDocument: [String: Any]
            do {
                enrichedDocument = try await enrichDocumentSynchronously(
                    baseDocument: baseDocument,
                    collectorDocument: collectorDocument
                )
                // Synchronous enrichment completed immediately
                enrichedCount += 1
            } catch {
                logger.warning("Synchronous enrichment failed, using base document", metadata: [
                    "document_id": documentId,
                    "error": error.localizedDescription
                ])
                enrichedDocument = baseDocument
                // Still count as enriched (using base document)
                enrichedCount += 1
            }
            
            // Add to batch
            currentBatch.append(enrichedDocument)
            currentBatchTimestamps.append(messageDate)
            allDocuments.append(enrichedDocument)
            stats.documentsCreated += 1
            
            // Report progress periodically while scanning (every 100 messages or on batch boundaries)
            // This keeps the UI updated even before batch submission
            // Use actualTotalCount instead of totalCount for accurate progress
            if scannedCount % 100 == 0 || currentBatch.count >= batchSize {
                // Sync submitter stats before reporting progress (submitter may have auto-flushed)
                await syncSubmitterStats(submittedCount: &submittedCount, errorCount: &errorCount)
                onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
            }
            
            // Process any completed enrichments before checking batch size
            let (_, newEnriched) = await processEnrichmentCompletions(
                pendingEnrichments: &pendingEnrichments,
                currentBatch: &currentBatch,
                currentBatchTimestamps: &currentBatchTimestamps,
                allDocuments: &allDocuments,
                stats: &stats,
                submittedCount: &submittedCount,
                successfulSubmissionTimestamps: &successfulSubmissionTimestamps
            )
            enrichedCount += newEnriched
            // Report progress after processing enrichments
            if newEnriched > 0 {
                // Sync submitter stats before reporting progress (submitter may have auto-flushed)
                await syncSubmitterStats(submittedCount: &submittedCount, errorCount: &errorCount)
                onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
            }

            // Process batch when it reaches batch size OR when we've reached the limit
            let shouldFlushBatch: Bool
            if let lim = params.limit, lim > 0 {
                // Check if adding this document would exceed limit
                // We need to account for documents already in currentBatch that haven't been submitted yet
                let totalPrepared = submittedCount + currentBatch.count
                shouldFlushBatch = currentBatch.count >= batchSize || totalPrepared >= lim
            } else {
                shouldFlushBatch = currentBatch.count >= batchSize
            }
            
            if shouldFlushBatch {
                // Check for cancellation before posting batch (graceful checkpoint)
                try Task.checkCancellation()
                
                // If we have a limit, truncate batch to only submit what we need
                var batchToSubmit = currentBatch
                var timestampsToSubmit = currentBatchTimestamps
                if let lim = params.limit, lim > 0, submittedCount < lim {
                    let remaining = lim - submittedCount
                    if currentBatch.count > remaining {
                        batchToSubmit = Array(currentBatch.prefix(remaining))
                        timestampsToSubmit = Array(currentBatchTimestamps.prefix(remaining))
                        logger.info("Truncating batch to respect limit", metadata: [
                            "original_size": String(currentBatch.count),
                            "truncated_size": String(remaining),
                            "limit": String(lim),
                            "already_submitted": String(submittedCount)
                        ])
                    }
                }
                
                logger.info("Processing batch of \(batchToSubmit.count) documents")
                
                // Post batch to gateway (URLSession will respect cancellation automatically)
                // When a submitter is available, documents are submitted via submitter which flushes automatically when buffer fills
                // Counting happens at submitter level - get stats from submitter
                let batchSuccessCount: Int
                let batchErrorCount: Int
                if let submitter = submitter {
                    // When a submitter is available, documents are already submitted via submitter during enrichment
                    // The submitter flushes documents automatically when its buffer fills (in submit() -> flushIfNeeded())
                    // Get current stats from submitter to update our counts
                    let stats = await submitter.getStats()
                    // Only count the delta since last check - we'll track incrementally
                    // For now, get stats and use them - the submitter tracks totals
                    let previousSubmitted = submittedCount
                    let previousErrors = errorCount
                    // Update to submitter's totals (submitter tracks all submissions)
                    submittedCount = stats.submittedCount
                    errorCount = stats.errorCount
                    // Calculate delta for this batch
                    batchSuccessCount = submittedCount - previousSubmitted
                    batchErrorCount = errorCount - previousErrors
                    logger.debug("Submitter available: batch contains documents already submitted via submitter", metadata: [
                        "batch_size": String(batchToSubmit.count),
                        "submitted_delta": String(batchSuccessCount),
                        "errors_delta": String(batchErrorCount)
                    ])
                } else {
                    // No submitter available - post via HTTP
                    let result = try await postDocumentsToGatewayWithErrors(batchToSubmit, batchMode: params.batchMode)
                    batchSuccessCount = result.successCount
                    batchErrorCount = result.errorCount
                    submittedCount += batchSuccessCount
                    errorCount += batchErrorCount
                }
                logger.info("Posted batch to gateway", metadata: [
                    "batch_size": String(batchToSubmit.count),
                    "posted_to_gateway": String(batchSuccessCount),
                    "errors": String(batchErrorCount),
                    "submission_mode": params.batchMode ? "batch" : "single"
                ])
                
                // Note: submittedCount and errorCount are already updated above if submitter is available
                // Sync submitter stats one more time before reporting (submitter may have auto-flushed during processing)
                await syncSubmitterStats(submittedCount: &submittedCount, errorCount: &errorCount)
                
                // Report progress after batch submission with actual scanned/skipped/error counts
                // Use actualTotalCount instead of totalCount for accurate progress
                onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
                
                // Update fences with successfully submitted timestamps
                // Skip fence updates if debug mode is enabled
                // When using a submitter, documents may have been submitted asynchronously during enrichment,
                // so we use accumulated successful timestamps up to the current submitted count.
                // When not using a submitter, we use batch timestamps.
                var successfulTimestamps: [Date] = []
                if let submitter = submitter {
                    // When using a submitter, use accumulated timestamps from async submissions
                    // Only use timestamps up to the current submitted count to ensure we don't include
                    // timestamps for documents that haven't been successfully submitted yet
                    let countToUse = min(successfulSubmissionTimestamps.count, submittedCount)
                    successfulTimestamps = Array(successfulSubmissionTimestamps.prefix(countToUse))
                } else {
                    // When not using a submitter, use timestamps from the batch that was just submitted
                    successfulTimestamps = Array(timestampsToSubmit.prefix(batchSuccessCount))
                    // Track these timestamps for consistency
                    successfulSubmissionTimestamps.append(contentsOf: successfulTimestamps)
                }
                
                if !ignoreFences && !successfulTimestamps.isEmpty {
                    let minTimestamp = successfulTimestamps.min()!
                    let maxTimestamp = successfulTimestamps.max()!
                    fences = FenceManager.addFence(newEarliest: minTimestamp, newLatest: maxTimestamp, existingFences: fences)
                    
                    // Save fences periodically (every 5 seconds) or if this is the first save
                    let now = Date()
                    let shouldSave = lastFenceSaveTime == nil || now.timeIntervalSince(lastFenceSaveTime!) >= fenceSaveInterval
                    
                    if shouldSave {
                        do {
                            try saveIMessageState(fences: fences)
                            lastFenceSaveTime = now
                            logger.debug("Saved fences to disk", metadata: [
                                "fence_count": String(fences.count),
                                "elapsed_since_last_save": lastFenceSaveTime == nil ? "N/A" : String(format: "%.2f", now.timeIntervalSince(lastFenceSaveTime!))
                            ])
                        } catch {
                            logger.warning("Failed to save iMessage collector state", metadata: ["error": error.localizedDescription])
                        }
                    }
                    
                    // Update earliest/latest timestamps for successfully posted docs using the same timestamps
                    // These represent messages actually submitted in THIS run only
                    logger.debug("Updating stats with successful timestamps", metadata: [
                        "count": String(successfulTimestamps.count),
                        "min": ISO8601DateFormatter().string(from: successfulTimestamps.min() ?? Date()),
                        "max": ISO8601DateFormatter().string(from: successfulTimestamps.max() ?? Date())
                    ])
                    for timestamp in successfulTimestamps {
                        let appleTs = dateToAppleEpoch(timestamp)
                        if let prev = stats.earliestMessageTimestamp {
                            if appleTs < prev { stats.earliestMessageTimestamp = appleTs }
                        } else {
                            stats.earliestMessageTimestamp = appleTs
                        }
                        if let prev = stats.latestMessageTimestamp {
                            if appleTs > prev { stats.latestMessageTimestamp = appleTs }
                        } else {
                            stats.latestMessageTimestamp = appleTs
                        }
                    }
                }
                
                // Remove submitted items from current batch
                let remainingCount = currentBatch.count - batchToSubmit.count
                if remainingCount > 0 {
                    currentBatch = Array(currentBatch.suffix(remainingCount))
                    currentBatchTimestamps = Array(currentBatchTimestamps.suffix(remainingCount))
                } else {
                    currentBatch = []
                    currentBatchTimestamps = []
                }
                
                // Check if we've reached the limit after this batch
                if let lim = params.limit, lim > 0, submittedCount >= lim {
                    logger.info("Reached limit of \(lim) messages after batch submission, stopping processing")
                    break
                }
            }
        }
        
        // Process any remaining documents in the final batch
        // Wait for all pending enrichments to complete before final batch
        if let queue = self.enrichmentQueue, !pendingEnrichments.isEmpty {
            logger.info("Waiting for all pending enrichments to complete", metadata: [
                "pending_count": String(pendingEnrichments.count)
            ])
            
            // Poll for completions until all are done (no timeout)
            let pollInterval: TimeInterval = 0.5 // Check every 500ms
            
            while !pendingEnrichments.isEmpty {
                // Process any completions that have arrived
                let (_, newEnriched) = await processEnrichmentCompletions(
                    pendingEnrichments: &pendingEnrichments,
                    currentBatch: &currentBatch,
                    currentBatchTimestamps: &currentBatchTimestamps,
                    allDocuments: &allDocuments,
                    stats: &stats,
                    submittedCount: &submittedCount,
                    successfulSubmissionTimestamps: &successfulSubmissionTimestamps
                )
                enrichedCount += newEnriched
                
                // Sync submitter stats before reporting progress (submitter may have auto-flushed)
                await syncSubmitterStats(submittedCount: &submittedCount, errorCount: &errorCount)
                
                // Report progress periodically while waiting for enrichments
                if newEnriched > 0 {
                    onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
                }
                
                // If still pending, wait a bit before checking again
                if !pendingEnrichments.isEmpty {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    // Sync submitter stats again before reporting (may have flushed during sleep)
                    await syncSubmitterStats(submittedCount: &submittedCount, errorCount: &errorCount)
                    // Report progress even if no new enrichments (to show we're still waiting)
                    onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
                }
            }
            
            logger.info("All pending enrichments completed", metadata: [
                "total_processed": String(stats.documentsCreated)
            ])
        }
        
        // But only if we haven't exceeded the limit
        if !currentBatch.isEmpty {
            // Truncate to limit if needed
            var finalBatch = currentBatch
            var finalTimestamps = currentBatchTimestamps
            if let lim = params.limit, lim > 0, submittedCount < lim {
                let remaining = lim - submittedCount
                if currentBatch.count > remaining {
                    finalBatch = Array(currentBatch.prefix(remaining))
                    finalTimestamps = Array(currentBatchTimestamps.prefix(remaining))
                    logger.info("Truncating final batch to respect limit", metadata: [
                        "original_size": String(currentBatch.count),
                        "truncated_size": String(remaining),
                        "limit": String(lim),
                        "already_submitted": String(submittedCount)
                    ])
                }
            }
            
            // Check for cancellation before posting final batch (graceful checkpoint)
            try Task.checkCancellation()
            
            logger.info("Processing final batch of \(finalBatch.count) documents")
            
            // Post batch to gateway or flush submitter
            let batchSuccessCount: Int
            let batchErrorCount: Int
            if let submitter = submitter {
                // When a submitter is available, ensure submitter flushes all remaining buffered documents
                // Get final stats from submitter after flushing
                let previousSubmitted = submittedCount
                let previousErrors = errorCount
                do {
                    let stats = try await submitter.finish()
                    // Update to final stats from submitter
                    submittedCount = stats.submittedCount
                    errorCount = stats.errorCount
                    // Calculate delta for final batch
                    batchSuccessCount = submittedCount - previousSubmitted
                    batchErrorCount = errorCount - previousErrors
                    logger.info("Submitter flushed all remaining buffered documents", metadata: [
                        "final_batch_count": String(finalBatch.count),
                        "submitted_delta": String(batchSuccessCount),
                        "errors_delta": String(batchErrorCount),
                        "total_submitted": String(stats.submittedCount),
                        "total_errors": String(stats.errorCount)
                    ])
                } catch {
                    logger.error("Submitter finish failed", metadata: [
                        "error": error.localizedDescription,
                        "final_batch_count": String(finalBatch.count)
                    ])
                    // Get stats even if finish failed (some may have been submitted)
                    let stats = await submitter.getStats()
                    submittedCount = stats.submittedCount
                    errorCount = stats.errorCount
                    batchSuccessCount = submittedCount - previousSubmitted
                    batchErrorCount = errorCount - previousErrors
                }
            } else {
                // No submitter available - post via HTTP
                let result = try await postDocumentsToGatewayWithErrors(finalBatch, batchMode: params.batchMode)
                batchSuccessCount = result.successCount
                batchErrorCount = result.errorCount
                submittedCount += batchSuccessCount
                errorCount += batchErrorCount
            }
            logger.info("Posted final batch to gateway", metadata: [
                "batch_size": String(finalBatch.count),
                "posted_to_gateway": String(batchSuccessCount),
                "errors": String(batchErrorCount),
                "submission_mode": params.batchMode ? "batch" : "single"
            ])
            
            // Sync submitter stats one more time before final progress report (may have flushed after finish())
            await syncSubmitterStats(submittedCount: &submittedCount, errorCount: &errorCount)
            
            // Report progress after final batch submission with actual scanned/skipped/error counts
            // Use actualTotalCount instead of totalCount for accurate progress
            onProgress?(scannedCount, scannedCount, submittedCount, skippedCount, actualTotalCount, foundCount, queuedCount, enrichedCount)
            
            // Store final counts in stats for persistence
            stats.scanned = scannedCount
            stats.matched = scannedCount
            stats.submitted = submittedCount
            stats.skipped = skippedCount
            stats.errors = errorCount
            stats.total = actualTotalCount
            stats.found = foundCount
            stats.queued = queuedCount
            stats.enriched = enrichedCount
            
            // Update fences with successfully submitted timestamps
            // Skip fence updates if debug mode is enabled
            // When using a submitter, use accumulated successful timestamps from the entire run,
            // limited to the total submitted count. When not using a submitter, use timestamps from the final batch.
            var successfulTimestamps: [Date] = []
            if let submitter = submitter {
                // When using a submitter, documents were submitted asynchronously during enrichment.
                // Use accumulated successful timestamps, but only up to the total submitted count
                // to ensure we don't include timestamps for documents that failed or are still pending.
                let countToUse = min(successfulSubmissionTimestamps.count, submittedCount)
                successfulTimestamps = Array(successfulSubmissionTimestamps.prefix(countToUse))
                // Also add timestamps from final batch if any documents were in the submitter's buffer
                if batchSuccessCount > 0 && !finalTimestamps.isEmpty {
                    // The final batch may contain documents that were in the submitter's buffer.
                    // Add their timestamps (up to the batchSuccessCount) to our tracking.
                    let finalBatchTimestamps = Array(finalTimestamps.prefix(batchSuccessCount))
                    successfulSubmissionTimestamps.append(contentsOf: finalBatchTimestamps)
                    // Recalculate with updated count
                    let updatedCountToUse = min(successfulSubmissionTimestamps.count, submittedCount)
                    successfulTimestamps = Array(successfulSubmissionTimestamps.prefix(updatedCountToUse))
                }
            } else {
                // When not using a submitter, use timestamps from the final batch that was just submitted
                successfulTimestamps = Array(finalTimestamps.prefix(batchSuccessCount))
                successfulSubmissionTimestamps.append(contentsOf: successfulTimestamps)
            }
            
            if !ignoreFences && !successfulTimestamps.isEmpty {
                let minTimestamp = successfulTimestamps.min()!
                let maxTimestamp = successfulTimestamps.max()!
                fences = FenceManager.addFence(newEarliest: minTimestamp, newLatest: maxTimestamp, existingFences: fences)
                
                // Update earliest/latest timestamps for successfully posted docs using the same timestamps
                // These represent messages actually submitted in THIS run only
                for timestamp in successfulTimestamps {
                    let appleTs = dateToAppleEpoch(timestamp)
                    if let prev = stats.earliestMessageTimestamp {
                        if appleTs < prev { stats.earliestMessageTimestamp = appleTs }
                    } else {
                        stats.earliestMessageTimestamp = appleTs
                    }
                    if let prev = stats.latestMessageTimestamp {
                        if appleTs > prev { stats.latestMessageTimestamp = appleTs }
                    } else {
                        stats.latestMessageTimestamp = appleTs
                    }
                }
            }
        }
        
        // Always save fences at the end of processing (final save)
        // Skip saving fences if debug mode is enabled
        if !ignoreFences {
        do {
            try saveIMessageState(fences: fences)
            logger.debug("Saved fences to disk (final save)", metadata: ["fence_count": String(fences.count)])
        } catch {
            logger.warning("Failed to save iMessage collector state (final save)", metadata: ["error": error.localizedDescription])
            }
        } else {
            logger.debug("Debug mode: skipping fence save (final save)")
        }


        // Return pending batch timestamps so caller can handle gaps on cancellation
        // Note: In descending order (default), pending batch messages are older than the latest fence,
        // so they will be processed on the next run. The fence system handles gaps correctly because
        // it only skips messages that are WITHIN fences, not messages between fences.
        let pendingTimestamps = currentBatchTimestamps
        return (documents: allDocuments, submittedCount: submittedCount, fences: fences, pendingBatchTimestamps: pendingTimestamps, totalCount: totalCount, scannedCount: scannedCount, skippedCount: skippedCount, errorCount: errorCount)
    }
    
    private func createChatDbSnapshot(sourcePath: String) throws -> String {
        // Use HavenFilePaths for chat backup directory
        let havenDir = HavenFilePaths.chatBackupDirectory
        try FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        
        let snapshotPath = havenDir.appendingPathComponent("chat.db").path
        let tmpPath = havenDir.appendingPathComponent("chat.db.tmp").path
        
        // Remove existing tmp file if present (best-effort cleanup)
        try? FileManager.default.removeItem(atPath: tmpPath)
        
        // Use SQLite backup API to safely copy the database
        // This handles WAL mode and ensures consistency.
        // Match Python implementation: write to tmp, then rename atomically
        var sourceDb: OpaquePointer? = nil
        var destDb: OpaquePointer? = nil
        logger.info("Snapshot: opening source", metadata: ["source": sourcePath])
        
        // Open source database in read-only mode with URI
        let sourceUri = "file:\(sourcePath)?mode=ro"
        guard sqlite3_open_v2(sourceUri, &sourceDb, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let errorMsg = sourceDb != nil ? String(cString: sqlite3_errmsg(sourceDb)) : "unknown error"
            if sourceDb != nil { sqlite3_close(sourceDb) }
            throw CollectorError.snapshotFailed("Failed to open source database: \(errorMsg)")
        }
        
        // Open/create temporary destination database
        guard sqlite3_open(tmpPath, &destDb) == SQLITE_OK else {
            let errorMsg = destDb != nil ? String(cString: sqlite3_errmsg(destDb)) : "unknown error"
            if destDb != nil { sqlite3_close(destDb) }
            if sourceDb != nil { sqlite3_close(sourceDb) }
            throw CollectorError.snapshotFailed("Failed to create tmp snapshot database: \(errorMsg)")
        }
        
        // Perform the backup using SQLite's backup API
        guard let backup = sqlite3_backup_init(destDb, "main", sourceDb, "main") else {
            let errorMsg = destDb != nil ? String(cString: sqlite3_errmsg(destDb)) : "backup init failed"
            // Clean up before throwing
            if destDb != nil { sqlite3_close(destDb) }
            if sourceDb != nil { sqlite3_close(sourceDb) }
            throw CollectorError.snapshotFailed("Failed to initialize backup: \(errorMsg)")
        }
        logger.info("Snapshot: backup init successful")
        
        // Incremental copy with retry on BUSY/LOCKED
        var totalPagesCopied: Int32 = 0
        var attempts = 0
        while true {
            let rc = sqlite3_backup_step(backup, 1024)
            if rc == SQLITE_DONE {
                break
            } else if rc == SQLITE_OK {
                attempts += 1
                totalPagesCopied = sqlite3_backup_pagecount(backup)
                continue
            } else if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                attempts += 1
                usleep(50_000) // 50ms backoff
                continue
            } else {
                let errorMsg = destDb != nil ? String(cString: sqlite3_errmsg(destDb)) : "backup step failed"
                sqlite3_backup_finish(backup)
                if destDb != nil { sqlite3_close(destDb) }
                if sourceDb != nil { sqlite3_close(sourceDb) }
                throw CollectorError.snapshotFailed("Backup failed: \(errorMsg) (code: \(rc)) after \(attempts) attempts")
            }
        }
        sqlite3_backup_finish(backup)
        logger.info("Snapshot: backup step completed", metadata: ["attempts": String(attempts), "pages": String(totalPagesCopied)])
        
        // Checkpoint the destination database to consolidate any WAL into the main file
        // This ensures the snapshot is a complete, standalone database
        var checkpointErr: UnsafeMutablePointer<Int8>?
        let checkpointRc = sqlite3_exec(destDb, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, &checkpointErr)
        if checkpointRc != SQLITE_OK {
            logger.warning("Snapshot: WAL checkpoint warning", metadata: [
                "code": String(checkpointRc),
                "error": checkpointErr != nil ? String(cString: checkpointErr!) : "none"
            ])
            if checkpointErr != nil { sqlite3_free(checkpointErr) }
        }
        
        // Close both databases to ensure all data is flushed
        sqlite3_close(destDb)
        sqlite3_close(sourceDb)
        
        // Clean up any WAL or SHM files from the tmp database
        try? FileManager.default.removeItem(atPath: tmpPath + "-wal")
        try? FileManager.default.removeItem(atPath: tmpPath + "-shm")
        
        // Atomically rename tmp to final snapshot path (overwrites existing)
        // Use FileManager.replaceItemAt for atomic replacement
        let tmpUrl = URL(fileURLWithPath: tmpPath)
        let snapshotUrl = URL(fileURLWithPath: snapshotPath)
        
        if FileManager.default.fileExists(atPath: snapshotPath) {
            // Replace existing file atomically
            _ = try? FileManager.default.replaceItemAt(snapshotUrl, withItemAt: tmpUrl)
        } else {
            // No existing file, just move
            try FileManager.default.moveItem(at: tmpUrl, to: snapshotUrl)
        }
        
        logger.info("Created chat.db snapshot using SQLite backup API", metadata: ["path": snapshotPath])
        return snapshotPath
    }
    
    // MARK: - Database Queries
    
    private struct MessageData {
        let rowId: Int64
        let guid: String
        let text: String?
        let attributedBody: Data?
        let handleId: Int64
        let date: Int64
        let dateRead: Int64?
        let dateDelivered: Int64?
        let isFromMe: Bool
        let isRead: Bool
        let chatId: Int64
        let service: String?
        let account: String?
        let attachments: [AttachmentData]
        // Reaction/impact flags for filtering out non-content messages
        let subject: String?  // Indicates reaction type (e.g., "expressivesend", "react")
        let associatedMessageGuid: String?  // The message this is reacting to
        let associatedMessageType: Int?  // Type of associated message (2000-2005 = reactions, 1000 = sticker)
        let threadOriginatorGuid: String?  // For explicit thread replies (when user taps "Reply")
    }
    
    private struct ThreadData {
        let rowId: Int64
        let guid: String
        let chatIdentifier: String?
        let serviceName: String?
        let displayName: String?
        let participants: [String]
        let isGroup: Bool
    }
    
    private struct AttachmentData {
        let rowId: Int64
        let guid: String
        let filename: String?
        let mimeType: String?
        let totalBytes: Int64
        let uti: String?
    }
    
    private func fetchMessages(db: OpaquePointer, params: CollectorParams) throws -> [MessageData] {
        var messages: [MessageData] = []
        
        // Determine whether to apply a date lower-bound. Preference order:
        // 1) explicit params.since
        // 2) messageLookbackDays > 0
        // 3) no date constraint (scan all messages)

        var lowerBoundEpoch: Int64? = nil
        if let since = params.since {
            lowerBoundEpoch = dateToAppleEpoch(since)
        } else if params.messageLookbackDays > 0 {
            let lookbackDate = Date().addingTimeInterval(-Double(params.messageLookbackDays) * 24 * 3600)
            lowerBoundEpoch = dateToAppleEpoch(lookbackDate)
        }

     var query = """
         SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, m.date, m.date_read,
             m.date_delivered, m.is_from_me, m.is_read, cmj.chat_id, m.service, m.account,
             m.subject, m.associated_message_guid, m.associated_message_type, m.thread_originator_guid
         FROM message m
         JOIN chat_message_join cmj ON m.ROWID = cmj.message_id

         """

        if lowerBoundEpoch != nil {
            query += "WHERE m.date >= ?\n"
        }
        query += "ORDER BY m.date DESC\nLIMIT ?\n"

    // Log the query for diagnostics (helps when dynamic query composition causes syntax errors)
    logger.debug("Preparing message query", metadata: ["query": query])
    var stmt: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare message query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare message query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        if let lb = lowerBoundEpoch {
            sqlite3_bind_int64(stmt, bindIndex, lb)
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(1000)) // Fetch more to allow filtering (fixed limit)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let guid = String(cString: sqlite3_column_text(stmt, 1))
            
            let text: String?
            if let textPtr = sqlite3_column_text(stmt, 2) {
                text = String(cString: textPtr)
            } else {
                text = nil
            }
            
            let attributedBody: Data?
            if sqlite3_column_type(stmt, 3) == SQLITE_BLOB {
                if let bytes = sqlite3_column_blob(stmt, 3) {
                    let count = sqlite3_column_bytes(stmt, 3)
                    attributedBody = Data(bytes: bytes, count: Int(count))
                } else {
                    attributedBody = nil
                }
            } else {
                attributedBody = nil
            }
            
            let handleId = sqlite3_column_int64(stmt, 4)
            let date = sqlite3_column_int64(stmt, 5)
            let dateRead = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_int64(stmt, 6) : nil
            let dateDelivered = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_int64(stmt, 7) : nil
            let isFromMe = sqlite3_column_int(stmt, 8) != 0
            let isRead = sqlite3_column_int(stmt, 9) != 0
            let chatId = sqlite3_column_int64(stmt, 10)
            
            let service: String?
            if let servicePtr = sqlite3_column_text(stmt, 11) {
                service = String(cString: servicePtr)
            } else {
                service = nil
            }
            
            let account: String?
            if let accountPtr = sqlite3_column_text(stmt, 12) {
                account = String(cString: accountPtr)
            } else {
                account = nil
            }
            
            let subject: String?
            if let subjectPtr = sqlite3_column_text(stmt, 13) {
                subject = String(cString: subjectPtr)
            } else {
                subject = nil
            }
            
            let associatedMessageGuid: String?
            if let assocGuidPtr = sqlite3_column_text(stmt, 14) {
                associatedMessageGuid = String(cString: assocGuidPtr)
            } else {
                associatedMessageGuid = nil
            }

            let associatedMessageType: Int?
            if sqlite3_column_type(stmt, 15) != SQLITE_NULL {
                associatedMessageType = Int(sqlite3_column_int(stmt, 15))
            } else {
                associatedMessageType = nil
            }

            let threadOriginatorGuid: String?
            if let threadOriginatorPtr = sqlite3_column_text(stmt, 16) {
                threadOriginatorGuid = String(cString: threadOriginatorPtr)
            } else {
                threadOriginatorGuid = nil
            }
            
            // Fetch attachments for this message
            let attachments = try fetchAttachments(db: db, messageRowId: rowId)
            
            messages.append(MessageData(
                rowId: rowId,
                guid: guid,
                text: text,
                attributedBody: attributedBody,
                handleId: handleId,
                date: date,
                dateRead: dateRead,
                dateDelivered: dateDelivered,
                isFromMe: isFromMe,
                isRead: isRead,
                chatId: chatId,
                service: service,
                account: account,
                attachments: attachments,
                subject: subject,
                associatedMessageGuid: associatedMessageGuid,
                associatedMessageType: associatedMessageType,
                threadOriginatorGuid: threadOriginatorGuid
            ))
        }
        
        return messages
    }
    
    /// Detect gaps between fences that need to be processed
    /// Gaps occur when there are non-contiguous fences (e.g., from cancelled batches)
    private func detectGapsBetweenFences(fences: [FenceRange]) -> [FenceRange] {
        guard fences.count > 1 else { return [] }
        
        // Sort fences by earliest timestamp
        let sortedFences = fences.sorted { $0.earliest < $1.earliest }
        var gaps: [FenceRange] = []
        
        // Check for gaps between consecutive fences
        for i in 0..<sortedFences.count - 1 {
            let current = sortedFences[i]
            let next = sortedFences[i + 1]
            
            // If fences are not contiguous, there's a gap
            if !current.isContiguous(with: next) {
                // Gap is from current.latest to next.earliest
                // But we need to be careful: if current.latest > next.earliest, they overlap (no gap)
                if current.latest < next.earliest {
                    let gapEarliest = current.latest
                    let gapLatest = next.earliest
                    gaps.append(FenceRange(earliest: gapEarliest, latest: gapLatest))
                }
            }
        }
        
        return gaps
    }

    private func fetchMessageRowIds(db: OpaquePointer, params: CollectorParams, fences: [FenceRange], gaps: [FenceRange] = []) throws -> [Int64] {
        var ids: [Int64] = []
        // Use canonical timestamp: message.date (not date_read or date_delivered)
        // This is the message's primary timestamp used for all processing, fences, and ordering
        
        // Determine effective lower-bound
        // Default behavior: If no explicit since/until is provided, start from newest and stop at latest fence
        // BUT: Also include messages in gaps between fences (from cancelled batches)
        var lowerBoundEpoch: Int64? = nil
        let latestFenceTimestamp: Date? = fences.isEmpty ? nil : fences.map { $0.latest }.max()
        let earliestFenceTimestamp: Date? = fences.isEmpty ? nil : fences.map { $0.earliest }.min()
        
        // Find the oldest gap timestamp (if any) - we need to process gaps too
        let oldestGapEarliest: Date? = gaps.isEmpty ? nil : gaps.map { $0.earliest }.min()
        
        if let since = params.since {
            // Explicit since provided by user
            let sinceEpoch = dateToAppleEpoch(since)
            // If the user is backfilling OLDER than the earliest fence, allow processing up to the fence boundary.
            if let earliestFence = earliestFenceTimestamp, since < earliestFence {
                // Backfill mode: process [since, earliestFence]
                lowerBoundEpoch = sinceEpoch
                // Upper bound is limited to earliest fence to avoid reprocessing fenced data
                // (we'll finalize upperBoundEpoch after it's initialized below)
                // Note: gaps logic is irrelevant for the pre-fence region
            } else {
                // Normal behavior when since is within or newer than fenced ranges:
                // do not go earlier than the latest fence
                if let latestFence = latestFenceTimestamp {
                    let latestFenceEpoch = dateToAppleEpoch(latestFence)
                    lowerBoundEpoch = max(sinceEpoch, latestFenceEpoch)
                } else {
                    lowerBoundEpoch = sinceEpoch
                }
                // Also consider gaps - if oldest gap is older than our lower bound, include it
                if let oldestGap = oldestGapEarliest {
                    let currentLower = lowerBoundEpoch ?? sinceEpoch
                    let oldestGapEpoch = dateToAppleEpoch(oldestGap)
                    lowerBoundEpoch = min(currentLower, oldestGapEpoch)  // Include gaps older than the fence
                }
            }
        } else if let latestFence = latestFenceTimestamp {
            // Default: Use latest fence as lower bound (stop at latest fence)
            // BUT: If there are gaps older than the latest fence, we need to include them
            if let oldestGap = oldestGapEarliest, oldestGap < latestFence {
                // Gaps exist that are older than latest fence - we need to process from oldest gap
                lowerBoundEpoch = dateToAppleEpoch(oldestGap)
                logger.info("Including gaps in processing", metadata: [
                    "latest_fence": ISO8601DateFormatter().string(from: latestFence),
                    "oldest_gap": ISO8601DateFormatter().string(from: oldestGap)
                ])
            } else {
                // No gaps or gaps are newer than latest fence - normal behavior
                lowerBoundEpoch = dateToAppleEpoch(latestFence)
            }
        } else if params.messageLookbackDays > 0 {
            // Fallback: Use messageLookbackDays if no fences exist
            let lookbackDate = Date().addingTimeInterval(-Double(params.messageLookbackDays) * 24 * 3600)
            lowerBoundEpoch = dateToAppleEpoch(lookbackDate)
        }
        
        // Determine upper-bound (until constraint)
        var upperBoundEpoch: Int64? = params.until != nil ? dateToAppleEpoch(params.until!) : nil
        // If we're backfilling prior to the earliest fence, cap the upper bound at the fence boundary.
        if let since = params.since, let earliestFence = earliestFenceTimestamp, since < earliestFence {
            let fenceEpoch = dateToAppleEpoch(earliestFence)
            if let currentUpper = upperBoundEpoch {
                upperBoundEpoch = min(currentUpper, fenceEpoch)
            } else {
                upperBoundEpoch = fenceEpoch
            }
        }

        // Determine chronological order (ascending = oldest first, descending = newest first)
        let isDescOrder = (params.order?.lowercased() == "desc")
        let orderDirection = isDescOrder ? "DESC" : "ASC"

        var query = """
            SELECT m.ROWID
            FROM message m

            """
        var whereClauses: [String] = []
        // Use canonical timestamp field: m.date
        if lowerBoundEpoch != nil {
            whereClauses.append("m.date >= ?")
        }
        if upperBoundEpoch != nil {
            whereClauses.append("m.date <= ?")
        }
        if !whereClauses.isEmpty {
            query += "WHERE " + whereClauses.joined(separator: " AND ") + "\n"
        }
        // Order chronologically by timestamp, with ROWID as tiebreaker for stability
        query += "ORDER BY m.date \(orderDirection), m.ROWID \(orderDirection)\n"

        // Log the query to help diagnose SQL syntax issues when dynamically composing the WHERE clause
        logger.debug("Preparing message rowid query", metadata: ["query": query])
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare message rowid query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare message rowid query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }

        // Bind parameters in order: lowerBound (since) first, then upperBound (until)
        var paramIndex: Int32 = 1
        if let lb = lowerBoundEpoch {
            sqlite3_bind_int64(stmt, paramIndex, lb)
            paramIndex += 1
        }
        if let ub = upperBoundEpoch {
            sqlite3_bind_int64(stmt, paramIndex, ub)
            paramIndex += 1
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            ids.append(rowId)
        }

        return ids
    }
    
    /// Count messages since the latest fence timestamp
    /// - Parameters:
    ///   - db: Database connection
    ///   - params: Collector parameters
    ///   - fences: Array of fence ranges
    /// - Returns: Count of messages that would be processed (not in fences)
    private func countMessagesSinceLatestFence(db: OpaquePointer, params: CollectorParams, fences: [FenceRange]) throws -> Int {
        // Find the latest fence timestamp (maximum latest date from all fences)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fenceTimestamps = fences.map { formatter.string(from: $0.latest) }
        logger.debug("Counting messages since latest fence", metadata: [
            "fence_count": String(fences.count),
            "fence_latest_timestamps": fenceTimestamps.joined(separator: ", ")
        ])
        let latestFenceTimestamp: Date? = fences.isEmpty ? nil : fences.map { $0.latest }.max()
        
        if let latestFence = latestFenceTimestamp {
            logger.debug("Using latest fence timestamp as lower bound", metadata: [
                "latest_fence_timestamp": formatter.string(from: latestFence)
            ])
        } else {
            logger.debug("No fences found, using params for lower bound")
        }
        
        // Determine effective lower-bound
        // If we have a latest fence, use that as the minimum since date
        // Otherwise, use the params.since or messageLookbackDays
        var lowerBoundEpoch: Int64? = nil
        if let since = params.since {
            let sinceEpoch = dateToAppleEpoch(since)
            // If we have a latest fence, use the maximum of since and latest fence
            if let latestFence = latestFenceTimestamp {
                let latestFenceEpoch = dateToAppleEpoch(latestFence)
                lowerBoundEpoch = max(sinceEpoch, latestFenceEpoch)
            } else {
                lowerBoundEpoch = sinceEpoch
            }
        } else if let latestFence = latestFenceTimestamp {
            // Use latest fence as the lower bound
            lowerBoundEpoch = dateToAppleEpoch(latestFence)
        } else if params.messageLookbackDays > 0 {
            let lookbackDate = Date().addingTimeInterval(-Double(params.messageLookbackDays) * 24 * 3600)
            lowerBoundEpoch = dateToAppleEpoch(lookbackDate)
        }
        
        // Determine upper-bound (until constraint)
        let upperBoundEpoch: Int64? = params.until != nil ? dateToAppleEpoch(params.until!) : nil
        
        // Build COUNT query
        var query = "SELECT COUNT(*) FROM message m"
        var whereClauses: [String] = []
        
        if lowerBoundEpoch != nil {
            whereClauses.append("m.date >= ?")
        }
        if upperBoundEpoch != nil {
            whereClauses.append("m.date <= ?")
        }
        if !whereClauses.isEmpty {
            query += " WHERE " + whereClauses.joined(separator: " AND ")
        }
        
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare message count query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare message count query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }
        
        // Bind parameters
        var paramIndex: Int32 = 1
        if let lb = lowerBoundEpoch {
            sqlite3_bind_int64(stmt, paramIndex, lb)
            paramIndex += 1
        }
        if let ub = upperBoundEpoch {
            sqlite3_bind_int64(stmt, paramIndex, ub)
            paramIndex += 1
        }
        
        // Execute query and get count
        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_int(stmt, 0)
            return Int(count)
        }
        
        return 0
    }
    
    /// Count messages in a specific date range
    private func countMessagesInRange(db: OpaquePointer, lowerBoundEpoch: Int64, upperBoundEpoch: Int64) throws -> Int {
        let query = "SELECT COUNT(*) FROM message m WHERE m.date >= ? AND m.date <= ?"
        
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare gap message count query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare gap message count query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, lowerBoundEpoch)
        sqlite3_bind_int64(stmt, 2, upperBoundEpoch)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_int(stmt, 0)
            return Int(count)
        }
        
        return 0
    }

    private func fetchMessageByRowId(db: OpaquePointer, rowId: Int64) throws -> MessageData? {
        let query = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, m.date, m.date_read,
                   m.date_delivered, m.is_from_me, m.is_read, cmj.chat_id, m.service, m.account,
                   m.subject, m.associated_message_guid, m.associated_message_type, m.thread_originator_guid
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE m.ROWID = ?
            LIMIT 1
            """

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare single message query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare single message query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, rowId)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let guid = String(cString: sqlite3_column_text(stmt, 1))

            let text: String?
            if let textPtr = sqlite3_column_text(stmt, 2) {
                text = String(cString: textPtr)
            } else {
                text = nil
            }

            let attributedBody: Data?
            if sqlite3_column_type(stmt, 3) == SQLITE_BLOB {
                if let bytes = sqlite3_column_blob(stmt, 3) {
                    let count = sqlite3_column_bytes(stmt, 3)
                    attributedBody = Data(bytes: bytes, count: Int(count))
                } else {
                    attributedBody = nil
                }
            } else {
                attributedBody = nil
            }

            let handleId = sqlite3_column_int64(stmt, 4)
            let date = sqlite3_column_int64(stmt, 5)
            let dateRead = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_int64(stmt, 6) : nil
            let dateDelivered = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_int64(stmt, 7) : nil
            let isFromMe = sqlite3_column_int(stmt, 8) != 0
            let isRead = sqlite3_column_int(stmt, 9) != 0
            let chatId = sqlite3_column_int64(stmt, 10)

            let service: String?
            if let servicePtr = sqlite3_column_text(stmt, 11) {
                service = String(cString: servicePtr)
            } else {
                service = nil
            }

            let account: String?
            if let accountPtr = sqlite3_column_text(stmt, 12) {
                account = String(cString: accountPtr)
            } else {
                account = nil
            }

            let subject: String?
            if let subjectPtr = sqlite3_column_text(stmt, 13) {
                subject = String(cString: subjectPtr)
            } else {
                subject = nil
            }

            let associatedMessageGuid: String?
            if let assocGuidPtr = sqlite3_column_text(stmt, 14) {
                associatedMessageGuid = String(cString: assocGuidPtr)
            } else {
                associatedMessageGuid = nil
            }

            let associatedMessageType: Int?
            if sqlite3_column_type(stmt, 15) != SQLITE_NULL {
                associatedMessageType = Int(sqlite3_column_int(stmt, 15))
            } else {
                associatedMessageType = nil
            }

            let threadOriginatorGuid: String?
            if let threadOriginatorPtr = sqlite3_column_text(stmt, 16) {
                threadOriginatorGuid = String(cString: threadOriginatorPtr)
            } else {
                threadOriginatorGuid = nil
            }

            let attachments = try fetchAttachments(db: db, messageRowId: rowId)

            return MessageData(
                rowId: rowId,
                guid: guid,
                text: text,
                attributedBody: attributedBody,
                handleId: handleId,
                date: date,
                dateRead: dateRead,
                dateDelivered: dateDelivered,
                isFromMe: isFromMe,
                isRead: isRead,
                chatId: chatId,
                service: service,
                account: account,
                attachments: attachments,
                subject: subject,
                associatedMessageGuid: associatedMessageGuid,
                associatedMessageType: associatedMessageType,
                threadOriginatorGuid: threadOriginatorGuid
            )
        }

        return nil
    }
    
    private func fetchThreads(db: OpaquePointer, messageIds: Set<Int64>) throws -> [ThreadData] {
        var threads: [ThreadData] = []
        
        // Return empty if no message IDs
        guard !messageIds.isEmpty else {
            return threads
        }
        
        let query = """
            SELECT c.ROWID, c.guid, c.chat_identifier, c.service_name, c.display_name
            FROM chat c
            WHERE c.ROWID IN (\(messageIds.map { String($0) }.joined(separator: ",")))
            """
        
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare thread query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare thread query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let guid = String(cString: sqlite3_column_text(stmt, 1))
            
            let chatIdentifier: String?
            if let idPtr = sqlite3_column_text(stmt, 2) {
                chatIdentifier = String(cString: idPtr)
            } else {
                chatIdentifier = nil
            }
            
            let serviceName: String?
            if let servicePtr = sqlite3_column_text(stmt, 3) {
                serviceName = String(cString: servicePtr)
            } else {
                serviceName = nil
            }
            
            let displayName: String?
            if let namePtr = sqlite3_column_text(stmt, 4) {
                displayName = String(cString: namePtr)
            } else {
                displayName = nil
            }
            
            // Fetch participants
            let participants = try fetchParticipants(db: db, chatRowId: rowId)
            let isGroup = participants.count > 1
            
            threads.append(ThreadData(
                rowId: rowId,
                guid: guid,
                chatIdentifier: chatIdentifier,
                serviceName: serviceName,
                displayName: displayName,
                participants: participants,
                isGroup: isGroup
            ))
        }
        
        return threads
    }

    // MARK: - Fence Management
    // Uses shared FenceManager from HavenCore

    // MARK: - State persistence for iMessage collector

    private func iMessageCacheDirURL() -> URL {
        // Use HavenFilePaths for state directory (fence state goes in State, not Cache)
        return HavenFilePaths.stateDirectory
    }

    private func iMessageCacheFileURL() -> URL {
        // State file goes in State directory
        return HavenFilePaths.stateFile("imessage_state.json")
    }

    private func loadIMessageState() throws -> [FenceRange] {
        let url = iMessageCacheFileURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let fences = try FenceManager.loadFences(from: data, oldFormatType: [String: Int64].self)
        if fences.isEmpty && !data.isEmpty {
            logger.info("Detected old iMessage state format, starting fresh with timestamp-based fences")
        }
        return fences
    }

    private func saveIMessageState(fences: [FenceRange]) throws {
        let url = iMessageCacheFileURL()
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try FenceManager.saveFences(fences)
        try data.write(to: url, options: .atomic)
    }
    
    // MARK: - Handler State Persistence
    
    private func handlerStateFileURL() -> URL {
        // Handler status goes in Caches directory
        return HavenFilePaths.cacheFile("imessage_handler_state.json")
    }
    
    private struct PersistedHandlerState: Codable {
        var lastRunTime: Date?
        var lastRunStatus: String
        var lastRunError: String?
        var lastRunStats: CollectorStats?
    }
    
    private func loadPersistedState() async {
        let url = handlerStateFileURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(PersistedHandlerState.self, from: data)
            
            lastRunTime = persisted.lastRunTime
            lastRunStatus = persisted.lastRunStatus
            lastRunError = persisted.lastRunError
            lastRunStats = persisted.lastRunStats
            
            logger.info("Loaded persisted iMessage handler state", metadata: [
                "lastRunStatus": lastRunStatus,
                "hasLastRunTime": lastRunTime != nil ? "true" : "false"
            ])
        } catch {
            logger.warning("Failed to load persisted iMessage handler state", metadata: ["error": error.localizedDescription])
        }
    }
    
    private func savePersistedState() async {
        let url = handlerStateFileURL()
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            
            let persisted = PersistedHandlerState(
                lastRunTime: lastRunTime,
                lastRunStatus: lastRunStatus,
                lastRunError: lastRunError,
                lastRunStats: lastRunStats
            )
            
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persisted)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("Failed to save persisted iMessage handler state", metadata: ["error": error.localizedDescription])
        }
    }

    // Compose processing order for message ROWIDs (ascending list input)
    private func composeProcessingOrder(
        searchResultAsc: [Int64],
        lastProcessedId: Int64?,
        order: String?,
        since: Date?,
        before: Date?,
        oldestCachedId: Int64? = nil
    ) -> [Int64] {
        let uidsSortedAsc = searchResultAsc.sorted()
        let normalizedOrder = order?.lowercased()

        // If the caller provides an explicit oldestCachedId, use that to
        // determine the cached range. Otherwise, fall back to treating all IDs <=
        // lastProcessedId as cached (best-effort given stored state only records
        // the most-recent ID).
        let cachedIds: [Int64]
        if let oldest = oldestCachedId, let last = lastProcessedId {
            cachedIds = uidsSortedAsc.filter { $0 >= oldest && $0 <= last }
        } else if let last = lastProcessedId {
            cachedIds = uidsSortedAsc.filter { $0 <= last }
        } else {
            cachedIds = []
        }
        let newerAsc = uidsSortedAsc.filter { id in
            if let last = lastProcessedId { return id > last }
            return true
        }

        if normalizedOrder == "desc" {
            // Process newer messages newest->oldest, then continue with older messages newest->oldest
            // This handles the case where new messages arrive after processing older ones.
            // Example: First run processes 100..91. New message 101 arrives.
            // Next run should process 101, then continue with 90..82.
            if let last = lastProcessedId {
                // Process new messages (ID > lastProcessedId) first, in descending order
                let newMessagesDesc = uidsSortedAsc
                    .filter { $0 > last }
                    .reversed()
                
                // Then continue with older messages (ID < oldestCachedId), in descending order
                // This allows us to resume processing from where we left off
                if let oldest = oldestCachedId {
                    let olderMessagesDesc = uidsSortedAsc
                        .filter { $0 < oldest }
                        .reversed()
                    return Array(newMessagesDesc) + Array(olderMessagesDesc)
                } else {
                    // No oldestCachedId: only process new messages
                    return Array(newMessagesDesc)
                }
            } else if let oldestCached = cachedIds.first {
                // No lastProcessedId but we have cached range: process newer messages and older than cache
                let newDesc = Array(newerAsc.reversed())
                let olderThanCacheDesc = Array(uidsSortedAsc.filter { $0 < oldestCached }.reversed())
                return newDesc + olderThanCacheDesc
            } else {
                // No cached ids: just return all in descending order
                return Array(uidsSortedAsc.reversed())
            }
        } else {
            // Ascending ordering: process messages in ascending order, skipping already-processed ones
            // to enable proper pagination across multiple runs.
            // If 'since' is provided, start from that date regardless of lastProcessedId,
            // as the user is explicitly specifying a new starting point.
            if since != nil {
                // User specified a date range starting point - process all messages in the result set
                // (which is already filtered by since date from fetchMessageRowIds)
                return uidsSortedAsc
            } else if let last = lastProcessedId {
                // No since date specified - continue from where we left off
                return uidsSortedAsc.filter { $0 > last }
            } else {
                return uidsSortedAsc
            }
        }
    }
    
    private func fetchParticipants(db: OpaquePointer, chatRowId: Int64) throws -> [String] {
        var participants: [String] = []
        
        let query = """
            SELECT h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            ORDER BY h.id
            """
        
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare participants query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare participants query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, chatRowId)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idPtr = sqlite3_column_text(stmt, 0) {
                participants.append(String(cString: idPtr))
            }
        }
        
        return participants
    }
    
    /// Fetch the handle identifier (phone number, email, etc.) for a given handle row ID
    /// This is used to determine the actual sender of received messages
    private func fetchHandleById(db: OpaquePointer, handleId: Int64) -> String? {
        let query = """
            SELECT h.id
            FROM handle h
            WHERE h.ROWID = ?
            """
        
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare handle query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, handleId)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let idPtr = sqlite3_column_text(stmt, 0) {
                return String(cString: idPtr)
            }
        }
        
        return nil
    }
    
    
    private func fetchAttachments(db: OpaquePointer, messageRowId: Int64) throws -> [AttachmentData] {
        var attachments: [AttachmentData] = []
        
        let query = """
            SELECT a.ROWID, a.guid, a.filename, a.mime_type, a.total_bytes, a.uti
            FROM message_attachment_join maj
            JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE maj.message_id = ?
            """
        
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare attachments query", metadata: ["error": errorMsg, "code": String(prepareResult)])
            throw CollectorError.queryFailed("Failed to prepare attachments query: \(errorMsg) (code: \(prepareResult))")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, messageRowId)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let guid = String(cString: sqlite3_column_text(stmt, 1))
            
            let filename: String?
            if let filenamePtr = sqlite3_column_text(stmt, 2) {
                filename = String(cString: filenamePtr)
            } else {
                filename = nil
            }
            
            let mimeType: String?
            if let mimePtr = sqlite3_column_text(stmt, 3) {
                mimeType = String(cString: mimePtr)
            } else {
                mimeType = nil
            }
            
            let totalBytes = sqlite3_column_int64(stmt, 4)
            
            let uti: String?
            if let utiPtr = sqlite3_column_text(stmt, 5) {
                uti = String(cString: utiPtr)
            } else {
                uti = nil
            }
            
            attachments.append(AttachmentData(
                rowId: rowId,
                guid: guid,
                filename: filename,
                mimeType: mimeType,
                totalBytes: totalBytes,
                uti: uti
            ))
        }
        
        return attachments
    }
    
    // MARK: - Reaction and Reply Handling
    
    /// Mapping of iMessage reaction types (associated_message_type) to emoji
    private let reactionEmojiMap: [Int: String] = [
        2000: "❤️",   // Love
        2001: "👍",   // Like
        2002: "👎",   // Dislike
        2003: "🤣",   // Laugh
        2004: "‼️",   // Emphasize (exclamation)
        2005: "❓"    // Question
    ]
    
    /// Check if a message is a reaction/tapback (associated_message_type 2000-2005)
    private func isReactionMessage(message: MessageData) -> Bool {
        guard let msgType = message.associatedMessageType else { return false }
        return msgType >= 2000 && msgType <= 2005
    }
    
    /// Check if a message is a sticker (associated_message_type 1000)
    private func isStickerMessage(message: MessageData) -> Bool {
        return message.associatedMessageType == 1000
    }
    
    /// Extract the actual message GUID from associated_message_guid format
    /// iMessage stores associated_message_guid in various formats:
    /// - "p:0/{guid}" or "p:1/{guid}" etc. - participant/platform format with slash (most common)
    /// - "bp:0{guid}" or "bp:1{guid}" etc. - binary participant format without slash (hex digits)
    /// - "{guid}" - direct GUID reference (no prefix)
    /// The actual message guid in the database is just "{guid}" without any prefix
    private func extractMessageGuid(from associatedGuid: String) -> String {
        // Handle "p:X/" format (e.g., "p:0/", "p:1/", "p:2/", etc.)
        if associatedGuid.hasPrefix("p:") {
            // Find the first "/" after "p:"
            if let slashIndex = associatedGuid.firstIndex(of: "/") {
                let guidStartIndex = associatedGuid.index(after: slashIndex)
                return String(associatedGuid[guidStartIndex...])
            }
            // Handle "p:X" format without slash (e.g., "p:10", "p:11")
            // This is less common but we should handle it
            if let colonIndex = associatedGuid.firstIndex(of: ":"), 
               let nextChar = associatedGuid.index(colonIndex, offsetBy: 1, limitedBy: associatedGuid.endIndex) {
                // Check if there's a digit after "p:" - if so, skip it and any following digits
                var guidStartIndex = nextChar
                while guidStartIndex < associatedGuid.endIndex && associatedGuid[guidStartIndex].isNumber {
                    guidStartIndex = associatedGuid.index(after: guidStartIndex)
                }
                if guidStartIndex < associatedGuid.endIndex {
                    return String(associatedGuid[guidStartIndex...])
                }
            }
        }
        
        // Handle "bp:X" format (e.g., "bp:0", "bp:1", "bp:A", etc.)
        // These are hexadecimal digits, so we need to skip "bp:" plus one hex character
        if associatedGuid.hasPrefix("bp:") {
            // Skip "bp:" (3 chars) plus one hex character (1 char) = 4 chars total
            let guidStartIndex = associatedGuid.index(associatedGuid.startIndex, offsetBy: 4)
            if guidStartIndex < associatedGuid.endIndex {
                return String(associatedGuid[guidStartIndex...])
            }
        }
        
        // If no recognized prefix, return as-is (might be a direct GUID)
        return associatedGuid
    }
    
    /// Get the text of the message a reaction is reacting to
    private func getReactionTargetText(db: OpaquePointer?, guid: String) -> String? {
        guard let db = db else {
            logger.debug("Cannot lookup reaction target: database is nil", metadata: [
                "target_guid": guid
            ])
            return nil
        }
        
        // Extract the actual GUID by stripping the "p:0/" or "p:1/" prefix if present
        let actualGuid = extractMessageGuid(from: guid)
        
        let query = """
            SELECT m.text, m.attributedBody FROM message m WHERE m.guid = ? LIMIT 1
            """
        
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            logger.warning("Failed to prepare query for reaction target lookup", metadata: [
                "target_guid": guid,
                "actual_guid": actualGuid,
                "sqlite_error": String(prepareResult)
            ])
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        // Bind the actual GUID parameter (without prefix)
        sqlite3_bind_text(stmt, 1, actualGuid, -1, unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
        
        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_ROW {
            let text: String?
            if let textPtr = sqlite3_column_text(stmt, 0) {
                text = String(cString: textPtr)
            } else {
                text = nil
            }
            
            // If there's text, return it truncated
            if let t = text, !t.isEmpty {
                let truncated = String(t.prefix(50))
                logger.debug("Found reaction target text from text field", metadata: [
                    "target_guid": guid,
                    "actual_guid": actualGuid,
                    "text_length": String(t.count),
                    "truncated_length": String(truncated.count)
                ])
                return truncated
            }
            
            // Try attributed body
            if sqlite3_column_type(stmt, 1) == SQLITE_BLOB {
                if let bytes = sqlite3_column_blob(stmt, 1) {
                    let count = sqlite3_column_bytes(stmt, 1)
                    let data = Data(bytes: bytes, count: Int(count))
                    if let decoded = decodeAttributedBody(data), !decoded.isEmpty {
                        let truncated = String(decoded.prefix(50))
                        logger.debug("Found reaction target text from attributedBody", metadata: [
                            "target_guid": guid,
                            "actual_guid": actualGuid,
                            "text_length": String(decoded.count),
                            "truncated_length": String(truncated.count)
                        ])
                        return truncated
                    } else {
                        logger.debug("Reaction target has attributedBody but decoding failed or returned empty", metadata: [
                            "target_guid": guid,
                            "actual_guid": actualGuid,
                            "attributed_body_size": String(count)
                        ])
                    }
                }
            } else {
                logger.debug("Reaction target message found but has no text or attributedBody", metadata: [
                    "target_guid": guid,
                    "actual_guid": actualGuid,
                    "has_text": text != nil ? "true" : "false",
                    "text_empty": text?.isEmpty ?? true ? "true" : "false"
                ])
            }
        } else if stepResult == SQLITE_DONE {
            // No row found - message doesn't exist in database
            logger.debug("Reaction target message not found in database", metadata: [
                "target_guid": guid,
                "actual_guid": actualGuid
            ])
        } else {
            logger.warning("Error executing query for reaction target lookup", metadata: [
                "target_guid": guid,
                "actual_guid": actualGuid,
                "sqlite_error": String(stepResult)
            ])
        }
        
        return nil
    }
    
    /// Build reaction text like "Reacted 👍 to: <first 50 characters of the message that was reacted to>"
    private func buildReactionText(emoji: String, targetText: String?) -> String {
        if let target = targetText, !target.isEmpty {
            return "Reacted \(emoji) to: \(target)"
        } else {
            return "Reacted \(emoji)"
        }
    }
    
    /// Get parent message text for thread replies (when user taps "Reply")
    private func getThreadParentText(db: OpaquePointer?, guid: String) -> String? {
        // Same implementation as getReactionTargetText since it just fetches message text
        return getReactionTargetText(db: db, guid: guid)
    }
    
    // MARK: - Document Building
    
    private func isMessageEmpty(message: MessageData) -> Bool {
        // Check if message has text
        let hasText = !(message.text?.isEmpty ?? true)
        
        // Check if message has attributed body with decodable text
        // We need to actually decode it to verify it contains valid text, not just check existence
        var hasAttributedBodyText = false
        if let attrBody = message.attributedBody, attrBody.count > 0 {
            // Try to decode the attributed body to see if it contains valid text
            if let decodedText = decodeAttributedBody(attrBody), !decodedText.isEmpty {
                hasAttributedBodyText = true
            }
        }
        
        // Check if message has attachments
        let hasAttachments = !message.attachments.isEmpty
        
        // Check if message is a reaction (these are handled in buildDocument and converted to readable format)
        let isReaction = isReactionMessage(message: message)
        
        // Message is empty if it has no text, no decodable attributed body text, and no attachments
        // Note: We decode attributedBody here to ensure we don't filter out messages that have
        // text only in attributedBody. Some messages (especially short ones like "545" or "Yup")
        // may only have text in attributedBody, not in the text field.
        // 
        // Note: Messages with subject/associated_message_guid (reactions) are handled in buildDocument
        // and converted to readable format (e.g., "Reacted 👍 to <original message>"), so we don't
        // filter them here to avoid bypassing that conversion logic.
        return !hasText && !hasAttributedBodyText && !hasAttachments && !isReaction
    }
    
    /// Build document with enrichment support using new architecture
    private func buildDocumentWithEnrichment(
        message: MessageData,
        thread: ThreadData,
        attachments: [[String: Any]],
        db: OpaquePointer?
    ) async throws -> [String: Any]? {
        // First build the base document dictionary
        let baseDocument = try buildDocument(message: message, thread: thread, attachments: attachments, db: db)
        let sourceId = baseDocument["source_id"] as? String ?? "unknown"
        
        // If enrichment is skipped, return base document
        if skipEnrichment {
            logger.debug("buildDocumentWithEnrichment: enrichment skipped", metadata: ["source_id": sourceId])
            return baseDocument
        }
        
        // Use new architecture enrichment if orchestrator is available
        if let orchestrator = enrichmentOrchestrator {
            logger.debug("buildDocumentWithEnrichment: starting enrichment", metadata: [
                "source_id": sourceId,
                "attachment_count": String(attachments.count)
            ])
            
            // Convert message to CollectorDocument format for enrichment
            let collectorDocument = try convertToCollectorDocument(
                message: message,
                thread: thread,
                baseDocument: baseDocument
            )
            
            logger.debug("buildDocumentWithEnrichment: CollectorDocument created", metadata: [
                "source_id": sourceId,
                "image_count": String(collectorDocument.images.count)
            ])
            
            // Enrich using orchestrator
            let enrichedDocument = try await orchestrator.enrich(collectorDocument)
            
            logger.debug("buildDocumentWithEnrichment: enrichment completed", metadata: [
                "source_id": sourceId,
                "image_enrichments_count": String(enrichedDocument.imageEnrichments.count),
                "has_document_enrichment": enrichedDocument.documentEnrichment != nil
            ])
            
            // If submitter is available (e.g., debug mode), submit directly and return nil to skip HTTP posting
            if let submitter = submitter {
                do {
                    _ = try await submitter.submit(enrichedDocument)
                    logger.debug("Submitted document via submitter", metadata: [
                        "source_id": enrichedDocument.base.externalId
                    ])
                    // Return nil to indicate this was submitted via submitter and shouldn't be posted via HTTP
                    return nil
                } catch {
                    logger.error("Failed to submit document via submitter", metadata: [
                        "source_id": enrichedDocument.base.externalId,
                        "error": error.localizedDescription
                    ])
                    // Fall through to merge and post via HTTP as fallback
                }
            }
            
            // Merge enrichment data into dictionary document for HTTP posting
            let mergedDocument = mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
            let contentText = (mergedDocument["content"] as? [String: Any])?["data"] as? String ?? ""
            logger.debug("buildDocumentWithEnrichment: enrichment merged into document", metadata: [
                "source_id": sourceId,
                "has_captions": String(contentText.contains("[Image:"))
            ])
            return mergedDocument
        }
        
        logger.debug("buildDocumentWithEnrichment: no orchestrator available", metadata: ["source_id": sourceId])
        // Fallback to base document if no orchestrator
        return baseDocument
    }
    
    /// Convert iMessage data to CollectorDocument format for enrichment
    private func convertToCollectorDocument(
        message: MessageData,
        thread: ThreadData,
        baseDocument: [String: Any]
    ) throws -> CollectorDocument {
        // Extract content from base document
        let content = (baseDocument["content"] as? [String: Any])?["data"] as? String ?? ""
        let contentHash = sha256(content)
        
        // Extract timestamp
        let contentTimestampStr = baseDocument["content_timestamp"] as? String ?? ""
        let contentTimestamp = ISO8601DateFormatter().date(from: contentTimestampStr) ?? Date()
        
        // Extract images from attachments (for enrichment)
        // Attachments are stored in metadata.attachments in the new schema
        var images: [ImageAttachment] = []
        let metadata = baseDocument["metadata"] as? [String: Any] ?? [:]
        if let attachments = metadata["attachments"] as? [[String: Any]] {
            logger.info("convertToCollectorDocument: found attachments in metadata", metadata: [
                "attachment_count": String(attachments.count),
                "source_id": baseDocument["source_id"] as? String ?? "unknown"
            ])
            for attachment in attachments {
                let filename = attachment["source_ref"] as? [String: Any] ?? [:]
                let path = filename["path"] as? String ?? ""
                let mimeType = attachment["mime_type"] as? String
                logger.debug("Processing attachment from metadata", metadata: [
                    "path": path,
                    "mime_type": mimeType ?? "nil",
                    "is_image": String(isImageAttachment(filename: path, mimeType: mimeType))
                ])
                
                // Check if this is an image attachment
                if isImageAttachment(filename: path, mimeType: mimeType) {
                    // Use path from source_ref (it's the file path in iMessage database)
                    if !path.isEmpty {
                        // Expand tilde in path
                        let expandedPath = NSString(string: path).expandingTildeInPath
                        let fileExists = FileManager.default.fileExists(atPath: expandedPath)
                        
                        logger.debug("Image attachment check", metadata: [
                            "path": path,
                            "expanded_path": expandedPath,
                            "file_exists": String(fileExists)
                        ])
                        
                        // Verify file exists before adding to images
                        if fileExists {
                            let imageAttachment = ImageAttachment(
                                hash: (filename["message_attachment_id"] as? String) ?? UUID().uuidString,
                                mimeType: mimeType ?? "image/jpeg",
                                temporaryPath: expandedPath,
                                temporaryData: nil
                            )
                            images.append(imageAttachment)
                            logger.info("Added image to enrichment", metadata: [
                                "path": path,
                                "hash": imageAttachment.hash
                            ])
                        } else {
                            logger.warning("Image file not found", metadata: [
                                "path": path,
                                "expanded_path": expandedPath
                            ])
                        }
                    }
                }
            }
        } else {
            logger.debug("convertToCollectorDocument: no attachments found in metadata", metadata: [
                "source_id": baseDocument["source_id"] as? String ?? "unknown"
            ])
        }
        
        logger.debug("convertToCollectorDocument completed", metadata: [
            "source_id": baseDocument["source_id"] as? String ?? "unknown",
            "image_count": String(images.count)
        ])
        
        return CollectorDocument(
            content: content,
            sourceType: "imessage",
            externalId: baseDocument["source_id"] as? String ?? "",
            metadata: DocumentMetadata(
                contentHash: contentHash,
                mimeType: "text/plain",
                timestamp: contentTimestamp,
                timestampType: baseDocument["content_timestamp_type"] as? String ?? "received",
                createdAt: contentTimestamp,
                modifiedAt: contentTimestamp
            ),
            images: images,
            contentType: .imessage,
            title: baseDocument["title"] as? String ?? "",
            canonicalUri: baseDocument["external_id"] as? String
        )
    }
    
    /// Merge enrichment data from EnrichedDocument into dictionary document
    /// Uses shared EnrichmentMerger utility to apply uniform enrichment strategy across all collectors
    private func mergeEnrichmentIntoDocument(
        _ baseDocument: [String: Any],
        _ enrichedDocument: EnrichedDocument
    ) -> [String: Any] {
        let attachments = baseDocument["attachments"] as? [[String: Any]]
        return EnrichmentMerger.mergeEnrichmentIntoDocument(baseDocument, enrichedDocument, imageAttachments: attachments)
    }
    
    /// Add completed enrichment to the completion queue
    private func addEnrichmentCompletion(documentId: String, enrichedDocument: EnrichedDocument?) {
        if let enriched = enrichedDocument {
            enrichmentCompletions[documentId] = .success(enriched)
        } else {
            logger.warning("Enrichment failed; using base document", metadata: [
                "document_id": documentId
            ])
            enrichmentCompletions[documentId] = .failure
        }
    }
    
    /// Sync submission counts from submitter if available
    /// The submitter tracks counts internally and may flush automatically, so we need to sync periodically
    private func syncSubmitterStats(submittedCount: inout Int, errorCount: inout Int) async {
        if let submitter = submitter {
            let stats = await submitter.getStats()
            submittedCount = stats.submittedCount
            errorCount = stats.errorCount
        }
    }
    
    /// Process completed enrichments and add them to batches
    /// Returns: (processedCount, enrichedCount) - number of documents processed and newly enriched
    private func processEnrichmentCompletions(
        pendingEnrichments: inout [String: ([String: Any], Date, CollectorDocument)],
        currentBatch: inout [[String: Any]],
        currentBatchTimestamps: inout [Date],
        allDocuments: inout [[String: Any]],
        stats: inout CollectorStats,
        submittedCount: inout Int,
        successfulSubmissionTimestamps: inout [Date]
    ) async -> (Int, Int) {
        var processedCount = 0
        var newlyEnriched = 0
        // Find completions that match pending enrichments
        let completedIds = Set(enrichmentCompletions.keys).intersection(Set(pendingEnrichments.keys))
        
        for documentId in completedIds {
            guard let (baseDocument, messageDate, _) = pendingEnrichments[documentId],
                  let completion = enrichmentCompletions[documentId] else {
                continue
            }
            
            // If submitter is available and enrichment succeeded, submit via submitter
            // This matches the behavior in buildDocumentWithEnrichment
            // The submitter tracks counts internally - we'll get stats when flushing/finishing
            if let submitter = submitter, case .success(let enrichedDocument) = completion {
                do {
                    _ = try await submitter.submit(enrichedDocument)
                    // Track timestamp for successful submission via submitter
                    // This ensures fence updates include all successfully submitted documents,
                    // not just those in the final batch flush
                    successfulSubmissionTimestamps.append(messageDate)
                    logger.debug("Submitted document via submitter from enrichment queue", metadata: [
                        "document_id": documentId,
                        "source_id": enrichedDocument.base.externalId
                    ])
                    // Document was submitted via submitter, but we still need to add it to the batch
                    // for progress tracking and fence updates. The HTTP posting will be skipped
                    // if documents were already submitted via submitter (handled in postDocumentsToGateway).
                    // Counts are tracked by the submitter and retrieved via getStats() or finish().
                } catch {
                    logger.error("Failed to submit document via submitter from enrichment queue", metadata: [
                        "document_id": documentId,
                        "source_id": enrichedDocument.base.externalId,
                        "error": error.localizedDescription
                    ])
                    // Fall through to add to batch for HTTP posting as fallback
                }
            }
            
            let documentToAppend: [String: Any]
            switch completion {
            case .success(let enrichedDocument):
                documentToAppend = mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
            case .failure:
                documentToAppend = baseDocument
            }
            
            // Add to batch
            currentBatch.append(documentToAppend)
            currentBatchTimestamps.append(messageDate)
            allDocuments.append(documentToAppend)
            stats.documentsCreated += 1
            
            // Remove from pending and completions
            pendingEnrichments.removeValue(forKey: documentId)
            enrichmentCompletions.removeValue(forKey: documentId)
            
            processedCount += 1
            if completion.isSuccess {
                newlyEnriched += 1
            }
            
            logger.debug("Processed completed enrichment", metadata: [
                "document_id": documentId,
                "completion_state": completion.isSuccess ? "success" : "failure"
            ])
        }
        
        return (processedCount, newlyEnriched)
    }
    
    /// Perform synchronous enrichment when the shared queue is unavailable
    /// Returns enriched document dictionary ready for batch submission
    private func enrichDocumentSynchronously(
        baseDocument: [String: Any],
        collectorDocument: CollectorDocument
    ) async throws -> [String: Any] {
        // If enrichment is skipped or no orchestrator, return base document
        guard !skipEnrichment, let orchestrator = enrichmentOrchestrator else {
            return baseDocument
        }
        
        let enrichedDocument = try await orchestrator.enrich(collectorDocument)
        return mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
    }
    
    
    private func buildDocument(message: MessageData, thread: ThreadData, attachments: [[String: Any]], db: OpaquePointer?) throws -> [String: Any] {
        // Extract message text, handling reactions and thread replies
        var messageText = message.text ?? ""
        if messageText.isEmpty, let attrBody = message.attributedBody {
            messageText = decodeAttributedBody(attrBody) ?? ""
        }
        
        // Handle reactions (tapbacks)
        if isReactionMessage(message: message) {
            let emoji = reactionEmojiMap[message.associatedMessageType ?? 0] ?? "👍"
            if let targetGuid = message.associatedMessageGuid {
                let targetText = getReactionTargetText(db: db, guid: targetGuid)
                if targetText == nil {
                    logger.warning("Reaction message missing target text", metadata: [
                        "message_guid": message.guid,
                        "target_guid": targetGuid,
                        "emoji": emoji
                    ])
                }
                messageText = buildReactionText(emoji: emoji, targetText: targetText)
            } else {
                logger.warning("Reaction message missing associatedMessageGuid", metadata: [
                    "message_guid": message.guid,
                    "emoji": emoji
                ])
                messageText = buildReactionText(emoji: emoji, targetText: nil)
            }
        }
        // Handle threaded replies (when user taps "Reply" on a message)
        else if let threadParentGuid = message.threadOriginatorGuid, !threadParentGuid.isEmpty {
            let parentText = getThreadParentText(db: db, guid: threadParentGuid)
            if let parent = parentText, !parent.isEmpty {
                if !messageText.isEmpty {
                    messageText = "Replied to \"\(parent)\" with: \(messageText)"
                } else if !attachments.isEmpty {
                    messageText = "Replied to \"\(parent)\" with attachment(s)"
                } else {
                    messageText = "Replied to \"\(parent)\""
                }
            }
        }
        
        // Safety check: if message is still empty after extraction, log warning
        // (This shouldn't happen since we filter empty messages earlier)
        // Note: Messages with attachments but no text are valid (image-only messages, etc.)
        if messageText.isEmpty && attachments.isEmpty {
            logger.warning("Empty message reached buildDocument (should have been filtered earlier)", metadata: [
                "message_guid": message.guid
            ])
            // Use a minimal placeholder - this case should be rare
            messageText = "[empty message - filtering check missed]"
        }
        
        // Format timestamps
        // Use canonical timestamp: message.date (the message's primary timestamp)
        // This is stored as content_timestamp in the document and used for all time-based operations
        let contentTimestamp = appleEpochToISO8601(message.date)
        let contentTimestampType = message.isFromMe ? "sent" : "received"
        let ingestionTimestamp = ISO8601DateFormatter().string(from: Date())
        
        // Extract source_account_id from message account
        let sourceAccountId = message.account
        
        // Build timestamp metadata structure
        var sourceSpecificTimestamps: [String: Any] = [:]
        sourceSpecificTimestamps["sent_at"] = appleEpochToISO8601(message.date)
        if let dateRead = message.dateRead {
            sourceSpecificTimestamps["received_at"] = appleEpochToISO8601(dateRead)
        } else if !message.isFromMe {
            // For received messages, use date as received_at if dateRead is not available
            sourceSpecificTimestamps["received_at"] = contentTimestamp
        }
        if let dateDelivered = message.dateDelivered {
            sourceSpecificTimestamps["delivered_at"] = appleEpochToISO8601(dateDelivered)
        }
        
        let timestampsMetadata: [String: Any] = [
            "primary": [
                "value": contentTimestamp,
                "type": contentTimestampType
            ],
            "source_specific": sourceSpecificTimestamps
        ]
        
        // Build people array
        // When isFromMe, use the message account (your iMessage account) as the sender
        // When received, use the handle_id to look up the actual sender instead of assuming it's the first participant
        var senderIdentifier: String = "me"
        if message.isFromMe {
            senderIdentifier = message.account ?? "me"
        } else {
            // Try to look up the actual sender using the message's handle_id
            if let db = db, let handleIdentifier = fetchHandleById(db: db, handleId: message.handleId) {
                senderIdentifier = handleIdentifier
            } else {
                // Fallback to first participant if handle lookup fails
                senderIdentifier = thread.participants.first ?? "unknown"
            }
        }
        let people = buildPeople(sender: senderIdentifier, participants: thread.participants, isFromMe: message.isFromMe)
        
        // Build thread payload with source_account_id
        let threadExternalId = "imessage:\(thread.guid)"
        var threadPayload: [String: Any] = [
            "external_id": threadExternalId,
            "source_type": "imessage",
            "source_provider": "apple_messages",
            "title": thread.displayName ?? thread.chatIdentifier ?? "Unknown",
            "participants": thread.participants.map { identifier in
                [
                    "identifier": identifier,
                    "identifier_type": inferIdentifierType(identifier),
                    "role": "participant"
                ]
            },
            "thread_type": thread.isGroup ? "group" : "direct",
            "is_group": thread.isGroup,
            "participant_count": thread.participants.count,
            "metadata": [
                "chat_guid": thread.guid
            ],
            "last_message_at": contentTimestamp
        ]
        if let accountId = sourceAccountId {
            threadPayload["source_account_id"] = accountId
        }
        
        // Restructure attachments to new schema format
        var structuredAttachments: [[String: Any]] = []
        for (index, attachment) in attachments.enumerated() {
            var structuredAttachment: [String: Any] = [
                "index": index,
                "kind": inferAttachmentKind(mimeType: attachment["mime_type"] as? String, filename: attachment["filename"] as? String),
                "role": "attachment",
                "mime_type": attachment["mime_type"] as? String ?? "application/octet-stream",
                "size_bytes": attachment["size_bytes"] as? Int64 ?? 0
            ]
            
            // Build source_ref
            var sourceRef: [String: Any] = [:]
            if let guid = attachment["guid"] as? String {
                sourceRef["message_attachment_id"] = guid
            }
            if let filename = attachment["filename"] as? String, !filename.isEmpty {
                sourceRef["path"] = filename
            }
            if let rowId = attachment["row_id"] as? Int64 {
                sourceRef["row_id"] = rowId
            }
            if !sourceRef.isEmpty {
                structuredAttachment["source_ref"] = sourceRef
            }
            
            // Add id/filename/path for image attachments to support token replacement later
            if let kind = structuredAttachment["kind"] as? String, kind == "image" {
                if let path = sourceRef["path"] as? String, !path.isEmpty {
                    let basename = (path as NSString).lastPathComponent
                    structuredAttachment["id"] = path   // use canonical file path as id
                    structuredAttachment["filename"] = basename
                    structuredAttachment["path"] = path
                }
            }
            
            structuredAttachments.append(structuredAttachment)
        }
        
        // Build metadata with new structure
        var metadata: [String: Any] = [
            "timestamps": timestampsMetadata,
            "source": [
                "imessage": [
                    "chat_guid": thread.guid,
                    "handle_id": message.handleId,
                    "service": message.service ?? "iMessage",
                    "row_id": message.rowId
        ]
            ],
            "type": [
                "kind": "imessage",
                "imessage": [
                    "direction": message.isFromMe ? "outgoing" : "incoming",
                    "is_group": thread.isGroup
                ]
            ],
            "extraction": [
                "collector_name": "imessage",
                "collector_version": "1.0.0",
                "hostagent_modules": enrichmentOrchestrator != nil ? ["ocr", "entities", "faces", "caption"] : []
            ]
        ]
        
        // Add attachments to metadata if present
        if !structuredAttachments.isEmpty {
            metadata["attachments"] = structuredAttachments
        }
        
        // Replace inline object replacement characters (U+FFFC) with image tokens {IMG:<id>}
        // Preserve positional context: one token per inline image occurrence, extras appended at end
        // Also handle image-only messages (no text) by adding image tokens
        do {
            let imageIds: [String] = structuredAttachments.compactMap { att in
                guard let kind = att["kind"] as? String, kind == "image" else { return nil }
                return att["id"] as? String
            }
            
            if !imageIds.isEmpty {
                let objChar = "\u{FFFC}"
                if messageText.contains(objChar) {
                    // Replace object replacement chars with image tokens
                    let parts = messageText.components(separatedBy: objChar)
                    var rebuilt = ""
                    let insertCount = min(max(parts.count - 1, 0), imageIds.count)
                    for i in 0..<parts.count {
                        rebuilt.append(parts[i])
                        if i < insertCount {
                            let token = "{IMG:\(imageIds[i])}"
                            rebuilt.append(token)
                        }
                    }
                    // If there are more images than object replacement chars, append tokens at end
                    if imageIds.count > insertCount {
                        let remaining = imageIds[insertCount...]
                        let tailTokens = remaining.map { "{IMG:\($0)}" }.joined(separator: "\n")
                        if !tailTokens.isEmpty {
                            if rebuilt.isEmpty {
                                rebuilt = tailTokens
                            } else {
                                rebuilt.append("\n")
                                rebuilt.append(tailTokens)
                            }
                        }
                    }
                    messageText = rebuilt
                } else if messageText.isEmpty || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Image-only message: add image tokens to ensure document has text content
                    // This ensures enrichment can add placeholders and gateway won't reject empty text
                    let imageTokens = imageIds.map { "{IMG:\($0)}" }.joined(separator: "\n")
                    messageText = imageTokens
                    logger.debug("Added image tokens to image-only message", metadata: [
                        "message_guid": message.guid,
                        "image_count": String(imageIds.count)
                    ])
                }
            }
        }
        
        // Build document
        let documentId = "imessage:\(message.guid)"
        let textSha256 = sha256(messageText)
        
        var document: [String: Any] = [
            "idempotency_key": "\(documentId):\(textSha256)",
            "source_type": "imessage",
            "source_provider": "apple_messages",
            "source_id": documentId,
            "external_id": documentId,
            "title": thread.displayName ?? thread.chatIdentifier ?? "iMessage Thread",
            "content": [
                "mime_type": "text/plain",
                "data": messageText
            ],
            "metadata": metadata,
            "content_timestamp": contentTimestamp,
            "content_timestamp_type": contentTimestampType,
            "people": people,
            "thread": threadPayload,
            "facet_overrides": [
                "has_attachments": !structuredAttachments.isEmpty,
                "attachment_count": structuredAttachments.count
            ]
        ]
        
        // Add source_account_id if available
        if let accountId = sourceAccountId {
            document["source_account_id"] = accountId
        }
        
        return document
    }
    
    private func buildPeople(sender: String, participants: [String], isFromMe: Bool) -> [[String: Any]] {
        var people: [[String: Any]] = []
        
        // When isFromMe is true, sender will be the account email (e.g., "E:mrwhistler@gmail.com")
        // When isFromMe is false, sender is the handle identifier looked up from the message's handle_id
        if isFromMe {
            // For messages we sent, add the account as the sender
            if !sender.isEmpty && sender != "me" {
                people.append([
                    "identifier": sender,
                    "identifier_type": inferIdentifierType(sender),
                    "role": "sender"
                ])
            } else {
                // Fallback to "me" if account not available
                people.append([
                    "identifier": "me",
                    "identifier_type": "imessage",
                    "role": "sender"
                ])
            }
        } else if !sender.isEmpty && sender != "unknown" {
            // For messages we received, add the sender (first participant) as the sender
            people.append([
                "identifier": sender,
                "identifier_type": inferIdentifierType(sender),
                "role": "sender"
            ])
        }
        
        // Add all participants as recipients (excluding the sender)
        for participant in participants where participant != sender {
            people.append([
                "identifier": participant,
                "identifier_type": inferIdentifierType(participant),
                "role": "recipient"
            ])
        }
        
        return people
    }
    
    private func inferAttachmentKind(mimeType: String?, filename: String?) -> String {
        // Check mime type first
        if let mime = mimeType {
            if mime.hasPrefix("image/") {
                return "image"
            }
            if mime == "application/pdf" {
                return "pdf"
            }
        }
        
        // Check filename extension as fallback
        if let filename = filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            let imageExts = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "heif", "webp"]
            if imageExts.contains(ext) {
                return "image"
            }
            if ext == "pdf" {
                return "pdf"
            }
        }
        
        return "file"
    }
    
    private func inferIdentifierType(_ identifier: String) -> String {
        let cleaned = identifier.trimmingCharacters(in: .whitespaces)
        
        // Check for phone number
        if cleaned.hasPrefix("+") && cleaned.dropFirst().allSatisfy({ $0.isNumber || $0.isWhitespace }) {
            return "phone"
        }
        
        let digits = cleaned.filter { $0.isNumber }
        if !digits.isEmpty && abs(digits.count - cleaned.count) <= 2 {
            return "phone"
        }
        
        // Check for email
        if cleaned.contains("@") {
            return "email"
        }
        
        return "imessage"
    }
    
    // MARK: - Attachment Enrichment
    
    private func enrichAttachments(_ attachments: [AttachmentData], db: OpaquePointer) async throws -> [[String: Any]] {
        var enriched: [[String: Any]] = []
        
        for attachment in attachments {
            var attachmentDict: [String: Any] = [
                "row_id": attachment.rowId,
                "guid": attachment.guid,
                "mime_type": attachment.mimeType ?? "application/octet-stream",
                "size_bytes": attachment.totalBytes
            ]
            
            if let filename = attachment.filename {
                attachmentDict["filename"] = filename
                
                // Check if it's an image and should be enriched
                if isImageAttachment(filename: filename, mimeType: attachment.mimeType) {
                    if let enrichedImage = try await enrichImageAttachment(path: filename, attachment: attachment) {
                        attachmentDict["image"] = enrichedImage
                    }
                }
            }
            
            enriched.append(attachmentDict)
        }
        
        return enriched
    }
    
    private func isImageAttachment(filename: String, mimeType: String?) -> Bool {
        let imageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".tiff", ".tif", ".bmp", ".webp"]
        let ext = (filename as NSString).pathExtension.lowercased()
        
        if imageExtensions.contains(".\(ext)") {
            return true
        }
        
        if let mime = mimeType, mime.hasPrefix("image/") {
            return true
        }
        
        return false
    }
    
    private func enrichImageAttachment(path: String, attachment: AttachmentData) async throws -> [String: Any]? {
        guard let ocrService = ocrService else {
            return nil
        }
        
        // Expand tilde in path
        let expandedPath = NSString(string: path).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.warning("Image attachment not found", metadata: ["path": expandedPath])
            return nil
        }
        
        do {
            let imageData = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
            
            // Perform OCR
            let ocrResult = try await ocrService.processImage(data: imageData, recognitionLevel: nil, includeLayout: nil)
            
            var imageDict: [String: Any] = [
                "ocr_text": ocrResult.ocrText
            ]
            
            // Calculate average confidence from boxes if available
            if !ocrResult.ocrBoxes.isEmpty {
                let confidenceSum = ocrResult.ocrBoxes.compactMap { $0.confidence }.reduce(0.0, +)
                let confidenceCount = ocrResult.ocrBoxes.compactMap { $0.confidence }.count
                if confidenceCount > 0 {
                    imageDict["ocr_confidence"] = confidenceSum / Float(confidenceCount)
                }
            }
            
            // Extract entities from OCR text if available
            if let entityService = entityService, !ocrResult.ocrText.isEmpty {
                let entityResult = try await entityService.extractEntities(from: ocrResult.ocrText)
                
                var entitiesDict: [String: [String]] = [:]
                for entity in entityResult.entities {
                    if entitiesDict[entity.type.rawValue] == nil {
                        entitiesDict[entity.type.rawValue] = []
                    }
                    entitiesDict[entity.type.rawValue]?.append(entity.text)
                }
                
                if !entitiesDict.isEmpty {
                    imageDict["ocr_entities"] = entitiesDict
                }
            }
            
            // Add facets
            imageDict["facets"] = buildImageFacets(ocrResult: ocrResult)
            
            return imageDict
            
        } catch {
            logger.error("Failed to enrich image attachment", metadata: [
                "path": expandedPath,
                "error": error.localizedDescription
            ])
            return nil
        }
    }
    
    private func buildImageFacets(ocrResult: OCRResult) -> [String: Any] {
        var facets: [String: Any] = [:]
        
        facets["has_ocr_text"] = !ocrResult.ocrText.isEmpty
        facets["ocr_text_length"] = ocrResult.ocrText.count
        
        // Calculate average confidence from boxes if available
        if !ocrResult.ocrBoxes.isEmpty {
            let confidenceSum = ocrResult.ocrBoxes.compactMap { $0.confidence }.reduce(0.0, +)
            let confidenceCount = ocrResult.ocrBoxes.compactMap { $0.confidence }.count
            if confidenceCount > 0 {
                facets["ocr_confidence"] = confidenceSum / Float(confidenceCount)
            }
        }
        
        if let regions = ocrResult.regions {
            facets["ocr_region_count"] = regions.count
        }
        
        return facets
    }
    
    // MARK: - Utilities
    
    private func dateToAppleEpoch(_ date: Date) -> Int64 {
        let appleEpoch = Date(timeIntervalSince1970: 978307200) // 2001-01-01 00:00:00 UTC
        let delta = date.timeIntervalSince(appleEpoch)
        return Int64(delta * 1_000_000_000) // Convert to nanoseconds
    }
    
    private func appleEpochToDate(_ timestamp: Int64) -> Date {
        let appleEpoch = Date(timeIntervalSince1970: 978307200) // 2001-01-01 00:00:00 UTC
        // Heuristic to detect stored unit and convert to seconds.
        let seconds: TimeInterval
        if timestamp > 1_000_000_000_000_000 {
            // Treat as nanoseconds -> divide by 1e9
            seconds = Double(timestamp) / 1_000_000_000.0
        } else if timestamp > 1_000_000_000_000 {
            // Treat as microseconds -> divide by 1e6
            seconds = Double(timestamp) / 1_000_000.0
        } else if timestamp > 1_000_000_000 {
            // Treat as milliseconds -> divide by 1e3
            seconds = Double(timestamp) / 1_000.0
        } else {
            // Seconds
            seconds = Double(timestamp)
        }
        return appleEpoch.addingTimeInterval(seconds)
    }
    
    private func appleEpochToISO8601(_ timestamp: Int64) -> String {
        let appleEpoch = Date(timeIntervalSince1970: 978307200) // 2001-01-01 00:00:00 UTC
        // Heuristic to detect stored unit and convert to seconds.
        // Use thresholds that separate seconds / milliseconds / microseconds / nanoseconds
        // for timestamps in the 2000s-2030s range.
        let seconds: TimeInterval
        if timestamp > 1_000_000_000_000_000 {
            // nanoseconds -> divide by 1e9
            seconds = Double(timestamp) / 1_000_000_000.0
        } else if timestamp > 1_000_000_000_000 {
            // microseconds -> divide by 1e6
            seconds = Double(timestamp) / 1_000_000.0
        } else if timestamp > 1_000_000_000 {
            // milliseconds -> divide by 1e3
            seconds = Double(timestamp) / 1_000.0
        } else {
            // seconds
            seconds = Double(timestamp)
        }

        let date = appleEpoch.addingTimeInterval(seconds)
        return ISO8601DateFormatter().string(from: date)
    }
    
    nonisolated private func decodeAttributedBody(_ data: Data) -> String? {
        // Enhanced attributed body decoding for iMessage attributedBody data
        // The data can be in multiple formats: NSKeyedArchiver, streamtyped, or binary plist
        
        // First, check if this is streamtyped format (starts with streamtyped marker)
        if data.count > 11 {
            let streamtypedMarker = Data([0x04, 0x0b, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64])
            if data.prefix(13) == streamtypedMarker {
                // This is streamtyped format - handle it directly
                if let result = extractTextFromStreamtypedData(data) {
                    return result
                }
            }
        }
        
        // Try NSKeyedUnarchiver for proper NSKeyedArchiver format
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            
            // Try to decode as NSAttributedString first (most common case)
            if let attributedString = unarchiver.decodeObject(of: NSAttributedString.self, forKey: NSKeyedArchiveRootObjectKey) {
                let plainText = attributedString.string
                if !plainText.isEmpty {
                    return plainText
                }
            }
            
            // Try to decode as NSString
            if let string = unarchiver.decodeObject(of: NSString.self, forKey: NSKeyedArchiveRootObjectKey) {
                let plainText = string as String
                if !plainText.isEmpty {
                    return plainText
                }
            }
            
            // Try to decode as any object and extract text
            if let anyObject = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) {
                if let attributedString = anyObject as? NSAttributedString {
                    let plainText = attributedString.string
                    if !plainText.isEmpty {
                        return plainText
                    }
                } else if let string = anyObject as? NSString {
                    let plainText = string as String
                    if !plainText.isEmpty {
                        return plainText
                    }
                }
            }
            
            unarchiver.finishDecoding()
        } catch {
            // NSKeyedUnarchiver failed, continue to fallback methods
        }
        
        // Fallback: Try standard PropertyListSerialization (XML/binary plist formats)
        do {
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if let result = extractTextFromPlist(plist) {
                    return result
                }
            }
        } catch {
            // PropertyListSerialization failed, will try binary extraction below
        }
        
        // Try to handle NSKeyedArchiver streamtyped format manually (as fallback)
        // Even if the exact marker wasn't found, the data might still be streamtyped
        if let result = extractTextFromStreamtypedData(data) {
            return result
        }
        
        // Final fallback: try to extract UTF-8 text directly from binary data
        // This should always be tried as a last resort, even if other methods didn't throw errors
        if let result = extractTextFromBinaryData(data) {
            return result
        }
        
        return nil
    }
    
    nonisolated private func extractTextFromPlist(_ plist: [String: Any]) -> String? {
        guard let objects = plist["$objects"] as? [Any] else {
            return nil
        }
        
        // Try to find the root object first
        if let top = plist["$top"] as? [String: Any],
           let root = top["root"] as? [String: Any],
           let rootUID = root["UID"] as? Int {
            if rootUID < objects.count,
               let rootObj = objects[rootUID] as? [String: Any] {
                if let result = extractTextFromObject(rootObj, objects: objects) {
                    return result
                }
            }
        }
        
        // Fallback: search through all objects
        for obj in objects {
            if let result = extractTextFromObject(obj, objects: objects) {
                return result
            }
        }
        
        return nil
    }
    
    nonisolated private func extractTextFromObject(_ obj: Any, objects: [Any]) -> String? {
        guard let dict = obj as? [String: Any] else {
            return nil
        }
        
        // Check for NSString directly
        if let nsString = dict["NSString"] as? String {
            return nsString.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        
        // Check for NS.string reference
        if let nsStringRef = dict["NS.string"] as? [String: Any],
           let uid = nsStringRef["UID"] as? Int,
           uid < objects.count,
           let stringObj = objects[uid] as? String {
            return stringObj.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        
        // Check for NS.objects array
        if let nsObjects = dict["NS.objects"] as? [Any] {
            for item in nsObjects {
                if let result = extractTextFromObject(item, objects: objects) {
                    return result
                }
            }
        }
        
        // Check for NS.values array
        if let nsValues = dict["NS.values"] as? [Any] {
            for item in nsValues {
                if let result = extractTextFromObject(item, objects: objects) {
                    return result
                }
            }
        }
        
        return nil
    }
    
    nonisolated private func extractTextFromStreamtypedData(_ data: Data) -> String? {
        // Handle NSKeyedArchiver streamtyped format
        // This is a binary format where text is embedded directly
        
        // Handle empty or very small data
        guard data.count > 2 else {
            return nil
        }
        
        // Method 1: Look for the pattern: + (0x2b) followed by length byte, then text
        for i in 0..<(data.count - 2) {
            if data[i] == 0x2b { // '+'
                let lengthByte = data[i + 1]
                let textStart = i + 2
                let textEnd = textStart + Int(lengthByte)
                
                if textEnd <= data.count && textEnd > textStart && lengthByte > 0 && lengthByte < 200 {
                    let textData = data.subdata(in: textStart..<textEnd)
                    if let text = String(data: textData, encoding: .utf8) {
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Filter out metadata-like strings
                        if cleaned.count > 3 && !cleaned.hasPrefix("NS") && !cleaned.hasPrefix("__k") &&
                           !cleaned.contains("streamtyped") && !cleaned.contains("NSObject") &&
                           !cleaned.contains("DDScannerResult") {
                            return cleaned
                        }
                    }
                }
            }
        }
        
        // Method 2: Convert to string and look for '+' patterns (more lenient)
        // Try UTF-8 decoding - use lossy decoding if needed
        let text: String
        if let utf8Text = String(data: data, encoding: .utf8) {
            text = utf8Text
        } else {
            // Try to decode with error replacement
            text = String(decoding: data, as: UTF8.self)
        }
        
        guard !text.isEmpty else {
            return nil
        }
        
        // Look for '+' characters which often precede text in streamtyped format
        // Pattern: streamtyped...NSAttributedString...NSString+<actual_text>\x02...
        var candidates: [String] = []
        
        // Find all '+' positions and extract text after them
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            if let plusIndex = text[searchStart...].firstIndex(of: "+") {
                let afterPlus = text.index(after: plusIndex)
                if afterPlus < text.endIndex {
                    let searchText = String(text[afterPlus...])
                    
                    // Extract text until we hit metadata markers or control characters
                    var extractedText = ""
                    for char in searchText {
                        // Stop at common metadata markers and control chars
                        if char == "\0" || char == "\u{02}" || char == "\u{03}" {
                            break
                        }
                        // Check if this looks like the start of metadata
                        if char == "i" || char == "I" {
                            let remainingStart = searchText.index(searchText.startIndex, offsetBy: extractedText.count)
                            if remainingStart < searchText.endIndex {
                                let remaining = String(searchText[remainingStart...])
                                if remaining.hasPrefix("iNSDictionary") || remaining.hasPrefix("INSDictionary") ||
                                   remaining.hasPrefix("i__kIM") || remaining.hasPrefix("I__kIM") {
                                    break
                                }
                            }
                        }
                        extractedText.append(char)
                    }
                    
                    // Clean up and validate
                    let cleaned = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.count > 3 && 
                       !cleaned.hasPrefix("NS") && 
                       !cleaned.hasPrefix("__k") &&
                       !cleaned.contains("streamtyped") &&
                       !cleaned.contains("NSObject") &&
                       !cleaned.contains("NSString") &&
                       !cleaned.contains("NSDictionary") &&
                       !cleaned.contains("DDScannerResult") {
                        candidates.append(cleaned)
                    }
                }
                searchStart = text.index(after: plusIndex)
            } else {
                break
            }
        }
        
        // Return the longest valid candidate
        if let best = candidates.max(by: { $0.count < $1.count }), best.count > 3 {
            return best
        }
        
        // Method 3: Look for ASCII text patterns directly in binary (similar to binary extraction)
        // This handles cases where UTF-8 decoding produces mixed text/control sequences
        var extractedText = ""
        var bestText = ""
        var i = 0
        while i < data.count {
            let byte = data[i]
            // Look for printable ASCII characters
            if byte >= 32 && byte <= 126 {
                extractedText.append(Character(UnicodeScalar(byte)))
            } else if byte == 0 || byte == 0x02 || byte == 0x03 {
                // Null terminator or control char - check if we have a reasonable text length
                if extractedText.count > 3 && extractedText.count < 2000 {
                    // Check if it looks like actual text (not metadata)
                    let trimmed = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > bestText.count &&
                       !trimmed.hasPrefix("NS") && 
                       !trimmed.hasPrefix("__k") &&
                       !trimmed.contains("streamtyped") &&
                       !trimmed.contains("NSObject") &&
                       !trimmed.contains("NSString") &&
                       !trimmed.contains("NSDictionary") &&
                       !trimmed.contains("DDScannerResult") &&
                       !trimmed.contains("__kIM") &&
                       !trimmed.contains("AttributeName") &&
                       !trimmed.contains("NSNumber") &&
                       !isMetadataAttributePattern(trimmed) {
                        bestText = trimmed
                    }
                }
                extractedText = ""
            } else {
                // Non-printable character - reset if we don't have much text
                if extractedText.count < 3 {
                    extractedText = ""
                }
            }
            i += 1
        }
        
        // Check final extracted text
        if extractedText.count > 3 && extractedText.count < 2000 {
            let trimmed = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > bestText.count &&
               !trimmed.hasPrefix("NS") && 
               !trimmed.hasPrefix("__k") &&
               !trimmed.contains("streamtyped") &&
               !trimmed.contains("NSObject") &&
               !trimmed.contains("DDScannerResult") &&
               !trimmed.contains("__kIM") &&
               !trimmed.contains("AttributeName") &&
               !trimmed.contains("NSNumber") &&
               !isMetadataAttributePattern(trimmed) {
                bestText = trimmed
            }
        }
        
        return bestText.isEmpty ? nil : bestText
    }
    
    nonisolated private func extractTextFromBinaryData(_ data: Data) -> String? {
        // Fallback: try to extract UTF-8 text directly from binary data
        // Use UTF-8 decoding with error replacement to handle invalid sequences
        let text = String(data: data, encoding: .utf8) ?? 
                   String(decoding: data, as: UTF8.self)
        
        guard !text.isEmpty else {
            return nil
        }
        
        // Quick check: if the text contains "streamtyped" or heavy framework markers at the start,
        // it's likely serialized binary data, not actual text - reject it
        if text.contains("streamtyped") || text.hasPrefix("NSMutableAttributedString") || 
           text.hasPrefix("NSAttributedString") || text.hasPrefix("NSObject") ||
           text.hasPrefix("NSMutableString") {
            return nil
        }
        
        // Remove null bytes and control characters (except newlines and tabs), keep printable and whitespace
        let cleaned = text.compactMap { char -> Character? in
            if char.isPrintable || char.isNewline || char.isWhitespace {
                return char
            }
            // Replace null bytes and other control characters with spaces for better text extraction
            if char.unicodeScalars.first?.value ?? 0 < 32 && char != "\n" && char != "\r" && char != "\t" {
                return " "
            }
            return nil
        }
        
        let cleanedString = String(cleaned)
        
        // Split by null bytes and control sequences, extract text segments
        // Create CharacterSet with control characters (0x00-0x1F, all ASCII control chars)
        var controlCharSet = CharacterSet()
        for i in 0...0x1F {
            controlCharSet.insert(UnicodeScalar(i)!)
        }
        // Also include DEL (0x7F)
        controlCharSet.insert(UnicodeScalar(0x7F)!)
        
        // Split on control characters
        let segments = cleanedString
            .components(separatedBy: controlCharSet)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { segment in
                // Filter out metadata-like strings and require minimum length
                segment.count > 3 && 
                !segment.hasPrefix("NS") && 
                !segment.hasPrefix("__k") &&
                !segment.contains("streamtyped") &&
                !segment.contains("NSObject") &&
                !segment.contains("NSString") &&
                !segment.contains("NSDictionary") &&
                !segment.contains("DDScannerResult") &&
                !segment.contains("__kIM") &&  // iMessage framework attributes
                !segment.contains("AttributeName") &&  // Common attribute suffix
                !segment.contains("NSNumber") &&  // NSNumber type markers
                !isMetadataAttributePattern(segment)
            }
        
        // Find the longest segment that looks like actual text
        if let longest = segments.max(by: { $0.count < $1.count }), longest.count > 3 {
            let final = longest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if final.isEmpty {
                return nil
            }
            // Check if the text looks like corrupted data
            // Allow: single chars, repeated punctuation, alphanumeric text, and approved special chars
            // Reject: mixed special chars that look like encoding artifacts ("3<?A", "5.1?!")
            if final.count > 1 && final.count < 10 {
                let alphanumericCount = final.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }.count
                let alphanumericRatio = Double(alphanumericCount) / Double(final.count)
                
                // Check if all characters are from the approved set: . ! * ? ^ and whitespace
                let approvedSpecialChars = CharacterSet(charactersIn: ".!*?^ ")
                let allApprovedSpecial = final.allSatisfy { char in
                    approvedSpecialChars.contains(char.unicodeScalars.first!)
                }
                
                // Check if all non-alphanumeric chars are the same (legitimate repeated punctuation)
                let nonAlphanumeric = final.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
                let allSameNonAlphanumeric = Set(nonAlphanumeric).count <= 1
                
                // Reject only if: low alphanumeric content AND NOT all-same-punctuation AND NOT all-approved-special
                if alphanumericRatio < 0.5 && !allSameNonAlphanumeric && !allApprovedSpecial {
                    // Short text with mixed special chars - likely corrupted
                    return nil
                }
            }
            return final
        }
        
        // If no segments found, try to find contiguous printable text in the cleaned string
        // Look for sequences of printable characters separated by at most a few spaces
        var candidate = ""
        var bestCandidate = ""
        var consecutiveSpaces = 0
        
        for char in cleanedString {
            if char.isPrintable || char.isNewline {
                candidate.append(char)
                consecutiveSpaces = 0
            } else if char.isWhitespace {
                candidate.append(char)
                consecutiveSpaces += 1
                if consecutiveSpaces > 3 {
                    // Too many spaces, likely not text - evaluate current candidate
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > bestCandidate.count && trimmed.count > 3 &&
                       !trimmed.hasPrefix("NS") && !trimmed.hasPrefix("__k") &&
                       !trimmed.contains("DDScannerResult") &&
                       !trimmed.contains("__kIM") &&
                       !trimmed.contains("AttributeName") &&
                       !trimmed.contains("NSNumber") &&
                       !isMetadataAttributePattern(trimmed) {
                        bestCandidate = trimmed
                    }
                    candidate = ""
                    consecutiveSpaces = 0
                }
            } else {
                // Non-printable, non-whitespace - evaluate current candidate
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > bestCandidate.count && trimmed.count > 3 &&
                   !trimmed.hasPrefix("NS") && !trimmed.hasPrefix("__k") &&
                   !trimmed.contains("__kIM") &&
                   !trimmed.contains("AttributeName") &&
                   !trimmed.contains("NSNumber") &&
                   !isMetadataAttributePattern(trimmed) {
                    bestCandidate = trimmed
                }
                candidate = ""
                consecutiveSpaces = 0
            }
        }
        
        // Check final candidate
        let finalTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalTrimmed.count > bestCandidate.count && finalTrimmed.count > 3 &&
           !finalTrimmed.hasPrefix("NS") && !finalTrimmed.hasPrefix("__k") &&
           !finalTrimmed.contains("DDScannerResult") &&
           !finalTrimmed.contains("__kIM") &&
           !finalTrimmed.contains("AttributeName") &&
           !finalTrimmed.contains("NSNumber") &&
           !isMetadataAttributePattern(finalTrimmed) {
            bestCandidate = finalTrimmed
        }
        
        // Validate final result - reject only if it looks like corrupted encoding artifacts
        // Allow: single chars, repeated punctuation, alphanumeric text, and approved special chars
        // Reject: mixed special chars that look like encoding artifacts ("3<?A", "5.1?!")
        if !bestCandidate.isEmpty && bestCandidate.count > 1 && bestCandidate.count < 10 {
            let alphanumericCount = bestCandidate.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }.count
            let alphanumericRatio = Double(alphanumericCount) / Double(bestCandidate.count)
            
            // Check if all characters are from the approved set: . ! * ? ^ and whitespace
            let approvedSpecialChars = CharacterSet(charactersIn: ".!*?^ ")
            let allApprovedSpecial = bestCandidate.allSatisfy { char in
                approvedSpecialChars.contains(char.unicodeScalars.first!)
            }
            
            // Check if all non-alphanumeric chars are the same (legitimate repeated punctuation)
            let nonAlphanumeric = bestCandidate.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
            let allSameNonAlphanumeric = Set(nonAlphanumeric).count <= 1
            
            // Reject only if: low alphanumeric content AND NOT all-same-punctuation AND NOT all-approved-special
            if alphanumericRatio < 0.5 && !allSameNonAlphanumeric && !allApprovedSpecial {
                // Short text (2-9 chars) with mixed special chars - likely corrupted
                return nil
            }
        }
        
        return bestCandidate.isEmpty ? nil : bestCandidate
    }
    
    nonisolated private func isMetadataAttributePattern(_ text: String) -> Bool {
        // Check for iMessage framework attribute patterns that should be filtered out
        let metadataPatterns = [
            "__kIM",  // iMessage framework prefix
            "AttributeName",
            "AttributeKey",
            "NSWritingDirection",
            "NSParagraphStyle",
            "NSFont",
            "NSColor",
            "NSBackgroundColor",
            "NSUnderline",
            "NSStrikethrough"
        ]
        
        for pattern in metadataPatterns {
            if text.contains(pattern) {
                return true
            }
        }
        
        return false
    }
    
    /// Public method for testing attributed body decoding
    func testDecodeAttributedBody(_ data: Data) -> String? {
        return decodeAttributedBody(data)
    }
    
    /// Static method for testing attributed body decoding without initialization
    static func testDecodeAttributedBodyStatic(_ data: Data) -> String? {
        let config = HavenConfig()
        let gatewayClient = GatewayClient(config: config.gateway, authToken: config.service.auth.secret)
        let handler = IMessageHandler(config: config, gatewayClient: gatewayClient)
        return handler.decodeAttributedBody(data)
    }
    
    /// Post a batch of documents to the gateway, preferring the batch endpoint when enabled.
    private struct GatewaySubmissionResult {
        let successCount: Int
        let errorCount: Int
    }
    
    private func postDocumentsToGatewayWithErrors(_ documents: [[String: Any]], batchMode: Bool) async throws -> GatewaySubmissionResult {
        guard !documents.isEmpty else { return GatewaySubmissionResult(successCount: 0, errorCount: 0) }
        
        // Use batch endpoint if batch mode is enabled
        if batchMode {
            if let batchCount = try await postDocumentsToGatewayBatch(documents) {
                // Batch endpoint succeeded - gateway accepted all documents
                // postDocumentsToGatewayBatch returns the count of documents if HTTP request succeeds (200/202/207)
                // which means all documents were accepted by the gateway
                return GatewaySubmissionResult(successCount: batchCount, errorCount: 0)
            } else {
                // Batch endpoint unavailable - fall through to individual submission
                // Return result from individual submissions below
            }
        }
        
        // Fallback to individual submissions
        var successCount = 0
        var errorCount = 0
        
        for document in documents {
            do {
                try await postDocumentToGateway(document)
                successCount += 1
            } catch {
                errorCount += 1
                logger.warning("Failed to post document to gateway", metadata: [
                    "error": error.localizedDescription,
                    "document_id": (document["id"] as? String) ?? "unknown"
                ])
            }
        }
        
        return GatewaySubmissionResult(successCount: successCount, errorCount: errorCount)
    }
    
    private func postDocumentsToGateway(_ documents: [[String: Any]], batchMode: Bool) async throws -> Int {
        guard !documents.isEmpty else { return 0 }
        
        // If a submitter is available, documents should have been submitted via the submitter
        // during enrichment. However, documents processed via enrichDocumentSynchronously
        // may not have been submitted. Check if submitter was used and if documents were actually submitted.
        // For now, if a submitter exists, we assume documents were submitted via it (they should be
        // submitted in buildDocumentWithEnrichment). If no submitter exists, we need to post via HTTP.
        if submitter != nil {
            // Documents should have been submitted via submitter during enrichment
            // But to be safe, we'll still post them via HTTP as a fallback
            // This ensures documents are submitted even if submitter submission failed silently
            logger.debug("Submitter available, but posting via HTTP as well to ensure submission", metadata: [
                "batch_size": String(documents.count)
            ])
        }
        
        // Actually post documents to gateway
        if batchMode {
            if let batchCount = try await postDocumentsToGatewayBatch(documents) {
                return batchCount
            } else {
                // Fallback to individual posting if batch endpoint unavailable
                return try await postDocumentsToGatewayIndividually(documents)
            }
        } else {
            return try await postDocumentsToGatewayIndividually(documents)
        }
    }

    /// Post documents individually to the legacy ingest endpoint.
    private func postDocumentsToGatewayIndividually(_ documents: [[String: Any]]) async throws -> Int {
        var successCount = 0

        // Post each document individually since gateway batch submission may be unavailable.
        // URLSession operations will automatically respect task cancellation.
        for document in documents {
            do {
                try await postDocumentToGateway(document)
                successCount += 1
            } catch let cancellationError as CancellationError {
                // Re-throw cancellation errors to stop processing gracefully
                logger.info("Document posting cancelled")
                throw cancellationError
            } catch {
                logger.error("Failed to post document to gateway", metadata: [
                    "error": error.localizedDescription,
                    "external_id": document["external_id"] as? String ?? "unknown"
                ])
                // Continue processing other documents even if one fails (unless cancelled)
            }
        }
        
        logger.debug("Posted batch to gateway", metadata: [
            "batch_size": String(documents.count),
            "success_count": String(successCount),
            "failed_count": String(documents.count - successCount)
        ])
        
        return successCount
    }

    /// Attempt to post documents via the gateway batch endpoint.
    /// - Returns: Success count when the batch endpoint is available, or `nil` if fallback is required.
    private func postDocumentsToGatewayBatch(_ documents: [[String: Any]]) async throws -> Int? {
        let payload: [String: Any] = ["documents": documents]
        let requestBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        let candidatePaths = batchEndpointCandidates(basePath: config.gateway.ingestPath)

        // Build base URL using URLComponents to avoid unwanted percent-encoding of path
        guard let baseURL = URL(string: config.gateway.baseUrl) else {
            logger.error("Invalid gateway base url", metadata: ["base_url": config.gateway.baseUrl])
            return nil
        }

        guard let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            logger.error("Failed to create URLComponents for gateway base url", metadata: ["base_url": config.gateway.baseUrl])
            return nil
        }

        for path in candidatePaths {
            // Build URL using URLComponents to avoid unwanted percent-encoding of path
            // Preserve existing base path and append candidate path. Set percentEncodedPath
            // directly so characters like ':' are not further escaped.
            var comps = baseComponents
            let basePath = comps.percentEncodedPath
            let trimmedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            let newPercentEncodedPath = trimmedBasePath + path
            comps.percentEncodedPath = newPercentEncodedPath

            guard let url = comps.url else {
                logger.error("Failed to compose gateway batch URL", metadata: ["base_url": config.gateway.baseUrl, "path": path])
                continue
            }
            let urlString = url.absoluteString

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(config.service.auth.secret)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = TimeInterval(config.gateway.timeoutMs) / 1000.0
            request.httpBody = requestBody

            logger.debug("Posting batch to gateway", metadata: [
                "url": urlString,
                "document_count": String(documents.count)
            ])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CollectorError.invalidGatewayResponse
                }

                switch httpResponse.statusCode {
                case 200, 202, 207:
                    let parsed = try parseGatewayBatchResponse(data: data, totalDocuments: documents.count)
                    logger.debug("Gateway batch ingest completed", metadata: [
                        "url": urlString,
                        "status": String(httpResponse.statusCode),
                        "total": String(parsed.totalCount ?? documents.count),
                        "catalog_success": String(parsed.successCount),
                        "catalog_failure": String(parsed.failureCount)
                    ])
                    // Return the number of documents successfully POSTed to gateway (HTTP success),
                    // not catalog ingestion success. All documents were accepted by gateway if we got 200/202/207.
                    return documents.count
                case 404, 405:
                    logger.info("Gateway batch endpoint unavailable, will attempt fallback", metadata: [
                        "url": urlString,
                        "status": String(httpResponse.statusCode)
                    ])
                    continue
                default:
                    let body = String(data: data, encoding: .utf8) ?? ""
                    logger.error("Gateway batch ingest failed", metadata: [
                        "url": urlString,
                        "status": String(httpResponse.statusCode),
                        "body": body
                    ])
                    continue
                }
            } catch {
                logger.error("Gateway batch ingest request failed", metadata: [
                    "url": urlString,
                    "error": error.localizedDescription
                ])
                continue
            }
        }

        return nil
    }
    
    private func batchEndpointCandidates(basePath: String) -> [String] {
        // Only use the colon version: /v1/ingest:batch
        let colonPath = basePath.hasSuffix(":batch") ? basePath : basePath + ":batch"
        return [colonPath]
    }

    private struct GatewayBatchResponseEnvelope: Decodable {
        let batchId: String?
        let batchStatus: String?
        let totalCount: Int?
        let successCount: Int?
        let failureCount: Int?
        let results: [GatewayBatchResponseItem]?
    }

    private struct GatewayBatchResponseItem: Decodable {
        let index: Int?
        let statusCode: Int?
    }

    private struct ParsedGatewayBatchResponse {
        let totalCount: Int?
        let successCount: Int
        let failureCount: Int
    }

    private func parseGatewayBatchResponse(data: Data, totalDocuments: Int) throws -> ParsedGatewayBatchResponse {
        if data.isEmpty {
            return ParsedGatewayBatchResponse(
                totalCount: totalDocuments,
                successCount: totalDocuments,
                failureCount: 0
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(GatewayBatchResponseEnvelope.self, from: data)

        let computedSuccess: Int
        if let successCount = envelope.successCount {
            computedSuccess = successCount
        } else if let items = envelope.results {
            let successes = items.compactMap { item -> Int? in
                guard let code = item.statusCode else { return nil }
                return (200...299).contains(code) ? 1 : 0
            }
            computedSuccess = successes.reduce(0, +)
        } else {
            computedSuccess = totalDocuments
        }

        let computedFailure: Int
        if let failureCount = envelope.failureCount {
            computedFailure = failureCount
        } else {
            computedFailure = max(0, totalDocuments - computedSuccess)
        }

        return ParsedGatewayBatchResponse(
            totalCount: envelope.totalCount,
            successCount: computedSuccess,
            failureCount: computedFailure
        )
    }
    
    /// Post a document to the gateway /v1/ingest endpoint
    private func postDocumentToGateway(_ document: [String: Any]) async throws {
        // Build the gateway URL
        let urlString = config.gateway.baseUrl + config.gateway.ingestPath
        guard let url = URL(string: urlString) else {
            throw CollectorError.invalidGatewayUrl(urlString)
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.service.auth.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = TimeInterval(config.gateway.timeoutMs) / 1000.0
        
        // Serialize document to JSON
        request.httpBody = try JSONSerialization.data(withJSONObject: document, options: [])
        
        // Log the request (truncate for readability)
        let externalId = document["external_id"] as? String ?? "unknown"
        logger.debug("Posting document to gateway", metadata: ["external_id": externalId, "url": urlString])
        
        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CollectorError.invalidGatewayResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Gateway returned error", metadata: [
                "status": String(httpResponse.statusCode),
                "body": body,
                "external_id": externalId
            ])
            throw CollectorError.gatewayHttpError(httpResponse.statusCode, body)
        }
        
        logger.debug("Document posted successfully", metadata: ["external_id": externalId])
    }
    
    private func sha256(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Collection Logic
}

// MARK: - Error Types

enum CollectorError: Error, LocalizedError {
    case moduleDisabled(String)
    case alreadyRunning(String)
    case chatDbNotFound(String)
    case databaseOpenFailed(String)
    case snapshotFailed(String)
    case queryFailed(String)
    case invalidGatewayUrl(String)
    case invalidGatewayResponse
    case gatewayHttpError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .moduleDisabled(let message):
            return "Module disabled: \(message)"
        case .alreadyRunning(let message):
            return "Collector already running: \(message)"
        case .chatDbNotFound(let path):
            return "chat.db not found at path: \(path)"
        case .databaseOpenFailed(let message):
            return "Failed to open database: \(message)"
        case .snapshotFailed(let message):
            return "Failed to create snapshot: \(message)"
        case .queryFailed(let message):
            return "Database query failed: \(message)"
        case .invalidGatewayUrl(let url):
            return "Invalid gateway URL: \(url)"
        case .invalidGatewayResponse:
            return "Invalid response from gateway"
        case .gatewayHttpError(let code, let body):
            return "Gateway HTTP error \(code): \(body)"
        }
    }
}

// Helper extensions
extension Character {
    var isPrintable: Bool {
        return !isNewline && !isWhitespace && (self >= " " && self <= "~" || self.unicodeScalars.first!.value >= 0xA0)
    }
}
