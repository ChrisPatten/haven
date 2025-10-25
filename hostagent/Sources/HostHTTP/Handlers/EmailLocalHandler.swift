 #if false
// EmailLocalHandler removed
// The local email collector (email_local) has been removed. Only IMAP-based email collection
// via EmailImapHandler is supported. This file is left intentionally minimal so it does not
// contribute collector functionality. If you need to fully delete this file from the repo
// use git to remove it.
        var errorsEncountered: Int
        var startTime: Date
        var endTime: Date?
        var durationMs: Int?
        
        mutating func finish(at end: Date) {
            endTime = end
            durationMs = Int(end.timeIntervalSince(startTime) * 1000)
        }
        
        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "messages_processed": messagesProcessed,
                "documents_created": documentsCreated,
                "attachments_processed": attachmentsProcessed,
                "errors_encountered": errorsEncountered,
                "start_time": isoString(from: startTime)
            ]
            if let endTime {
                dict["end_time"] = isoString(from: endTime)
            }
            if let durationMs {
                dict["duration_ms"] = durationMs
            }
            return dict
        }
        
        private func isoString(from date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
    }

    private enum SubmissionStatus: String, Codable {
        case found
        case submitted
        case accepted
        case rejected
    }

    private struct SubmissionResponseLog: Codable {
        var timestamp: Date
        var statusCode: Int?
        var body: String?
    }

    private struct IndexedMessageSnapshot: Codable {
        var rowID: Int64
        var subject: String?
        var sender: String?
        var toList: [String]
        var ccList: [String]
        var bccList: [String]
        var dateSent: Date?
        var mailboxName: String?
        var mailboxDisplayName: String?
        var mailboxPath: String?
        var flags: Int64
        var isVIP: Bool
        var remoteID: String?
        var emlxPath: String?
    var fileInode: UInt64?
    var fileMtime: Date?

        init(message: EmailIndexedMessage) {
            self.rowID = message.rowID
            self.subject = message.subject
            self.sender = message.sender
            self.toList = message.toList
            self.ccList = message.ccList
            self.bccList = message.bccList
            self.dateSent = message.dateSent
            self.mailboxName = message.mailboxName
            self.mailboxDisplayName = message.mailboxDisplayName
            self.mailboxPath = message.mailboxPath
            self.flags = message.flags
            self.isVIP = message.isVIP
            self.remoteID = message.remoteID
            self.emlxPath = message.emlxPath?.path
            self.fileInode = message.fileInode
            self.fileMtime = message.fileMtime
        }

        func toEmailIndexedMessage() -> EmailIndexedMessage? {
            let pathURL = emlxPath.map { URL(fileURLWithPath: $0) }
            let mtime = fileMtime
            return EmailIndexedMessage(
                rowID: rowID,
                subject: subject,
                sender: sender,
                toList: toList,
                ccList: ccList,
                bccList: bccList,
                dateSent: dateSent,
                mailboxName: mailboxName,
                mailboxDisplayName: mailboxDisplayName,
                mailboxPath: mailboxPath,
                flags: flags,
                isVIP: isVIP,
                remoteID: remoteID,
                emlxPath: pathURL,
                fileInode: fileInode,
                fileMtime: mtime
            )
        }
    }

    private struct SubmissionEntry: Codable {
        var key: String
        var rowID: Int64?
        var externalID: String?
        var messageId: String?
        var sourceId: String?
        var filePath: String?
        var idempotencyKey: String?
        var textHash: String?
        var status: SubmissionStatus
        var attempts: Int
        var lastAttemptAt: Date?
        var lastResponse: SubmissionResponseLog?
        var lastError: String?
        var updatedAt: Date
        var indexedMessage: IndexedMessageSnapshot?

        init(key: String, rowID: Int64?) {
            self.key = key
            self.rowID = rowID
            self.status = .found
            self.attempts = 0
            self.updatedAt = Date()
        }

        mutating func markFound() {
            status = .found
            updatedAt = Date()
        }

        mutating func markSubmitted(idempotencyKey: String, textHash: String, sourceId: String?) {
            status = .submitted
            self.idempotencyKey = idempotencyKey
            self.textHash = textHash
            self.sourceId = sourceId ?? self.sourceId
            attempts += 1
            lastAttemptAt = Date()
            updatedAt = Date()
        }

        mutating func markAccepted(response: SubmissionResponseLog?) {
            status = .accepted
            lastResponse = response
            lastError = nil
            updatedAt = Date()
        }

        mutating func markRejected(error: String, response: SubmissionResponseLog?) {
            status = .rejected
            lastError = error
            lastResponse = response
            updatedAt = Date()
        }
    }

    private struct SubmissionRunState: Codable {
        var version: Int
        var lastAcceptedRowID: Int64
        var entries: [String: SubmissionEntry]

        init(version: Int = 1, lastAcceptedRowID: Int64 = 0, entries: [String: SubmissionEntry] = [:]) {
            self.version = version
            self.lastAcceptedRowID = lastAcceptedRowID
            self.entries = entries
        }
    }

    
    private struct RunRequest: Decodable {
        let mode: String?
        let limit: Int?
        // Accept either `simulate_path` (back-compat) or the preferred `source_path`.
        let simulatePath: String?
        let sourcePath: String?
        let order: String?
        let since: String?
        let until: String?

        enum CodingKeys: String, CodingKey {
            case mode
            case limit
            case simulatePath = "simulate_path"
            case sourcePath = "source_path"
            case order
            case since
            case until
        }
    }
    
    private enum HandlerError: LocalizedError {
        case moduleDisabled
        case alreadyRunning
        case invalidMode(String)
        case invalidLimit(Int)
        case simulatePathRequired
        case conflictingPaths
        case pathNotFound(String)
        case noEmlxFiles(String)
        case invalidRequestBody
        case lockUnavailable(String)
        case overrideNotAllowed(String)
        case invalidOrder(String)
        
        var errorDescription: String? {
            switch self {
            case .moduleDisabled:
                return "Email collector module is disabled"
            case .alreadyRunning:
                return "Collector is already running"
            case .invalidMode(let mode):
                return "Invalid mode '\(mode)': must be 'simulate' or 'real'"
            case .invalidLimit(let limit):
                return "Invalid limit '\(limit)': must be between 1 and 10_000"
            case .simulatePathRequired:
                return "simulate_path is required when mode is 'simulate'"
            case .conflictingPaths:
                return "Both source_path and simulate_path were provided; they are mutually exclusive"
            case .pathNotFound(let path):
                return "No file or directory found at path '\(path)'"
            case .noEmlxFiles(let path):
                return "No .emlx files found under '\(path)'"
            case .invalidRequestBody:
                return "Request body must be valid JSON"
            case .lockUnavailable(let reason):
                return "Email collector lock unavailable: \(reason)"
            case .overrideNotAllowed(let param):
                return "Override of '\(param)' not allowed (allow_override is false in config)"
            case .invalidOrder(let order):
                return "Invalid order '\(order)': must be 'asc' or 'desc'"
            }
        }
        
        var statusCode: Int {
            switch self {
            case .moduleDisabled:
                return 503
            case .alreadyRunning:
                return 409
            case .invalidMode, .invalidLimit, .simulatePathRequired, .conflictingPaths:
                return 400
            case .pathNotFound, .noEmlxFiles:
                return 404
            case .invalidRequestBody:
                return 400
            case .lockUnavailable:
                return 423
            case .overrideNotAllowed, .invalidOrder:
                return 400
            }
        }
    }
    
    public init(
        config: HavenConfig,
        indexedCollector: EmailIndexedCollector = EmailIndexedCollector(),
        emailCollector: (any EmailCollecting)? = nil,
        emailService: EmailService? = nil
    ) {
        self.config = config
        self.emailService = emailService ?? EmailService()
        // If config.modules.mail.sourcePath is set, initialize an indexed collector pointing at that mail root
        if let mailSource = config.modules.mail.sourcePath, !mailSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (mailSource as NSString).expandingTildeInPath
            let mailRootURL = URL(fileURLWithPath: expanded)
            let envelopeIndexURL = mailRootURL.appendingPathComponent("Envelope Index", isDirectory: false)
            self.indexedCollector = EmailIndexedCollector(mailRoot: mailRootURL, envelopeIndexOverride: envelopeIndexURL)
        } else {
            self.indexedCollector = indexedCollector
        }
        if let providedCollector = emailCollector {
            self.emailCollector = providedCollector
        } else {
            self.emailCollector = EmailCollector(
                gatewayConfig: config.gateway,
                authToken: config.auth.secret
            )
        }
        let stateConfig = config.modules.mail.state
        let stateURL = EmailLocalHandler.expandPath(stateConfig.runStatePath)
        self.runStateFileURL = stateURL
        self.clearOnNewRun = stateConfig.clearOnNewRun
        self.lockFileURL = EmailLocalHandler.expandPath(stateConfig.lockFilePath)
        self.rejectedRetentionDays = stateConfig.rejectedRetentionDays
        self.rejectedLogWriter = RejectedEmailLogWriter(
            baseURL: EmailLocalHandler.expandPath(stateConfig.rejectedLogPath),
            retentionDays: stateConfig.rejectedRetentionDays
        )
        self.runState = EmailLocalHandler.loadRunState(from: stateURL)
    }
    
    /// Handle POST /v1/collectors/email_local:run
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        do {
            try validateModuleEnabled()
        } catch {
            logger.warning("email_local run rejected", metadata: ["error": error.localizedDescription])
            return errorResponse(from: error)
        }
        
        let params: RunParameters
        do {
            params = try parseParameters(from: request)
        } catch {
            logger.warning("email_local run rejected", metadata: ["error": error.localizedDescription])
            return errorResponse(from: error)
        }
        
        do {
            try ensureNotRunning()
        } catch {
            logger.warning("email_local run rejected", metadata: ["error": error.localizedDescription])
            return errorResponse(from: error)
        }

        do {
            try acquireProcessLock()
        } catch {
            logger.warning("email_local run rejected", metadata: ["error": error.localizedDescription])
            return errorResponse(from: error)
        }
        
        isRunning = true
        defer {
            isRunning = false
            releaseProcessLock()
        }
        
        logger.info("Starting email_local run", metadata: [
            "mode": params.mode,
            "limit": "\(params.limit)",
            "simulate_path": params.sourcePath ?? "nil"
        ])
        
        lastRunStatus = .running
        lastRunTime = Date()
        lastRunError = nil
        
        var stats = CollectorStats(
            messagesProcessed: 0,
            documentsCreated: 0,
            attachmentsProcessed: 0,
            errorsEncountered: 0,
            startTime: Date(),
            endTime: nil,
            durationMs: nil
        )
        
        do {
            let result = try await runCollector(with: params, stats: &stats)
            stats.finish(at: Date())
            lastRunStats = stats
            lastRunStatus = result.partial ? .partial : .completed
            
            logger.info("email_local run finished", metadata: [
                "status": lastRunStatus.rawValue,
                "messages_processed": "\(stats.messagesProcessed)",
                "documents_created": "\(stats.documentsCreated)",
                "attachments_processed": "\(stats.attachmentsProcessed)",
                "errors": "\(stats.errorsEncountered)"
            ])
            
            return successResponse(status: lastRunStatus, params: params, stats: stats, warnings: result.warnings)
        } catch {
            stats.finish(at: Date())
            lastRunStats = stats
            lastRunStatus = .failed
            lastRunError = error.localizedDescription
            
            logger.error("email_local run failed", metadata: [
                "error": error.localizedDescription
            ])
            
            return errorResponse(from: error)
        }
    }
    
    /// Handle GET /v1/collectors/email_local/state
    public func handleState(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        let response = buildStateResponse()
        
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            logger.error("Failed to encode email_local state", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "Failed to encode state response")
        }
    }
    
    // MARK: - Run Helpers
    
    private struct RunParameters {
        let mode: String
        let limit: Int
        let sourcePath: String?
        let order: String?
        let since: Date?
        let until: Date?
    }
    
    private struct RunOutcome {
        let partial: Bool
        let warnings: [String]
        
        static let success = RunOutcome(partial: false, warnings: [])
    }

    private struct PreparedAttachment {
        let attachment: EmailAttachment
        let fileURL: URL
    }
    
    private struct PreparedSubmission {
        let key: String
        let sourceFile: URL
        let message: EmailMessage
        let document: EmailDocumentPayload
        let attachments: [PreparedAttachment]
        let indexedMetadata: EmailIndexedMessage?
        let mailboxLabel: String
    }

    private struct SubmissionTarget {
        let key: String
        let fileURL: URL
        let indexedMessage: EmailIndexedMessage?
        let mailboxLabel: String
    }
    
    private func runCollector(with params: RunParameters, stats: inout CollectorStats) async throws -> RunOutcome {
        switch params.mode {
        case "simulate":
            guard let path = params.sourcePath else {
                throw HandlerError.simulatePathRequired
            }
            return try await runSimulateMode(at: path, limit: params.limit, order: params.order, stats: &stats)
        case "real":
            return try await runRealMode(sourcePath: params.sourcePath, limit: params.limit, params: params, stats: &stats)
        default:
            throw HandlerError.invalidMode(params.mode)
        }
    }
    
    private func runSimulateMode(at path: String, limit: Int, order: String?, stats: inout CollectorStats) async throws -> RunOutcome {
        var files = try collectSimulateTargets(at: path, limit: limit)
        var warnings: [String] = []
        
        // Apply sorting if order is specified
        if let orderValue = order?.lowercased() {
            let fileManager = FileManager.default
            // Get file modification dates for sorting
            var filesWithDates: [(URL, Date?)] = files.map { url in
                let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                let modDate = attrs?[.modificationDate] as? Date
                return (url, modDate)
            }
            
            if orderValue == "desc" {
                filesWithDates.sort { (lhs, rhs) in
                    guard let lhsDate = lhs.1, let rhsDate = rhs.1 else {
                        return lhs.1 != nil
                    }
                    return lhsDate > rhsDate
                }
            } else {
                filesWithDates.sort { (lhs, rhs) in
                    guard let lhsDate = lhs.1, let rhsDate = rhs.1 else {
                        return rhs.1 != nil
                    }
                    return lhsDate < rhsDate
                }
            }
            files = filesWithDates.map { $0.0 }
        }
        
        let targets = files.enumerated().map { index, url in
            SubmissionTarget(key: "simulate-\(index)", fileURL: url, indexedMessage: nil, mailboxLabel: "simulate")
        }
        let submissions = await prepareSubmissions(from: targets, stats: &stats, warnings: &warnings)
        
        stats.documentsCreated += submissions.count
        let attachmentCount = submissions.reduce(0) { $0 + $1.attachments.count }
        stats.attachmentsProcessed += attachmentCount
        
        for submission in submissions {
            logSimulatedSubmission(submission)
        }
        
        let partial = stats.errorsEncountered > 0 || !warnings.isEmpty
        return RunOutcome(partial: partial, warnings: warnings)
    }
    
    private func runRealMode(sourcePath: String?, limit: Int, params: RunParameters, stats: inout CollectorStats) async throws -> RunOutcome {
        do {
            // If sourcePath is provided, create a collector configured for that directory
            let collector: EmailIndexedCollector
            if let path = sourcePath {
                let expandedPath = (path as NSString).expandingTildeInPath
                let mailRoot = URL(fileURLWithPath: expandedPath)
                let envelopeIndexURL = mailRoot.appendingPathComponent("Envelope Index", isDirectory: false)
                collector = EmailIndexedCollector(
                    mailRoot: mailRoot,
                    envelopeIndexOverride: envelopeIndexURL
                )
            } else {
                collector = indexedCollector
            }
            
            let result = try await collector.run(limit: limit, order: params.order, since: params.since, until: params.until)
            var warnings = result.warnings
            let fileManager = FileManager.default
            
            if clearOnNewRun && !runState.entries.isEmpty && !result.messages.isEmpty {
                logger.info("Clearing prior email collector run state", metadata: [
                    "previous_entries": "\(runState.entries.count)"
                ])
                runState.entries.removeAll()
            }
            
            var targets: [SubmissionTarget] = []
            var seenFilePaths = Set<String>()
            var seenEnvelopeKeys = Set<String>()

            for entry in runState.entries.values where entry.status == .accepted {
                if let snapshot = entry.indexedMessage {
                    if let mailbox = snapshot.mailboxPath ?? snapshot.mailboxName,
                       let remoteID = snapshot.remoteID, !remoteID.isEmpty {
                        let key = "remote:\(mailbox):\(remoteID)"
                        seenEnvelopeKeys.insert(key)
                    }
                    if let path = snapshot.emlxPath {
                        seenFilePaths.insert(path)
                    }
                }
                if let path = entry.filePath {
                    seenFilePaths.insert(path)
                }
            }

            for message in result.messages {
                guard let rawEmlxPath = message.emlxPath else {
                    let warning = "Indexed message \(message.rowID) missing .emlx path"
                    warnings.append(warning)
                    // Emit a debug-level full representation of the indexed message with human-readable timestamps.
                    let snapshot = IndexedMessageSnapshot(message: message)
                    if let json = HavenLogger.dumpJSONIfDebug(snapshot) {
                        logger.debug("Indexed message missing .emlx path - full indexed snapshot: \(json)")
                    } else {
                        // Either debug is disabled or encoding failed; log a compact description
                        logger.debug("Indexed message missing .emlx path - snapshot: \(String(describing: snapshot))")
                    }
                        logger.warning("Indexed message missing .emlx path", metadata: [
                            "rowid": "\(message.rowID)",
                            "mailbox": message.mailboxName ?? "unknown",
                            "subject": message.subject ?? "nil",
                            "date_sent": "\(iso8601String(from: message.dateSent))"
                        ])
                    stats.errorsEncountered += 1
                    continue
                }
                let emlxPath = rawEmlxPath.resolvingSymlinksInPath()

                guard fileManager.fileExists(atPath: emlxPath.path) else {
                    let warning = "Emlx file not found at \(emlxPath.path)"
                    warnings.append(warning)
                    logger.error("Indexed message referenced missing .emlx file", metadata: [
                        "rowid": "\(message.rowID)",
                        "path": emlxPath.path
                    ])
                    stats.errorsEncountered += 1
                    continue
                }

                if let mailbox = message.mailboxPath ?? message.mailboxName,
                   let remoteID = message.remoteID, !remoteID.isEmpty {
                    let envelopeKey = "remote:\(mailbox):\(remoteID)"
                    if !seenEnvelopeKeys.insert(envelopeKey).inserted {
                        let warning = "Duplicate Envelope Index entry for remoteID \(remoteID) in mailbox \(mailbox); skipping rowID \(message.rowID)"
                        warnings.append(warning)
                        logger.info("Skipping duplicate envelope entry", metadata: [
                            "rowid": "\(message.rowID)",
                            "mailbox": mailbox,
                            "remote_id": remoteID
                        ])
                        continue
                    }
                }

                if !seenFilePaths.insert(emlxPath.path).inserted {
                    let warning = "Duplicate .emlx path \(emlxPath.path) encountered for rowID \(message.rowID); skipping duplicate entry"
                    warnings.append(warning)
                    logger.info("Skipping duplicate email entry", metadata: [
                        "rowid": "\(message.rowID)",
                        "path": emlxPath.path
                    ])
                    continue
                }
                
                let mailboxLabel = message.mailboxDisplayName ?? message.mailboxName ?? "unknown"
                await MetricsCollector.shared.incrementCounter("email_local_found_total", labels: ["mailbox": mailboxLabel])
                let key = stateKey(for: message)
                registerDiscovery(key: key, message: message, fileURL: emlxPath)
                targets.append(SubmissionTarget(key: key, fileURL: emlxPath, indexedMessage: message, mailboxLabel: mailboxLabel))
            }
            
            persistRunState()
            
            if targets.isEmpty {
                let partial = stats.errorsEncountered > 0 || !warnings.isEmpty
                return RunOutcome(partial: partial, warnings: warnings)
            }
            
            var submissions = await prepareSubmissions(from: targets, stats: &stats, warnings: &warnings)

            if submissions.isEmpty {
                let partial = stats.errorsEncountered > 0 || !warnings.isEmpty
                return RunOutcome(partial: partial, warnings: warnings)
            }

            var seenSourceIds = Set(runState.entries.values.filter { $0.status == .accepted }.compactMap { $0.sourceId })
            var uniqueSubmissions: [PreparedSubmission] = []
            for submission in submissions {
                if !seenSourceIds.insert(submission.document.sourceId).inserted {
                    let rowIDDescription = submission.indexedMetadata?.rowID ?? -1
                    warnings.append("Duplicate document source_id \(submission.document.sourceId) encountered (rowID \(rowIDDescription)); skipping submission")
                    logger.info("Skipping duplicate document submission", metadata: [
                        "source_id": submission.document.sourceId,
                        "rowid": "\(rowIDDescription)"
                    ])
                    runState.entries.removeValue(forKey: submission.key)
                    continue
                }
                uniqueSubmissions.append(submission)
            }
            submissions = uniqueSubmissions
            
            if submissions.isEmpty {
                let partial = stats.errorsEncountered > 0 || !warnings.isEmpty
                return RunOutcome(partial: partial, warnings: warnings)
            }
            
            for submission in submissions {
                var entry = runState.entries[submission.key] ?? SubmissionEntry(
                    key: submission.key,
                    rowID: submission.indexedMetadata?.rowID
                )
                entry.sourceId = submission.document.sourceId
                entry.messageId = submission.message.messageId
                entry.filePath = submission.sourceFile.path
                entry.rowID = entry.rowID ?? submission.indexedMetadata?.rowID
                if let metadata = submission.indexedMetadata {
                    entry.indexedMessage = IndexedMessageSnapshot(message: metadata)
                }
                let mailboxLabel = submission.mailboxLabel
                let textHash = submission.document.metadata.contentHash
                let idempotencyKey = EmailCollector.makeDocumentIdempotencyKey(
                    sourceType: submission.document.sourceType,
                    sourceId: submission.document.sourceId,
                    textHash: textHash
                )
                entry.markSubmitted(idempotencyKey: idempotencyKey, textHash: textHash, sourceId: submission.document.sourceId)
                await MetricsCollector.shared.incrementCounter(
                    "email_local_submitted_total",
                    labels: ["mailbox": mailboxLabel]
                )
                runState.entries[submission.key] = entry
                persistRunState()
                let submissionStart = Date()
                do {
                    let response = try await emailCollector.submitEmailDocument(submission.document)
                    stats.documentsCreated += 1
                    let elapsedMs = Date().timeIntervalSince(submissionStart) * 1000
                    await MetricsCollector.shared.recordHistogram(
                        "email_local_submission_latency_ms",
                        value: elapsedMs,
                        labels: ["mailbox": mailboxLabel]
                    )
                    await MetricsCollector.shared.incrementCounter(
                        "email_local_accepted_total",
                        labels: [
                            "mailbox": mailboxLabel,
                            "duplicate": response.duplicate ? "true" : "false"
                        ]
                    )
                    entry.externalID = response.externalId
                    entry.markAccepted(response: SubmissionResponseLog(
                        timestamp: Date(),
                        statusCode: 202,
                        body: nil
                    ))
                    runState.entries[submission.key] = entry
                    persistRunState()
                    
                    for attachment in submission.attachments {
                        do {
                            _ = try await emailCollector.submitEmailAttachment(
                                fileURL: attachment.fileURL,
                                attachment: attachment.attachment,
                                messageId: submission.message.messageId,
                                intent: nil,
                                relevance: nil,
                                enrichment: nil
                            )
                            stats.attachmentsProcessed += 1
                        } catch {
                            stats.errorsEncountered += 1
                            let filename = attachment.attachment.filename ?? attachment.fileURL.lastPathComponent
                            warnings.append("Failed to submit attachment \(filename): \(error.localizedDescription)")
                            logger.error("Failed to submit email attachment", metadata: [
                                "filename": filename,
                                "error": error.localizedDescription
                            ])
                        }
                    }
                } catch {
                    let elapsedMs = Date().timeIntervalSince(submissionStart) * 1000
                    await MetricsCollector.shared.recordHistogram(
                        "email_local_submission_latency_ms",
                        value: elapsedMs,
                        labels: ["mailbox": mailboxLabel]
                    )
                    stats.errorsEncountered += 1
                    if let collectorError = error as? HostAgentEmail.EmailCollectorError {
                        switch collectorError {
                        case .gatewayHTTPError(let status, let body):
                            let responseLog = SubmissionResponseLog(timestamp: Date(), statusCode: status, body: body)
                            if (400..<500).contains(status), status != 429 {
                                entry.markRejected(error: body, response: responseLog)
                                runState.entries[submission.key] = entry
                                persistRunState()
                                logRejectedEntry(for: entry)
                                await MetricsCollector.shared.incrementCounter(
                                    "email_local_rejected_total",
                                    labels: [
                                        "mailbox": mailboxLabel,
                                        "status": "\(status)"
                                    ]
                                )
                            } else {
                                warnings.append("Failed to submit document \(submission.document.sourceId): \(collectorError.localizedDescription)")
                                entry.lastResponse = responseLog
                                entry.lastError = collectorError.localizedDescription
                                runState.entries[submission.key] = entry
                                persistRunState()
                            }
                        default:
                            warnings.append("Failed to submit document \(submission.document.sourceId): \(collectorError.localizedDescription)")
                            entry.lastError = collectorError.localizedDescription
                            runState.entries[submission.key] = entry
                            persistRunState()
                        }
                        logger.error("Failed to submit email document", metadata: [
                            "source_id": submission.document.sourceId,
                            "error": collectorError.localizedDescription
                        ])
                    } else {
                        warnings.append("Failed to submit document \(submission.document.sourceId): \(error.localizedDescription)")
                        entry.lastError = error.localizedDescription
                        runState.entries[submission.key] = entry
                        persistRunState()
                        logger.error("Failed to submit email document", metadata: [
                            "source_id": submission.document.sourceId,
                            "error": error.localizedDescription
                        ])
                    }
                    continue
                }
            }

            let acceptedRowIDs = Set(runState.entries.values.compactMap { entry -> Int64? in
                guard entry.status == .accepted else { return nil }
                return entry.rowID
            })
            let acceptedMessages = runState.entries.values.compactMap { entry -> EmailIndexedMessage? in
                guard entry.status == .accepted else { return nil }
                return entry.indexedMessage?.toEmailIndexedMessage()
            }
            if !acceptedRowIDs.isEmpty {
                let lastRowID = try await collector.commitState(acceptedRowIDs: acceptedRowIDs, acceptedMessages: acceptedMessages)
                runState.lastAcceptedRowID = lastRowID
                persistRunState()
            }
            
            let partial = stats.errorsEncountered > 0 || !warnings.isEmpty
            return RunOutcome(partial: partial, warnings: warnings)
        } catch let error as EmailCollectorError {
            if case .envelopeIndexNotFound = error {
                let warning = "Envelope Index not found; falling back to crawler mode (not yet implemented)"
                logger.warning("Indexed mode unavailable, falling back to crawler placeholder", metadata: ["warning": warning])
                return RunOutcome(partial: true, warnings: [warning])
            }
            throw error
        }
    }

    private func collectSimulateTargets(at path: String, limit: Int) throws -> [URL] {
        let expandedPath = (path as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            throw HandlerError.pathNotFound(expandedPath)
        }
        
        var files: [URL] = []
        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: expandedPath), includingPropertiesForKeys: nil) else {
                throw HandlerError.pathNotFound(expandedPath)
            }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "emlx" {
                    files.append(url)
                }
            }
        } else {
            let fileURL = URL(fileURLWithPath: expandedPath)
            if fileURL.pathExtension.lowercased() == "emlx" {
                files.append(fileURL)
            }
        }
        
        guard !files.isEmpty else {
            throw HandlerError.noEmlxFiles(expandedPath)
        }
        
        return Array(files.prefix(limit))
    }
    
    private func prepareSubmissions(from targets: [SubmissionTarget], stats: inout CollectorStats, warnings: inout [String]) async -> [PreparedSubmission] {
        var submissions: [PreparedSubmission] = []
        for target in targets {
            if let submission = await prepareSubmission(for: target, stats: &stats, warnings: &warnings) {
                submissions.append(submission)
            }
        }
        return submissions
    }
    
    private func prepareSubmission(for target: SubmissionTarget, stats: inout CollectorStats, warnings: inout [String]) async -> PreparedSubmission? {
        do {
            let message = try await emailService.parseEmlxFile(at: target.fileURL)
            stats.messagesProcessed += 1
            let document = try await emailCollector.buildDocumentPayload(email: message, intent: nil, relevance: nil)
            let attachmentResolution = await resolveAttachments(for: message, sourceFile: target.fileURL)
            if !attachmentResolution.unresolvedWarnings.isEmpty {
                warnings.append(contentsOf: attachmentResolution.unresolvedWarnings)
            }
            return PreparedSubmission(
                key: target.key,
                sourceFile: target.fileURL,
                message: message,
                document: document,
                attachments: attachmentResolution.attachments,
                indexedMetadata: target.indexedMessage,
                mailboxLabel: target.mailboxLabel
            )
        } catch {
            stats.errorsEncountered += 1
            warnings.append("Failed to prepare \(target.fileURL.lastPathComponent): \(error.localizedDescription)")
            logger.error("Failed to prepare email submission", metadata: [
                "path": target.fileURL.path,
                "error": error.localizedDescription
            ])
            return nil
        }
    }
    
    private func resolveAttachments(for message: EmailMessage, sourceFile: URL) async -> (attachments: [PreparedAttachment], unresolvedWarnings: [String]) {
        var attachments: [PreparedAttachment] = []
        var unresolved: [String] = []
        
        for (index, attachment) in message.attachments.enumerated() {
            if let resolved = await emailService.resolveAttachmentPath(for: message, partIndex: index) {
                attachments.append(PreparedAttachment(attachment: attachment, fileURL: resolved))
            } else {
                let filename = attachment.filename ?? "part-\(index)"
                let warning = "Attachment \(filename) could not be resolved for \(sourceFile.lastPathComponent)"
                unresolved.append(warning)
                logger.warning("Attachment path not resolved", metadata: [
                    "filename": filename,
                    "source": sourceFile.lastPathComponent
                ])
            }
        }
        
        return (attachments, unresolved)
    }
    
    private func logSimulatedSubmission(_ submission: PreparedSubmission) {
        var metadata: [String: String] = [
            "source_path": submission.sourceFile.path,
            "source_id": submission.document.sourceId,
            "attachment_count": "\(submission.attachments.count)"
        ]
        if let subject = submission.message.subject {
            metadata["subject"] = subject
        }
        if let messageId = submission.message.messageId {
            metadata["message_id"] = messageId
        }
        logger.info("Simulate mode: prepared email submission", metadata: metadata)
    }
    
    // MARK: - Validation & Parsing
    
    private func validateModuleEnabled() throws {
        guard config.modules.mail.enabled else {
            throw HandlerError.moduleDisabled
        }
    }
    
    private func ensureNotRunning() throws {
        guard !isRunning else {
            throw HandlerError.alreadyRunning
        }
    }
    
    private func parseParameters(from request: HTTPRequest) throws -> RunParameters {
        var mode = "real"
        var limit = 100
        var simulatePath: String?
        var order: String?
        var since: Date?
        var until: Date?

        if let body = request.body, !body.isEmpty {
            do {
                let decoder = JSONDecoder()
                let runRequest = try decoder.decode(RunRequest.self, from: body)
                if let providedMode = runRequest.mode {
                    mode = providedMode.lowercased()
                }
                if let providedLimit = runRequest.limit {
                    limit = providedLimit
                }
                // If both paths provided, that's an error. Otherwise prefer source_path (real) over simulate_path (dry-run).
                let providedSource = runRequest.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines)
                let providedSimulate = runRequest.simulatePath?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let pSource = providedSource, !pSource.isEmpty, let pSim = providedSimulate, !pSim.isEmpty {
                    throw HandlerError.conflictingPaths
                }

                if let pSource = providedSource, !pSource.isEmpty {
                    // source_path implies real mode
                    mode = "real"
                    simulatePath = pSource
                } else if let pSim = providedSimulate, !pSim.isEmpty {
                    // simulate_path implies simulate mode
                    mode = "simulate"
                    simulatePath = pSim
                }
                
                // Handle order, since, until with config fallback and override check
                let allowOverride = config.modules.mail.allowOverride
                
                if let providedOrder = runRequest.order {
                    guard allowOverride else {
                        throw HandlerError.overrideNotAllowed("order")
                    }
                    order = providedOrder
                } else if let defaultOrder = config.modules.mail.defaultOrder {
                    order = defaultOrder
                }
                
                if let providedSince = runRequest.since {
                    guard allowOverride else {
                        throw HandlerError.overrideNotAllowed("since")
                    }
                    since = parseISO8601Date(providedSince)
                } else if let defaultSince = config.modules.mail.defaultSince {
                    since = parseISO8601Date(defaultSince)
                }
                
                if let providedUntil = runRequest.until {
                    guard allowOverride else {
                        throw HandlerError.overrideNotAllowed("until")
                    }
                    until = parseISO8601Date(providedUntil)
                } else if let defaultUntil = config.modules.mail.defaultUntil {
                    until = parseISO8601Date(defaultUntil)
                }
            } catch {
                throw HandlerError.invalidRequestBody
            }
        } else {
            // No request body, use config defaults
            if let defaultOrder = config.modules.mail.defaultOrder {
                order = defaultOrder
            }
            if let defaultSince = config.modules.mail.defaultSince {
                since = parseISO8601Date(defaultSince)
            }
            if let defaultUntil = config.modules.mail.defaultUntil {
                until = parseISO8601Date(defaultUntil)
            }
        }

        guard mode == "simulate" || mode == "real" else {
            throw HandlerError.invalidMode(mode)
        }

        guard (1...10_000).contains(limit) else {
            throw HandlerError.invalidLimit(limit)
        }

        if mode == "simulate" && simulatePath == nil {
            throw HandlerError.simulatePathRequired
        }
        
        // Validate order if provided
        if let orderValue = order {
            let normalized = orderValue.lowercased()
            guard normalized == "asc" || normalized == "desc" else {
                throw HandlerError.invalidOrder(orderValue)
            }
        }

        return RunParameters(mode: mode, limit: limit, sourcePath: simulatePath, order: order, since: since, until: until)
    }
    
    private func parseISO8601Date(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }

    private func iso8601String(from date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    
    // MARK: - Response Helpers
    
    private func successResponse(status: RunStatus, params: RunParameters, stats: CollectorStats, warnings: [String]) -> HTTPResponse {
        var response: [String: Any] = [
            "status": status.rawValue,
            "mode": params.mode,
            "limit": params.limit,
            "stats": stats.toDictionary()
        ]
        // Return both keys for backward compatibility: simulate_path (legacy) and source_path (preferred)
        if let path = params.sourcePath {
            response["simulate_path"] = path
            response["source_path"] = path
        }
        if !warnings.isEmpty {
            response["warnings"] = warnings
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            logger.error("Failed to encode email_local run response", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "Failed to encode response")
        }
    }
    
    private func errorResponse(from error: Error) -> HTTPResponse {
        if let handlerError = error as? HandlerError {
            let payload: [String: Any] = [
                "error": handlerError.errorDescription ?? "Unknown error"
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: handlerError.statusCode,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } else {
            let payload: [String: Any] = [
                "error": "email_local run failed",
                "details": error.localizedDescription
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
    }
    
    private func buildStateResponse() -> [String: Any] {
        var response: [String: Any] = [
            "is_running": isRunning,
            "status": lastRunStatus.rawValue
        ]
        
        if let lastRunTime {
            response["last_run_time"] = isoString(from: lastRunTime)
        }
        if let lastRunStats {
            response["last_run_stats"] = lastRunStats.toDictionary()
        }
        if let lastRunError {
            response["last_run_error"] = lastRunError
        }
        response["run_state"] = [
            "last_accepted_rowid": runState.lastAcceptedRowID,
            "entries": sanitizedRunStateEntries()
        ]
        
        return response
    }
    
    private func sanitizedRunStateEntries() -> [[String: Any]] {
        let entries = runState.entries.values
        let mapped = entries.map { entry -> [String: Any] in
            var result: [String: Any] = [
                "key": entry.key,
                "status": entry.status.rawValue,
                "attempts": entry.attempts
            ]
            if let rowID = entry.rowID { result["row_id"] = rowID }
            if let source = entry.sourceId { result["source_id"] = source }
            if let external = entry.externalID { result["external_id"] = external }
            if let messageId = entry.messageId { result["message_id"] = messageId }
            if let idempotency = entry.idempotencyKey { result["idempotency_key"] = idempotency }
            if let lastAttempt = entry.lastAttemptAt { result["last_attempt_at"] = isoString(from: lastAttempt) }
            if let lastError = entry.lastError { result["last_error"] = lastError }
            if let lastResponse = entry.lastResponse?.body { result["last_response"] = lastResponse }
            if let snapshot = entry.indexedMessage {
                result["mailbox"] = snapshot.mailboxDisplayName ?? snapshot.mailboxName
                if result["row_id"] == nil {
                    result["row_id"] = snapshot.rowID
                }
            }
            return result
        }
        return mapped.sorted { lhs, rhs in
            let leftNumber = lhs["row_id"] as? NSNumber
            let rightNumber = rhs["row_id"] as? NSNumber
            return (leftNumber?.intValue ?? 0) < (rightNumber?.intValue ?? 0)
        }
    }
    
    private func stateKey(for message: EmailIndexedMessage) -> String {
        return String(message.rowID)
    }

    private func registerDiscovery(key: String, message: EmailIndexedMessage, fileURL: URL) {
        var entry = runState.entries[key] ?? SubmissionEntry(key: key, rowID: message.rowID)
        entry.rowID = message.rowID
        entry.filePath = fileURL.path
        entry.indexedMessage = IndexedMessageSnapshot(message: message)
        entry.markFound()
        runState.entries[key] = entry
    }

    private func logRejectedEntry(for entry: SubmissionEntry) {
        guard let textHash = entry.textHash else { return }
        let payload = RejectedEmailLogEntry(
            timestamp: Date(),
            rowID: entry.rowID,
            externalID: entry.externalID ?? entry.sourceId,
            idempotencyKey: entry.idempotencyKey,
            contentSHA: textHash,
            attempts: entry.attempts,
            lastServerResponse: entry.lastResponse?.body ?? entry.lastError
        )
        Task {
            await rejectedLogWriter.append(entry: payload)
        }
    }
    
    private func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Run State Persistence

    private static func expandPath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func loadRunState(from url: URL) -> SubmissionRunState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return SubmissionRunState()
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SubmissionRunState.self, from: data)
        } catch {
            return SubmissionRunState()
        }
    }

    private func persistRunState() {
        do {
            try ensureParentDirectoryExists(for: runStateFileURL)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(runState)
            let tempURL = runStateFileURL.appendingPathExtension("tmp")
            try data.write(to: tempURL, options: [.atomic])
            if FileManager.default.fileExists(atPath: runStateFileURL.path) {
                try FileManager.default.removeItem(at: runStateFileURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: runStateFileURL)
        } catch {
            logger.error("Failed to persist email collector run state", metadata: [
                "path": runStateFileURL.path,
                "error": error.localizedDescription
            ])
        }
    }

    private func ensureParentDirectoryExists(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw NSError(domain: "EmailLocalHandler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path exists but is not directory: \(directory.path)"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }

    private func acquireProcessLock() throws {
        guard lockHandle == nil else { return }
        try ensureParentDirectoryExists(for: lockFileURL)
        let fd = open(lockFileURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if fd < 0 {
            throw HandlerError.lockUnavailable("Failed to open lock file at \(lockFileURL.path)")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw HandlerError.lockUnavailable("Another collector instance holds the lock")
        }
        lockHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func releaseProcessLock() {
        guard let handle = lockHandle else { return }
        let fd = handle.fileDescriptor
        flock(fd, LOCK_UN)
        handle.closeFile()
        lockHandle = nil
    }
}

private struct RejectedEmailLogEntry: Codable {
    var timestamp: Date
    var rowID: Int64?
    var externalID: String?
    var idempotencyKey: String?
    var contentSHA: String
    var attempts: Int
    var lastServerResponse: String?
}

private actor RejectedEmailLogWriter {
    private let baseDirectory: URL
    private let baseName: String
    private let fileExtension: String
    private let retentionDays: Int
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter
    private let fileManager = FileManager.default
    
    init(baseURL: URL, retentionDays: Int) {
        self.baseDirectory = baseURL.deletingLastPathComponent()
        let nameComponent = baseURL.deletingPathExtension().lastPathComponent
        self.baseName = nameComponent.isEmpty ? "rejected_emails" : nameComponent
        let ext = baseURL.pathExtension
        self.fileExtension = ext.isEmpty ? "log" : ext
        self.retentionDays = retentionDays
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.dayFormatter = formatter
    }
    
    func append(entry: RejectedEmailLogEntry) async {
        do {
            try ensureDirectory()
            let dayString = dayFormatter.string(from: entry.timestamp)
            let fileURL = fileURLForDay(dayString)
            var payload = try encoder.encode(entry)
            payload.append(0x0A)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: payload)
            } else if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(payload)
            }
            try pruneOldLogs()
        } catch {
            // Swallow logging errors to avoid crashing ingestion; optionally print for debugging.
        }
    }
    
    private func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: baseDirectory.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw NSError(domain: "EmailLocalHandler", code: 2, userInfo: [NSLocalizedDescriptionKey: "Log path exists but is not directory: \(baseDirectory.path)"])
        }
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }
    
    private func fileURLForDay(_ day: String) -> URL {
        let filename = "\(baseName)-\(day).\(fileExtension)"
        return baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }
    
    private func pruneOldLogs() throws {
        guard retentionDays > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date.distantPast
        guard let contents = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }
        for url in contents {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("\(baseName)-") else { continue }
            let suffix = String(name.dropFirst(baseName.count + 1))
            guard let fileDate = dayFormatter.date(from: suffix) else { continue }
            if fileDate < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

#endif
