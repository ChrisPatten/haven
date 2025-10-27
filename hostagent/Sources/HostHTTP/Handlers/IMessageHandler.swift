import Foundation
import HavenCore
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
        
        // Parse request parameters.
        // Prefer the strict unified CollectorRunRequest shape; collector-specific
        // options must be nested under `collector_options`. Fall back to the
        // legacy top-level shape for backward compatibility.
        var params = CollectorParams()
        params.configChatDbPath = config.modules.imessage.chatDbPath
        if let body = request.body, !body.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            // Decode a lightweight local DTO matching the unified CollectorRunRequest
            // shape for the fields we care about (avoid importing HostAgent to
            // prevent circular module dependencies).
                struct UnifiedRunDTO: Codable {
                struct DateRange: Codable {
                    let since: Date?
                    let until: Date?
                }
                let mode: String?
                let timeWindow: Int?
                let dateRange: DateRange?
                let limit: Int?
                let order: String?
                enum CodingKeys: String, CodingKey {
                    case mode
                    case timeWindow = "time_window"
                    case dateRange = "date_range"
                    case limit
                    case order
                }
            }

                if let unified = try? decoder.decode(UnifiedRunDTO.self, from: body) {
                    // Map unified fields we care about
                    if let m = unified.mode { params.mode = m }
                    if let tw = unified.timeWindow { params.batchSize = tw }
                    if let l = unified.limit { params.limit = l }
                    if let o = unified.order { params.order = o }
                    if let since = unified.dateRange?.since { params.since = since }
                    if let until = unified.dateRange?.until { params.until = until }

                    // Collector-specific options must be provided under collector_options
                    if let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
                       let coll = json["collector_options"] as? [String: Any] {
                        // Support multiple aliases for batch size: batch_size, batchSize, and limit
                        params.batchSize = coll["batch_size"] as? Int ?? coll["batchSize"] as? Int ?? params.batchSize
                        // Allow collector limit and order overrides
                        params.limit = coll["limit"] as? Int ?? params.limit
                        params.order = coll["order"] as? String ?? params.order
                        params.threadLookbackDays = coll["thread_lookback_days"] as? Int ?? coll["threadLookbackDays"] as? Int ?? params.threadLookbackDays
                        params.messageLookbackDays = coll["message_lookback_days"] as? Int ?? coll["messageLookbackDays"] as? Int ?? params.messageLookbackDays
                        params.chatDbPath = coll["chat_db_path"] as? String ?? coll["chatDbPath"] as? String ?? params.chatDbPath
                    }
                } else {
                // Legacy support: accept collector-specific keys at top-level
                    if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        params.mode = json["mode"] as? String ?? params.mode
                        // Support legacy aliases for batch size (batch_size, limit)
                        params.batchSize = json["batch_size"] as? Int ?? json["limit"] as? Int ?? params.batchSize
                        params.limit = json["limit"] as? Int ?? params.limit
                        params.order = json["order"] as? String ?? params.order
                        params.threadLookbackDays = json["thread_lookback_days"] as? Int ?? params.threadLookbackDays
                        params.messageLookbackDays = json["message_lookback_days"] as? Int ?? params.messageLookbackDays
                        params.chatDbPath = json["chat_db_path"] as? String ?? params.chatDbPath

                        // Optional date_range (legacy) or top-level since/until
                        let iso = ISO8601DateFormatter()
                        if let dr = json["date_range"] as? [String: Any] {
                            if let s = dr["since"] as? String, let d = iso.date(from: s) { params.since = d }
                            if let u = dr["until"] as? String, let d = iso.date(from: u) { params.until = d }
                        }
                        if let s = json["since"] as? String, let d = iso.date(from: s) { params.since = d }
                        if let u = json["until"] as? String, let d = iso.date(from: u) { params.until = d }
                    }
            }
        }
        
        // Validate parameters
        if params.mode != "tail" && params.mode != "backfill" {
            return HTTPResponse.badRequest(message: "Invalid mode: must be 'tail' or 'backfill'")
        }
        
        logger.info("Starting iMessage collector", metadata: [
            "mode": params.mode,
            "batch_size": String(params.batchSize),
            "thread_lookback_days": String(params.threadLookbackDays),
            "message_lookback_days": String(params.messageLookbackDays)
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
            
            // Post documents to gateway
            var successCount = 0
            var failureCount = 0
            
            for document in result {
                do {
                    try await postDocumentToGateway(document)

                    // Update earliest/latest to reflect only successfully submitted docs.
                    if let contentTs = document["content_timestamp"] as? String,
                       let contentDate = ISO8601DateFormatter().date(from: contentTs) {
                        let appleTs = dateToAppleEpoch(contentDate)
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

                    successCount += 1
                } catch {
                    logger.error("Failed to post document to gateway", metadata: [
                        "error": error.localizedDescription,
                        "external_id": document["external_id"] as? String ?? "unknown"
                    ])
                    failureCount += 1
                }
            }
            
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = failureCount == 0 ? "completed" : "partial"
            lastRunStats = stats
            
            logger.info("iMessage collection completed", metadata: [
                "documents": String(result.count),
                "posted": String(successCount),
                "failed": String(failureCount),
                "duration_ms": String(stats.durationMs ?? 0)
            ])
            
            // Build response
            // Add earliest/latest touched timestamps at top level for easy consumption
            var response: [String: Any] = [
                "status": failureCount == 0 ? "success" : "partial",
                "posted": successCount,
                "failed": failureCount,
                "stats": stats.toDict
            ]
            if let earliest = stats.earliestMessageTimestamp {
                response["earliest_touched_message_timestamp"] = appleEpochToISO8601(earliest)
                // Standardized adapter field
                response["earliest_touched"] = appleEpochToISO8601(earliest)
            } else {
                // Ensure adapter payload always contains the key (null when unknown)
                response["earliest_touched_message_timestamp"] = NSNull()
                response["earliest_touched"] = NSNull()
            }
            if let latest = stats.latestMessageTimestamp {
                response["latest_touched_message_timestamp"] = appleEpochToISO8601(latest)
                // Standardized adapter field
                response["latest_touched"] = appleEpochToISO8601(latest)
            } else {
                response["latest_touched_message_timestamp"] = NSNull()
                response["latest_touched"] = NSNull()
            }

            // Adapter-standard fields for RunRouter normalization
            response["scanned"] = stats.messagesProcessed
            response["matched"] = stats.documentsCreated
            response["submitted"] = successCount
            response["skipped"] = failureCount
            response["warnings"] = [String]()
            response["errors"] = failureCount > 0 ? ["Some documents failed to post"] : [String]()

            let responseData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])

            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
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
        var mode: String = "tail"
        var batchSize: Int = 500
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
    
    private func collectMessages(params: CollectorParams, stats: inout CollectorStats) async throws -> [[String: Any]] {
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
        
        // Load persisted state (last and earliest processed row IDs)
        var lastProcessedRowId: Int64? = nil
        var earliestProcessedRowIdCache: Int64? = nil
        do {
            if let state = try loadIMessageState() {
                lastProcessedRowId = state.last
                earliestProcessedRowIdCache = state.earliest
            }
        } catch {
            logger.warning("Failed to load iMessage collector state", metadata: ["error": error.localizedDescription])
        }

        // Retrieve candidate message ROWIDs within the lookback window (ascending)
        let rowIds = try fetchMessageRowIds(db: db!, params: params)
        // Track total candidates
        stats.messagesProcessed = rowIds.count

        // NOTE: Do NOT set earliest/latest here from the scanned result set.
        // earliest/latest should reflect submitted documents only. These will be
        // updated during the posting loop in `handleRun` after a document is
        // successfully submitted to the Gateway.

        // Compose processing order based on cached state
        // Convert optional since/until dates to Apple epoch Int64 for comparisons
        let sinceEpoch: Int64? = params.since != nil ? dateToAppleEpoch(params.since!) : nil
        let untilEpoch: Int64? = params.until != nil ? dateToAppleEpoch(params.until!) : nil

        let orderedRowIds = composeProcessingOrder(
            searchResultAsc: rowIds,
            lastProcessedId: lastProcessedRowId,
            order: params.order,
            since: params.since,
            before: params.until,
            oldestCachedId: earliestProcessedRowIdCache
        )

        // Build thread lookup for messages we will process by fetching threads for all chat IDs encountered
        // We'll lazily fetch the thread when processing each message to avoid fetching unnecessary threads.

        var documents: [[String: Any]] = []
        var processedCount = 0
        var earliestProcessedRowId: Int64? = nil

        // Iterate ordered rows and prepare documents. Stop when since/until reached
        // or when batch/limit thresholds are met.
        var stopProcessing = false
        for rowId in orderedRowIds {
            // Fetch the message row
            guard let message = try fetchMessageByRowId(db: db!, rowId: rowId) else { continue }

            // If date bounds are specified, check them and stop processing when reached
            if let s = sinceEpoch {
                if message.date < s {
                    // We've reached messages older than `since` — stop processing
                    break
                }
            }
            if let u = untilEpoch {
                if message.date > u {
                    // We've reached messages newer than `until` (before) — stop processing
                    break
                }
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
            documents.append(document)
            stats.documentsCreated += 1
            processedCount += 1

            // Track earliest processed rowId
            if let prev = earliestProcessedRowId {
                if rowId < prev { earliestProcessedRowId = rowId }
            } else {
                earliestProcessedRowId = rowId
            }

            // Persist last/earliest processed IDs after each document is prepared
            do {
                let lastToSave = max(lastProcessedRowId ?? 0, rowId)
                try saveIMessageState(last: lastToSave, earliest: earliestProcessedRowId)
            } catch {
                logger.warning("Failed to save iMessage collector state", metadata: ["error": error.localizedDescription])
            }

            // Respect overall limit (if provided) and batch size
            if let lim = params.limit, lim > 0, documents.count >= lim {
                stopProcessing = true
            }
            if documents.count >= params.batchSize {
                stopProcessing = true
            }

            if stopProcessing { break }
        }

        return documents
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
        sqlite3_bind_int(stmt, bindIndex, Int32(params.batchSize * 2)) // Fetch more to allow filtering
        
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
        // Determine effective lower-bound (explicit since preferred)
        var lowerBoundEpoch: Int64? = nil
        if let since = params.since {
            lowerBoundEpoch = dateToAppleEpoch(since)
        } else if params.messageLookbackDays > 0 {
            let lookbackDate = Date().addingTimeInterval(-Double(params.messageLookbackDays) * 24 * 3600)
            lowerBoundEpoch = dateToAppleEpoch(lookbackDate)
        }

        var query = """
            SELECT m.ROWID
            FROM message m

            """
        if lowerBoundEpoch != nil {
            query += "WHERE m.date >= ?\n"
        }
        query += "ORDER BY m.ROWID ASC\n"

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

        if let lb = lowerBoundEpoch {
            sqlite3_bind_int64(stmt, 1, lb)
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

    private func loadIMessageState() throws -> (last: Int64?, earliest: Int64?)? {
        let url = iMessageCacheFileURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let obj = try decoder.decode([String: Int64].self, from: data)
        let last = obj["last_processed_rowid"]
        let earliest = obj["earliest_processed_rowid"]
        return (last: last, earliest: earliest)
    }

    private func saveIMessageState(last: Int64, earliest: Int64?) throws {
        let url = iMessageCacheFileURL()
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var obj: [String: Int64] = ["last_processed_rowid": last]
        if let e = earliest { obj["earliest_processed_rowid"] = e }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(obj)
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
            // Process newer messages newest->oldest, then older-than-cache newest->oldest
            let newDesc = Array(newerAsc.reversed())
            if let oldestCached = cachedIds.first {
                let olderThanCacheDesc = Array(uidsSortedAsc.filter { $0 < oldestCached }.reversed())
                return newDesc + olderThanCacheDesc
            } else {
                // No cached ids: just return all in descending order
                return Array(uidsSortedAsc.reversed())
            }
        } else {
            // Ascending ordering: process all matching messages in ascending order.
            // The version tracker will handle deduplication for already-processed messages,
            // so we don't need to skip the cached range at the ordering level.
            return uidsSortedAsc
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
    
    private func buildDocument(message: MessageData, thread: ThreadData, attachments: [[String: Any]]) throws -> [String: Any] {
        // Extract message text
        var messageText = message.text ?? ""
        if messageText.isEmpty, let attrBody = message.attributedBody {
            messageText = decodeAttributedBody(attrBody) ?? ""
        }
        if messageText.isEmpty {
            messageText = "[empty message]"
        }
        
        // Format timestamps
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
    
    // MARK: - Utilities
    
    private func dateToAppleEpoch(_ date: Date) -> Int64 {
        let appleEpoch = Date(timeIntervalSince1970: 978307200) // 2001-01-01 00:00:00 UTC
        let delta = date.timeIntervalSince(appleEpoch)
        return Int64(delta * 1_000_000_000) // Convert to nanoseconds
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
    
    private func decodeAttributedBody(_ data: Data) -> String? {
        // Try to extract plain text from NSAttributedString archive
        // This is a simplified version - the Python collector has more sophisticated handling
        
        do {
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                // Try to find the string content
                if let objects = plist["$objects"] as? [Any] {
                    for obj in objects {
                        if let str = obj as? String, !str.isEmpty, str.count > 3 {
                            // Filter out metadata strings
                            if !str.hasPrefix("NS") && !str.hasPrefix("$") {
                                return str
                            }
                        }
                    }
                }
            }
        } catch {
            // Fallback: try to extract UTF-8 text directly from binary data
            if let text = String(data: data, encoding: .utf8) {
                let cleaned = text.filter { $0.isPrintable || $0.isNewline }
                let segments = cleaned.components(separatedBy: "\0").filter { $0.count > 10 }
                if let longest = segments.max(by: { $0.count < $1.count }) {
                    return longest.trimmingCharacters(in: .controlCharacters)
                }
            }
        }
        
        return nil
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
