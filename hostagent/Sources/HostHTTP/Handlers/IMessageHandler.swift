import Foundation
import HavenCore
@_spi(Generated) import OpenAPIRuntime
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
            return dict
        }
    }
    
    public init(config: HavenConfig, gatewayClient: GatewayClient) {
        self.config = config
        self.gatewayClient = gatewayClient
        
        // Initialize OCR service if enabled
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
        
        // Initialize entity service if enabled
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
    
    /// Handle POST /v1/collectors/imessage:run
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.imessage.enabled else {
            logger.warning("iMessage collector request rejected - module disabled")
            return HTTPResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"iMessage collector module is disabled"}"#.data(using: .utf8)
            )
        }
        
        // Check if already running
        guard !isRunning else {
            logger.warning("iMessage collector already running")
            return HTTPResponse(
                statusCode: 409,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Collector is already running"}"#.data(using: .utf8)
            )
        }
        
        // Parse request parameters using OpenAPI-generated types
        var params = CollectorParams()
        params.configChatDbPath = config.modules.imessage.chatDbPath
        var runRequest: Components.Schemas.RunRequest?
        
        if let body = request.body, !body.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            do {
                runRequest = try decoder.decode(Components.Schemas.RunRequest.self, from: body)
                
                // Extract parameters from RunRequest
                params.limit = runRequest!.limit  // Use provided limit or nil for unlimited
                params.order = runRequest!.order.rawValue
                params.batchMode = runRequest!.batch ?? false
                if let providedBatchSize = runRequest!.batchSize {
                    params.batchSize = providedBatchSize
                }
                if let dateRange = runRequest!.dateRange {
                    params.since = dateRange.since
                    params.until = dateRange.until
                }
                // Handle collector-specific options
                if case let .IMessageCollectorOptions(options) = runRequest!.collectorOptions {
                    params.limit = options.limit ?? params.limit
                    if let order = options.order {
                        params.order = order.rawValue
                    }
                    params.threadLookbackDays = options.threadLookbackDays ?? params.threadLookbackDays
                    params.messageLookbackDays = options.messageLookbackDays ?? params.messageLookbackDays
                    params.chatDbPath = options.chatDbPath ?? params.chatDbPath
                }
            } catch {
                logger.error("Failed to decode RunRequest", metadata: ["error": error.localizedDescription])
                return HTTPResponse.badRequest(message: "Invalid request format: \(error.localizedDescription)")
            }
        }
        
        // Validate parameters (no mode validation needed)
        
        logger.info("Starting iMessage collector", metadata: [
            "limit": params.limit?.description ?? "unlimited",
            "thread_lookback_days": String(params.threadLookbackDays),
            "message_lookback_days": String(params.messageLookbackDays),
            "batch_mode": params.batchMode ? "true" : "false",
            "batch_size": params.batchSize.map(String.init) ?? "default"
        ])
        
        // Run collection
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        lastRunError = nil
        
        let startTime = Date()
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
            let result = try await collectMessages(params: params, stats: &stats)
            
            // Documents are posted to gateway in batches during collection
            // Count successful posts from the collection process
            let successCount = result.submittedCount
            let failureCount = 0  // Individual failures are logged but don't stop processing
            
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "completed"
            lastRunStats = stats
            
            logger.info("iMessage collection completed", metadata: [
                "documents": String(result.documents.count),
                "posted": String(successCount),
                "failed": String(failureCount),
                "duration_ms": String(stats.durationMs ?? 0)
            ])
            
            // Return adapter format that RunRouter expects
            return encodeAdapterResponse(
                scanned: stats.messagesProcessed,
                matched: stats.messagesProcessed, // Same as scanned for iMessage
                submitted: successCount,
                skipped: max(0, stats.messagesProcessed - successCount),
                earliestTouched: stats.earliestMessageTimestamp.map { appleEpochToISO8601($0) },
                latestTouched: stats.latestMessageTimestamp.map { appleEpochToISO8601($0) },
                warnings: [],
                errors: []
            )
            
        } catch {
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "failed"
            lastRunStats = stats
            lastRunError = error.localizedDescription
            
            logger.error("iMessage collection failed", metadata: ["error": error.localizedDescription])
            
            return HTTPResponse.internalError(message: "Collection failed: \(error.localizedDescription)")
        }
    }
    
    /// Handle GET /v1/collectors/imessage/state
    public func handleState(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        var state: [String: Any] = [
            "is_running": isRunning,
            "last_run_status": lastRunStatus
        ]
        
        if let lastRunTime = lastRunTime {
            state["last_run_time"] = ISO8601DateFormatter().string(from: lastRunTime)
        }
        
        if let lastRunStats = lastRunStats {
            state["last_run_stats"] = lastRunStats.toDict
        }
        
        if let lastRunError = lastRunError {
            state["last_run_error"] = lastRunError
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            return HTTPResponse.internalError(message: "Failed to encode state: \(error.localizedDescription)")
        }
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
            if !configChatDbPath.isEmpty {
                return NSString(string: configChatDbPath).expandingTildeInPath
            }
            if !chatDbPath.isEmpty {
                return chatDbPath
            }
            return NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
        }
    }
    
    private func collectMessages(params: CollectorParams, stats: inout CollectorStats) async throws -> (documents: [[String: Any]], submittedCount: Int) {
        let chatDbPath = params.resolvedChatDbPath
        
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
        var fences: [FenceRange] = []
        do {
            fences = try loadIMessageState()
            logger.info("Loaded iMessage fences", metadata: ["fence_count": String(fences.count)])
        } catch {
            logger.warning("Failed to load iMessage collector state", metadata: ["error": error.localizedDescription])
        }

        // Retrieve candidate message ROWIDs chronologically ordered (respects params.order)
        let rowIds = try fetchMessageRowIds(db: db!, params: params)
        // Track total candidates
        stats.messagesProcessed = rowIds.count

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
        
        logger.info("Processing messages in batches of \(batchSize)", metadata: [
            "total_rows": String(orderedRowIds.count),
            "limit": params.limit?.description ?? "unlimited",
            "submission_mode": params.batchMode ? "batch" : "single",
            "existing_fences": String(fences.count)
        ])

        // Iterate ordered rows and prepare documents in batches
        for rowId in orderedRowIds {
            // Check if we've hit the overall limit BEFORE processing
            if let lim = params.limit, lim > 0, submittedCount >= lim {
                logger.info("Reached limit of \(lim) messages, stopping processing")
                break
            }
            
            // Fetch the message row
            guard let message = try fetchMessageByRowId(db: db!, rowId: rowId) else { continue }
            
            // Use canonical timestamp: message.date (the message's primary timestamp)
            // This is used for all comparisons, fences, and ordering - never use date_read or date_delivered
            // Convert from Apple epoch to Date for fence checking and date range comparisons
            let messageDate = appleEpochToDate(message.date)

            // Check if message timestamp is within any fence - if so, skip
            if FenceManager.isTimestampInFences(messageDate, fences: fences) {
                logger.debug("Skipping message within fence", metadata: [
                    "row_id": String(rowId),
                    "timestamp": ISO8601DateFormatter().string(from: messageDate),
                    "fence_count": String(fences.count)
                ])
                continue
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
            guard let thread = threads.first(where: { $0.rowId == message.chatId }) else { continue }

            // Enrich attachments if present
            var enrichedAttachments: [[String: Any]] = []
            if !message.attachments.isEmpty {
                enrichedAttachments = try await enrichAttachments(message.attachments, db: db!)
                stats.attachmentsProcessed += message.attachments.count
            }

            let document = try buildDocument(message: message, thread: thread, attachments: enrichedAttachments)
            currentBatch.append(document)
            currentBatchTimestamps.append(messageDate)
            allDocuments.append(document)
            stats.documentsCreated += 1

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
                
                // Post batch to gateway
                let batchSuccessCount = try await postDocumentsToGateway(batchToSubmit, batchMode: params.batchMode)
                logger.info("Posted batch to gateway", metadata: [
                    "batch_size": String(batchToSubmit.count),
                    "posted_to_gateway": String(batchSuccessCount),
                    "submission_mode": params.batchMode ? "batch" : "single"
                ])
                
                // Update submitted count (only successful submissions count toward limit)
                submittedCount += batchSuccessCount
                
                // Update fences with successfully submitted timestamps
                let successfulTimestamps = Array(timestampsToSubmit.prefix(batchSuccessCount))
                if !successfulTimestamps.isEmpty {
                    let minTimestamp = successfulTimestamps.min()!
                    let maxTimestamp = successfulTimestamps.max()!
                    fences = FenceManager.addFence(newEarliest: minTimestamp, newLatest: maxTimestamp, existingFences: fences)
                    
                    // Save updated fences
                    do {
                        try saveIMessageState(fences: fences)
                    } catch {
                        logger.warning("Failed to save iMessage collector state", metadata: ["error": error.localizedDescription])
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
            
            logger.info("Processing final batch of \(finalBatch.count) documents")
            let batchSuccessCount = try await postDocumentsToGateway(finalBatch, batchMode: params.batchMode)
            logger.info("Posted final batch to gateway", metadata: [
                "batch_size": String(finalBatch.count),
                "posted_to_gateway": String(batchSuccessCount),
                "submission_mode": params.batchMode ? "batch" : "single"
            ])
            
            // Update submitted count
            submittedCount += batchSuccessCount
            
            // Update fences with successfully submitted timestamps
            let successfulTimestamps = Array(finalTimestamps.prefix(batchSuccessCount))
            if !successfulTimestamps.isEmpty {
                let minTimestamp = successfulTimestamps.min()!
                let maxTimestamp = successfulTimestamps.max()!
                fences = FenceManager.addFence(newEarliest: minTimestamp, newLatest: maxTimestamp, existingFences: fences)
                
                // Save updated fences
                do {
                    try saveIMessageState(fences: fences)
                } catch {
                    logger.warning("Failed to save iMessage collector state", metadata: ["error": error.localizedDescription])
                }
                
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

        return (documents: allDocuments, submittedCount: submittedCount)
    }
    
    private func createChatDbSnapshot(sourcePath: String) throws -> String {
        // Use ~/.haven/chat_backup directory like the Python collector
        let havenDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".haven/chat_backup")
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
        let attachments: [AttachmentData]
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
             m.date_delivered, m.is_from_me, m.is_read, cmj.chat_id, m.service
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
                attachments: attachments
            ))
        }
        
        return messages
    }

    private func fetchMessageRowIds(db: OpaquePointer, params: CollectorParams) throws -> [Int64] {
        var ids: [Int64] = []
        // Use canonical timestamp: message.date (not date_read or date_delivered)
        // This is the message's primary timestamp used for all processing, fences, and ordering
        
        // Determine effective lower-bound (explicit since preferred)
        var lowerBoundEpoch: Int64? = nil
        if let since = params.since {
            lowerBoundEpoch = dateToAppleEpoch(since)
        } else if params.messageLookbackDays > 0 {
            let lookbackDate = Date().addingTimeInterval(-Double(params.messageLookbackDays) * 24 * 3600)
            lowerBoundEpoch = dateToAppleEpoch(lookbackDate)
        }
        
        // Determine upper-bound (until constraint)
        let upperBoundEpoch: Int64? = params.until != nil ? dateToAppleEpoch(params.until!) : nil

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

    private func fetchMessageByRowId(db: OpaquePointer, rowId: Int64) throws -> MessageData? {
        let query = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, m.date, m.date_read,
                   m.date_delivered, m.is_from_me, m.is_read, cmj.chat_id, m.service
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
                attachments: attachments
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
        // Prefer the user's standard Caches directory: ~/Library/Caches/Haven
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return caches.appendingPathComponent("Haven", isDirectory: true)
        }

        // Fallback for older installations: ~/.haven/cache
        let raw = "~/.haven/cache"
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func iMessageCacheFileURL() -> URL {
        let dir = iMessageCacheDirURL()
        let fileName = "imessage_state.json"
        return dir.appendingPathComponent(fileName)
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
    
    // MARK: - Document Building
    
    private func isMessageEmpty(message: MessageData) -> Bool {
        // Check if message has text
        let hasText = !(message.text?.isEmpty ?? true)
        
        // Check if message has attributed body (we'll decode it in buildDocument if text is empty)
        let hasAttributedBody = message.attributedBody != nil && message.attributedBody!.count > 0
        
        // Check if message has attachments
        let hasAttachments = !message.attachments.isEmpty
        
        // Message is empty if it has no text, no attributed body, and no attachments
        // Note: We check for attributedBody existence but don't decode it here to avoid duplicate work.
        // If a message has an attributedBody, buildDocument will try to decode it.
        // Empty messages (unsent/retracted) typically have NULL attributedBody or empty attributedBody
        return !hasText && !hasAttributedBody && !hasAttachments
    }
    
    private func buildDocument(message: MessageData, thread: ThreadData, attachments: [[String: Any]]) throws -> [String: Any] {
        // Extract message text
        var messageText = message.text ?? ""
        if messageText.isEmpty, let attrBody = message.attributedBody {
            messageText = decodeAttributedBody(attrBody) ?? ""
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
        let ingestionTimestamp = ISO8601DateFormatter().string(from: Date())
        
        // Build people array
        let sender = message.isFromMe ? "me" : (thread.participants.first ?? "unknown")
        let people = buildPeople(sender: sender, participants: thread.participants, isFromMe: message.isFromMe)
        
        // Build thread payload
        let threadExternalId = "imessage:\(thread.guid)"
        let threadPayload: [String: Any] = [
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
        
        // Build metadata
        let metadata: [String: Any] = [
            "source": "imessage",
            "ingested_at": ingestionTimestamp,
            "message_guid": message.guid,
            "thread_guid": thread.guid,
            "service": message.service ?? "iMessage"
        ]
        
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
            "content_timestamp_type": message.isFromMe ? "sent" : "received",
            "people": people,
            "thread": threadPayload,
            "facet_overrides": [
                "has_attachments": !attachments.isEmpty,
                "attachment_count": attachments.count
            ]
        ]
        
        if !attachments.isEmpty {
            document["attachments"] = attachments
        }
        
        return document
    }
    
    private func buildPeople(sender: String, participants: [String], isFromMe: Bool) -> [[String: Any]] {
        var people: [[String: Any]] = []
        
        if !sender.isEmpty && sender != "me" {
            people.append([
                "identifier": sender,
                "identifier_type": inferIdentifierType(sender),
                "role": isFromMe ? "recipient" : "sender"
            ])
        }
        
        for participant in participants where participant != sender {
            people.append([
                "identifier": participant,
                "identifier_type": inferIdentifierType(participant),
                "role": "recipient"
            ])
        }
        
        return people
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
    
    // MARK: - Response Encoding
    
    private func encodeAdapterResponse(
        scanned: Int,
        matched: Int,
        submitted: Int,
        skipped: Int,
        earliestTouched: String?,
        latestTouched: String?,
        warnings: [String],
        errors: [String]
    ) -> HTTPResponse {
        // Emit an adapter-standard payload so RunRouter can decode and incorporate it into
        // the canonical RunResponse envelope. Fields required by RunResponse.AdapterResult
        // are: scanned, matched, submitted, skipped, earliest_touched, latest_touched,
        // warnings, errors.
        var obj: [String: Any] = [:]
        obj["scanned"] = scanned
        obj["matched"] = matched
        obj["submitted"] = submitted
        obj["skipped"] = skipped
        obj["earliest_touched"] = earliestTouched
        obj["latest_touched"] = latestTouched
        obj["warnings"] = warnings
        obj["errors"] = errors

        do {
            // Use JSONSerialization to allow mixed Any -> Data conversion with sorted keys
            let final = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: final
            )
        } catch {
            logger.error("Failed to encode iMessage adapter payload", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "Failed to encode response")
        }
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
                           !cleaned.contains("streamtyped") && !cleaned.contains("NSObject") {
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
                       !cleaned.contains("NSDictionary") {
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
                       !trimmed.contains("NSDictionary") {
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
               !trimmed.contains("NSObject") {
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
        // Create CharacterSet with control characters (0x00-0x05)
        var controlCharSet = CharacterSet()
        for i in 0...5 {
            controlCharSet.insert(UnicodeScalar(i)!)
        }
        
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
                !segment.contains("NSDictionary")
            }
        
        // Find the longest segment that looks like actual text
        if let longest = segments.max(by: { $0.count < $1.count }), longest.count > 3 {
            let final = longest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return final.isEmpty ? nil : final
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
                       !trimmed.hasPrefix("NS") && !trimmed.hasPrefix("__k") {
                        bestCandidate = trimmed
                    }
                    candidate = ""
                    consecutiveSpaces = 0
                }
            } else {
                // Non-printable, non-whitespace - evaluate current candidate
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > bestCandidate.count && trimmed.count > 3 &&
                   !trimmed.hasPrefix("NS") && !trimmed.hasPrefix("__k") {
                    bestCandidate = trimmed
                }
                candidate = ""
                consecutiveSpaces = 0
            }
        }
        
        // Check final candidate
        let finalTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalTrimmed.count > bestCandidate.count && finalTrimmed.count > 3 &&
           !finalTrimmed.hasPrefix("NS") && !finalTrimmed.hasPrefix("__k") {
            bestCandidate = finalTrimmed
        }
        
        return bestCandidate.isEmpty ? nil : bestCandidate
    }
    
    /// Public method for testing attributed body decoding
    func testDecodeAttributedBody(_ data: Data) -> String? {
        return decodeAttributedBody(data)
    }
    
    /// Static method for testing attributed body decoding without initialization
    static func testDecodeAttributedBodyStatic(_ data: Data) -> String? {
        let config = HavenConfig()
        let gatewayClient = GatewayClient(config: config.gateway, authToken: config.auth.secret)
        let handler = IMessageHandler(config: config, gatewayClient: gatewayClient)
        return handler.decodeAttributedBody(data)
    }
    
    /// Post a batch of documents to the gateway, preferring the batch endpoint when enabled.
    private func postDocumentsToGateway(_ documents: [[String: Any]], batchMode: Bool) async throws -> Int {
        guard !documents.isEmpty else { return 0 }

        if batchMode {
            if let batchSuccessCount = try await postDocumentsToGatewayBatch(documents) {
                return batchSuccessCount
            }
            logger.debug("Falling back to single-document ingest for batch", metadata: [
                "batch_size": String(documents.count)
            ])
        }

        return try await postDocumentsToGatewayIndividually(documents)
    }

    /// Post documents individually to the legacy ingest endpoint.
    private func postDocumentsToGatewayIndividually(_ documents: [[String: Any]]) async throws -> Int {
        var successCount = 0

        // Post each document individually since gateway batch submission may be unavailable.
        for document in documents {
            do {
                try await postDocumentToGateway(document)
                successCount += 1
            } catch {
                logger.error("Failed to post document to gateway", metadata: [
                    "error": error.localizedDescription,
                    "external_id": document["external_id"] as? String ?? "unknown"
                ])
                // Continue processing other documents even if one fails
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
            request.setValue("Bearer \(config.auth.secret)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = TimeInterval(config.gateway.timeout)
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
        request.setValue("Bearer \(config.auth.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = TimeInterval(config.gateway.timeout)
        
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
}

// MARK: - Error Types

enum CollectorError: Error, LocalizedError {
    case chatDbNotFound(String)
    case databaseOpenFailed(String)
    case snapshotFailed(String)
    case queryFailed(String)
    case invalidGatewayUrl(String)
    case invalidGatewayResponse
    case gatewayHttpError(Int, String)
    
    var errorDescription: String? {
        switch self {
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
