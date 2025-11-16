import Foundation
import HavenCore
import Email
import HostAgentEmail
import IMAP

public actor EmailImapHandler {
    private let config: HavenConfig
    private let emailCollector: any EmailCollecting
    private let emailService: EmailService
    private let baseSecretResolver: SecretResolving
    private let logger = HavenLogger(category: "email-imap-handler")
    
    // Enrichment support
    private let enrichmentOrchestrator: EnrichmentOrchestrator?
    private let submitter: DocumentSubmitter?
    private let enrichmentQueue: EnrichmentQueue?
    private let skipEnrichment: Bool
    
    // State tracking
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunStats: CollectorStats?
    private var lastRunError: String?
    
    private struct CollectorStats: Codable {
        var messagesProcessed: Int
        var documentsCreated: Int
        var attachmentsProcessed: Int
        var startTime: Date
        var endTime: Date?
        var durationMs: Int?
        var scanned: Int
        var matched: Int
        var submitted: Int
        var skipped: Int
        var batches: Int
        
        var toDict: [String: Any] {
            var dict: [String: Any] = [
                "messages_processed": messagesProcessed,
                "documents_created": documentsCreated,
                "attachments_processed": attachmentsProcessed,
                "scanned": scanned,
                "matched": matched,
                "submitted": submitted,
                "skipped": skipped,
                "batches": batches,
                "start_time": ISO8601DateFormatter().string(from: startTime)
            ]
            if let endTime = endTime {
                dict["end_time"] = ISO8601DateFormatter().string(from: endTime)
            }
            if let durationMs = durationMs {
                dict["duration_ms"] = durationMs
            }
            return dict
        }
    }
    
    public init(
        config: HavenConfig,
        emailCollector: (any EmailCollecting)? = nil,
        emailService: EmailService? = nil,
        secretResolver: SecretResolving = KeychainSecretResolver(),
        enrichmentOrchestrator: EnrichmentOrchestrator? = nil,
        enrichmentQueue: EnrichmentQueue? = nil,
        submitter: DocumentSubmitter? = nil,
        skipEnrichment: Bool = false
    ) {
        self.config = config
        if let providedCollector = emailCollector {
            self.emailCollector = providedCollector
        } else {
            self.emailCollector = EmailCollector(
                gatewayConfig: config.gateway,
                authToken: config.service.auth.secret,
                sourceType: "email",
                sourceIdPrefix: "email_imap",
                moduleRedaction: config.modules.mail.redactPii,
                sourceRedaction: nil // Will be set per-source in handleRun
            )
        }
        self.emailService = emailService ?? EmailService()
        self.baseSecretResolver = secretResolver
        self.enrichmentOrchestrator = enrichmentOrchestrator
        self.enrichmentQueue = enrichmentQueue
        self.submitter = submitter
        self.skipEnrichment = skipEnrichment
        
        // Load persisted state (lazy loading on first getCollectorState call)
    }
    
    // MARK: - Direct Swift APIs
    
    /// Internal collection result structure
    private struct CollectionResult {
        let totalFound: Int
        let processed: Int
        let submitted: Int
        let errors: [ImapRunError]
        let earliestTouched: Date?
        let latestTouched: Date?
    }
    
    /// Core collection logic extracted from handleRun for reuse by both handleRun and runCollector
    private func performCollection(
        accountsToProcess: [MailSourceConfig],
        folder: String?,
        limit: Int?,
        maxLimit: Int?,
        order: String,
        reset: Bool,
        sinceDate: Date?,
        beforeDate: Date?,
        dryRun: Bool,
        concurrency: Int,
        credentials: ImapCredentials?,
        batchMode: Bool,
        batchSize: Int,
        onProgress: ((Int, Int, Int, Int) -> Void)?
    ) async throws -> CollectionResult {
        let resolvedFetchBatchSize = max(1, batchSize)
        let resolvedSubmissionBatchSize = batchMode ? resolvedFetchBatchSize : 1
        
        // limit: if omitted or 0 -> unlimited. If provided >0, honor it but clamp to maxLimit when maxLimit > 0.
        let providedLimit = limit ?? 0
        let maxLimitValue = maxLimit ?? 0
        let globalLimit: Int
        if providedLimit == 0 {
            globalLimit = 0 // 0 means unlimited
        } else if maxLimitValue > 0 {
            globalLimit = min(max(providedLimit, 1), maxLimitValue)
        } else {
            globalLimit = max(providedLimit, 1)
        }
        let fetchConcurrency = max(1, min(concurrency, 12))
        
        // Helper: process one account and return per-account results
        func processAccount(
            _ account: MailSourceConfig,
            remainingGlobalLimit: Int
        ) async -> (accountId: String, totalFound: Int, processed: Int, submitted: Int, results: [ImapMessageResult], errors: [ImapRunError], earliestTouched: Date?, latestTouched: Date?) {
            
            // Determine folders to process: explicit folder in the request wins, otherwise
            // process all configured folders (or INBOX if none configured).
            let foldersToProcess: [String]
            if let reqFolder = folder, !reqFolder.isEmpty {
                // Request specifies a single folder - use it
                foldersToProcess = [reqFolder]
                logger.debug("Using request-specified folder", metadata: [
                    "account": account.responseIdentifier,
                    "folder": reqFolder
                ])
            } else if let accountFolders = account.folders, !accountFolders.isEmpty {
                // Filter out empty folder names and use configured folders
                let validFolders = accountFolders.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if validFolders.isEmpty {
                    // All folders were empty, fall back to INBOX
                    logger.warning("All configured folders were empty, defaulting to INBOX", metadata: [
                        "account": account.responseIdentifier
                    ])
                    foldersToProcess = ["INBOX"]
                } else {
                    foldersToProcess = validFolders
                    logger.debug("Using configured account folders", metadata: [
                        "account": account.responseIdentifier,
                        "configured_count": "\(accountFolders.count)",
                        "valid_count": "\(validFolders.count)"
                    ])
                }
            } else {
                // No folders configured - default to INBOX
                foldersToProcess = ["INBOX"]
                logger.debug("No folders configured, defaulting to INBOX", metadata: [
                    "account": account.responseIdentifier
                ])
            }
            
            logger.info("Processing IMAP account", metadata: [
                "account": account.responseIdentifier,
                "folders": foldersToProcess.joined(separator: ","),
                "folder_count": "\(foldersToProcess.count)"
            ])
            
            guard let authResolution = resolveAuth(for: account, credentials: credentials) else {
                logger.error("Unable to resolve IMAP credentials", metadata: ["account": account.debugIdentifier])
                return (accountId: account.responseIdentifier, totalFound: 0, processed: 0, submitted: 0, results: [], errors: [ImapRunError(uid: 0, reason: "Unable to resolve IMAP credentials")], earliestTouched: nil, latestTouched: nil)
            }
            
            let security: ImapSessionConfiguration.Security = (account.tls ?? true) ? .tls : .plaintext
            let imapConfig = ImapSessionConfiguration(
                hostname: account.host ?? "",
                port: UInt32(account.port ?? 993),
                username: account.username ?? "",
                security: security,
                auth: authResolution.auth,
                timeout: 60,
                fetchConcurrency: fetchConcurrency,
                allowsInsecurePlainAuth: !(account.tls ?? true)
            )
            
            let imapSession: ImapSession
            do {
                imapSession = try ImapSession(configuration: imapConfig, secretResolver: authResolution.resolver)
            } catch {
                logger.error("Failed to instantiate IMAP session", metadata: [
                    "account": account.debugIdentifier,
                    "error": error.localizedDescription
                ])
                return (accountId: account.responseIdentifier, totalFound: 0, processed: 0, submitted: 0, results: [], errors: [ImapRunError(uid: 0, reason: "Failed to initialize IMAP session: \(error.localizedDescription)")], earliestTouched: nil, latestTouched: nil)
            }
            
            // Helper: process one folder and return per-folder results
            func processFolder(
                _ folder: String,
                remainingGlobalLimit: Int,
                fetchBatchSize: Int,
                submissionBatchSize: Int,
                batchMode: Bool
            ) async -> (totalFound: Int, processed: Int, submitted: Int, results: [ImapMessageResult], errors: [ImapRunError], earliestTouched: Date?, latestTouched: Date?) {
                do {
                    // Load persisted fences BEFORE searching to optimize what we fetch
                    // Skip loading fences if debug mode is enabled
                    let ignoreFences = config.debug.enabled
                    var fences: [FenceRange] = []
                    if !ignoreFences {
                    do {
                        fences = try loadImapState(account: account, folder: folder)
                        logger.info("Loaded IMAP fences", metadata: [
                            "account": account.responseIdentifier,
                            "folder": folder,
                            "fence_count": String(fences.count)
                        ])
                    } catch {
                        logger.warning("Failed to load IMAP account state", metadata: ["account": account.responseIdentifier, "folder": folder, "error": error.localizedDescription])
                        }
                    } else {
                        logger.info("Debug mode enabled: ignoring fences", metadata: [
                            "account": account.responseIdentifier,
                            "folder": folder
                        ])
                    }
                    
                    if reset == true {
                        logger.info("IMAP run requested reset; clearing fences", metadata: ["account": account.responseIdentifier, "folder": folder])
                        fences = []
                    }

                    // Calculate gaps in fences (time ranges not covered by fences)
                    // These are the ranges we need to search for new messages
                    // When debug mode is enabled, create a gap covering the entire requested range
                    let gaps: [FenceRange]
                    if ignoreFences {
                        // Create a single gap covering the entire requested range
                        // Use Unix epoch (1970-01-01) instead of Date.distantPast (year 1) for IMAP compatibility
                        let gapSince = sinceDate ?? Date(timeIntervalSince1970: 0)
                        let gapBefore = beforeDate ?? Date()
                        gaps = [FenceRange(earliest: gapSince, latest: gapBefore)]
                        logger.info("Debug mode: creating gap covering entire requested range", metadata: [
                            "account": account.responseIdentifier,
                            "folder": folder,
                            "since": gapSince.description,
                            "before": gapBefore.description
                        ])
                    } else {
                        gaps = Self.calculateGaps(
                        fences: fences,
                        requestedSince: sinceDate,
                        requestedBefore: beforeDate
                    )
                    }
                    
                    logger.info("Calculated fence gaps for IMAP search", metadata: [
                        "account": account.responseIdentifier,
                        "folder": folder,
                        "fence_count": "\(fences.count)",
                        "gap_count": "\(gaps.count)",
                        "requested_since": sinceDate?.description ?? "nil",
                        "requested_before": beforeDate?.description ?? "nil",
                        "debug_mode": String(ignoreFences)
                    ])
                    
                    // If there are no gaps (everything is fenced), skip searching
                    // Skip this check if debug mode is enabled
                    if !ignoreFences && gaps.isEmpty && !fences.isEmpty {
                        logger.info("All requested time range is covered by fences, skipping IMAP search", metadata: [
                            "account": account.responseIdentifier,
                            "folder": folder
                        ])
                        return (totalFound: 0, processed: 0, submitted: 0, results: [], errors: [], earliestTouched: nil, latestTouched: nil)
                    }

                    // Perform searches for each gap and combine results
                    var allUIDs: Set<UInt32> = []
                    for (index, gap) in gaps.enumerated() {
                        // If no explicit beforeDate was provided, use current time right before search
                        // This ensures we catch messages that arrived between gap creation and search execution
                        // The gap.latest was set to Date() at gap creation time, but we want the current time
                        let searchBefore: Date = beforeDate ?? Date()
                        
                        logger.info("Searching IMAP gap \(index + 1)/\(gaps.count)", metadata: [
                            "account": account.responseIdentifier,
                            "folder": folder,
                            "gap_since": gap.earliest.description,
                            "gap_before": gap.latest.description,
                            "search_before": searchBefore.description,
                            "had_explicit_before": beforeDate != nil ? "true" : "false"
                        ])
                        let gapResults = try await imapSession.searchMessages(
                            folder: folder,
                            since: gap.earliest,
                            before: searchBefore
                        )
                        allUIDs.formUnion(gapResults)
                        logger.debug("IMAP gap search completed", metadata: [
                            "account": account.responseIdentifier,
                            "folder": folder,
                            "gap_index": "\(index + 1)",
                            "found_in_gap": "\(gapResults.count)",
                            "total_unique": "\(allUIDs.count)"
                        ])
                    }
                    
                    let searchResult = Array(allUIDs)
                    logger.info("IMAP search completed (all gaps)", metadata: [
                        "account": account.responseIdentifier,
                        "folder": folder,
                        "total_found": "\(searchResult.count)",
                        "gaps_searched": "\(gaps.count)"
                    ])
                    let uidsSortedAsc = searchResult.sorted()
                    
                    // Order UIDs based on requested order
                    let orderedUIDs = Self.composeProcessingOrder(
                        searchResultAsc: uidsSortedAsc,
                        lastProcessedUid: 0,
                        order: order,
                        since: sinceDate,
                        before: beforeDate,
                        oldestCachedUid: nil
                    )
                    
                    logger.info("Processing order determined", metadata: [
                        "account": account.responseIdentifier,
                        "folder": folder,
                        "ordered_count": "\(orderedUIDs.count)",
                        "existing_fences": String(fences.count)
                    ])
                    
                    var processedCount = 0
                    var submittedCount = 0
                    var results: [ImapMessageResult] = []
                    var errors: [ImapRunError] = []
                    var earliestProcessedDate: Date? = nil
                    var latestProcessedDate: Date? = nil
                    var pendingSubmissions: [PendingImapSubmission] = []
                    
                    let sourcePrefix = "email_imap/\(account.responseIdentifier)"
                    let fetchBatch = max(1, fetchBatchSize)
                    let submitBatch = max(1, submissionBatchSize)
                    
                    var processedSoFar = 0
                    var stopProcessing = false
                    
                    func flushPendingSubmissions(force: Bool = false) async {
                        guard !pendingSubmissions.isEmpty else { return }
                        if !force && pendingSubmissions.count < submitBatch {
                            return
                        }
                        
                        do {
                            let preferBatch = batchMode && pendingSubmissions.count > 1
                            let payloads = pendingSubmissions.map(\.payload)
                            let outcomes = try await emailCollector.submitEmailDocuments(payloads, preferBatch: preferBatch)
                            if outcomes.count != pendingSubmissions.count {
                                logger.warning("Gateway batch response size mismatch", metadata: [
                                    "account": account.responseIdentifier,
                                    "folder": folder,
                                    "expected": "\(pendingSubmissions.count)",
                                    "actual": "\(outcomes.count)"
                                ])
                            }
                            
                            // Collect successfully submitted timestamps for fence updates
                            var successfulTimestamps: [Date] = []
                            
                            for (index, pending) in pendingSubmissions.enumerated() {
                                let outcome: EmailCollectorSubmissionResult
                                if index < outcomes.count {
                                    outcome = outcomes[index]
                                } else {
                                    outcome = EmailCollectorSubmissionResult(
                                        statusCode: 502,
                                        submission: nil,
                                        errorCode: "INGEST.BATCH_MISSING_RESULT",
                                        errorMessage: "Batch response missing entry for index \(index)",
                                        retryable: true
                                    )
                                }
                                
                                if let submission = outcome.submission {
                                    submittedCount += 1
                                    let entry = ImapMessageResult(
                                        uid: pending.uid,
                                        messageId: pending.payload.metadata.messageId,
                                        status: submission.status,
                                        submissionId: submission.submissionId,
                                        docId: submission.docId,
                                        duplicate: submission.duplicate
                                    )
                                    results.append(entry)
                                    
                                    if let msgDate = pending.messageDate {
                                        successfulTimestamps.append(msgDate)
                                        
                                        if let prev = earliestProcessedDate {
                                            if msgDate < prev { earliestProcessedDate = msgDate }
                                        } else {
                                            earliestProcessedDate = msgDate
                                        }
                                        if let prev = latestProcessedDate {
                                            if msgDate > prev { latestProcessedDate = msgDate }
                                        } else {
                                            latestProcessedDate = msgDate
                                        }
                                    }
                                    
                                    // Report progress
                                    onProgress?(processedCount, processedCount, submittedCount, max(0, processedCount - submittedCount))
                                } else {
                                    let reason = outcome.errorMessage ?? outcome.errorCode ?? "Batch submission failed"
                                    errors.append(ImapRunError(uid: pending.uid, reason: reason))
                                }
                            }
                            
                            // Update fences with successfully submitted timestamps
                            // Skip fence updates if debug mode is enabled
                            if !ignoreFences && !successfulTimestamps.isEmpty {
                                let minTimestamp = successfulTimestamps.min()!
                                let maxTimestamp = successfulTimestamps.max()!
                                fences = FenceManager.addFence(newEarliest: minTimestamp, newLatest: maxTimestamp, existingFences: fences)
                                
                                // Save updated fences
                                do {
                                    try saveImapState(account: account, folder: folder, fences: fences)
                                } catch {
                                    logger.warning("Failed to save IMAP account state", metadata: [
                                        "account": account.responseIdentifier,
                                        "folder": folder,
                                        "error": error.localizedDescription
                                    ])
                                }
                            }
                            
                            if globalLimit > 0 && submittedCount >= globalLimit {
                                stopProcessing = true
                            }
                        } catch {
                            logger.error("Failed to submit IMAP batch", metadata: [
                                "account": account.debugIdentifier,
                                "folder": folder,
                                "error": error.localizedDescription
                            ])
                            for pending in pendingSubmissions {
                                errors.append(ImapRunError(uid: pending.uid, reason: error.localizedDescription))
                            }
                        }
                        
                        pendingSubmissions.removeAll()
                    }
                    
                    while processedSoFar < orderedUIDs.count && !stopProcessing {
                        let remaining = orderedUIDs.count - processedSoFar
                        let thisBatchSize = min(fetchBatch, remaining)
                        let startIndex = processedSoFar
                        let endIndex = processedSoFar + thisBatchSize
                        let batchUIDs = Array(orderedUIDs[startIndex..<endIndex])
                        
                        logger.info("Processing IMAP batch", metadata: ["account": account.responseIdentifier, "folder": folder, "batch_start": "\(startIndex)", "batch_count": "\(batchUIDs.count)"])
                        
                        for uid in batchUIDs {
                            do {
                                let data = try await imapSession.fetchRFC822(folder: folder, uid: uid)
                                let message = try await emailService.parseRFC822Data(data)
                                processedCount += 1
                                
                                // Check if message timestamp is within any fence - if so, skip
                                // Skip fence check if debug mode is enabled
                                if !ignoreFences, let msgDate = message.date, FenceManager.isTimestampInFences(msgDate, fences: fences) {
                                    logger.debug("Skipping message within fence", metadata: [
                                        "account": account.responseIdentifier,
                                        "folder": folder,
                                        "uid": String(uid),
                                        "timestamp": ISO8601DateFormatter().string(from: msgDate)
                                    ])
                                    continue
                                }
                                
                                if ignoreFences, let msgDate = message.date {
                                    logger.debug("Debug mode: ignoring fences, processing message", metadata: [
                                        "account": account.responseIdentifier,
                                        "folder": folder,
                                        "uid": String(uid),
                                        "timestamp": ISO8601DateFormatter().string(from: msgDate)
                                    ])
                                }
                                
                                // If date bounds are specified, check them and skip/stop based on processing order
                                if let msgDate = message.date {
                                    if order == "desc" {
                                        if let before = beforeDate, msgDate > before {
                                            logger.debug("Skipping message after until date", metadata: [
                                                "account": account.responseIdentifier,
                                                "folder": folder,
                                                "uid": String(uid),
                                                "message_date": ISO8601DateFormatter().string(from: msgDate),
                                                "until": ISO8601DateFormatter().string(from: before)
                                            ])
                                            continue
                                        }
                                        if let since = sinceDate, msgDate < since {
                                            logger.info("Reached since date constraint, stopping processing")
                                            stopProcessing = true
                                            break
                                        }
                                    } else {
                                        if let since = sinceDate, msgDate < since {
                                            logger.debug("Skipping message before since date", metadata: [
                                                "account": account.responseIdentifier,
                                                "folder": folder,
                                                "uid": String(uid),
                                                "message_date": ISO8601DateFormatter().string(from: msgDate),
                                                "since": ISO8601DateFormatter().string(from: since)
                                            ])
                                            continue
                                        }
                                        if let before = beforeDate, msgDate > before {
                                            logger.info("Reached until date constraint, stopping processing")
                                            stopProcessing = true
                                            break
                                        }
                                    }
                                }
                                
                                // Use new architecture: collectAndSubmit
                                if let emailCollectorActor = emailCollector as? EmailCollector {
                                    let submissionResult = try await emailCollectorActor.collectAndSubmit(
                                        email: message,
                                        enrichmentOrchestrator: enrichmentOrchestrator,
                                        enrichmentQueue: enrichmentQueue,
                                        submitter: submitter,
                                        skipEnrichment: skipEnrichment,
                                        config: config,
                                        intent: nil,
                                        relevance: nil
                                    )
                                    
                                    if dryRun {
                                        // For dry run, extract message ID from email
                                        let messageId = message.messageId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).trimmingCharacters(in: .whitespacesAndNewlines)
                                        let entry = ImapMessageResult(
                                            uid: uid,
                                            messageId: messageId?.isEmpty == false ? messageId : nil,
                                            status: "dry_run",
                                            submissionId: nil,
                                            docId: nil,
                                            duplicate: nil
                                        )
                                        results.append(entry)
                                        continue
                                    }
                                    
                                    // Handle submission result
                                    if submissionResult.success, let submission = submissionResult.submission {
                                        submittedCount += 1
                                        let entry = ImapMessageResult(
                                            uid: uid,
                                            messageId: submission.docId, // Use docId as message identifier
                                            status: submission.status,
                                            submissionId: submission.submissionId,
                                            docId: submission.docId,
                                            duplicate: submission.duplicate
                                        )
                                        results.append(entry)
                                        
                                        if let msgDate = message.date {
                                            if let prev = earliestProcessedDate {
                                                if msgDate < prev { earliestProcessedDate = msgDate }
                                            } else {
                                                earliestProcessedDate = msgDate
                                            }
                                            if let prev = latestProcessedDate {
                                                if msgDate > prev { latestProcessedDate = msgDate }
                                            } else {
                                                latestProcessedDate = msgDate
                                            }
                                        }
                                        
                                        // Report progress
                                        onProgress?(processedCount, processedCount, submittedCount, max(0, processedCount - submittedCount))
                                        
                                        // Update fences if needed
                                        // Skip fence updates if debug mode is enabled
                                        if !ignoreFences, let msgDate = message.date {
                                            fences = FenceManager.addFence(newEarliest: msgDate, newLatest: msgDate, existingFences: fences)
                                            try? saveImapState(account: account, folder: folder, fences: fences)
                                        }
                                    } else {
                                        let reason = submissionResult.error ?? "Submission failed"
                                        errors.append(ImapRunError(uid: uid, reason: reason))
                                    }
                                    
                                    if globalLimit > 0 && submittedCount >= globalLimit {
                                        stopProcessing = true
                                        break
                                    }
                                } else {
                                    // Fallback to old architecture if collector doesn't support new method
                                    let payload = try await emailCollector.buildDocumentPayload(
                                        email: message,
                                        intent: nil,
                                        relevance: nil,
                                        sourceType: "email",
                                        sourceIdPrefix: sourcePrefix,
                                        sourceAccountId: account.responseIdentifier
                                    )
                                    
                                    if dryRun {
                                        let entry = ImapMessageResult(
                                            uid: uid,
                                            messageId: payload.metadata.messageId,
                                            status: "dry_run",
                                            submissionId: nil,
                                            docId: nil,
                                            duplicate: nil
                                        )
                                        results.append(entry)
                                        continue
                                    }
                                    
                                    if globalLimit > 0 && remainingGlobalLimit <= 0 {
                                        stopProcessing = true
                                        break
                                    }
                                    
                                    pendingSubmissions.append(
                                        PendingImapSubmission(
                                            uid: uid,
                                            payload: payload,
                                            messageDate: message.date
                                        )
                                    )
                                    
                                    await flushPendingSubmissions(force: false)
                                }
                                
                                if stopProcessing {
                                    break
                                }
                            } catch {
                                logger.error("Failed to process IMAP message", metadata: [
                                    "account": account.debugIdentifier,
                                    "folder": folder,
                                    "uid": "\(uid)",
                                    "error": error.localizedDescription
                                ])
                                errors.append(ImapRunError(uid: uid, reason: error.localizedDescription))
                            }
                        }
                        
                        await flushPendingSubmissions(force: stopProcessing)
                        
                        processedSoFar += batchUIDs.count
                        if stopProcessing { break }
                    }
                    
                    await flushPendingSubmissions(force: true)
                    
                    return (totalFound: searchResult.count, processed: processedCount, submitted: submittedCount, results: results, errors: errors, earliestTouched: earliestProcessedDate, latestTouched: latestProcessedDate)
                } catch {
                    logger.error("IMAP search failed", metadata: [
                        "account": account.debugIdentifier,
                        "folder": folder,
                        "error": error.localizedDescription
                    ])
                    return (totalFound: 0, processed: 0, submitted: 0, results: [], errors: [ImapRunError(uid: 0, reason: error.localizedDescription)], earliestTouched: nil, latestTouched: nil)
                }
            }
            
            // Iterate folders, aggregating results
            var accountTotalFound = 0
            var accountProcessed = 0
            var accountSubmitted = 0
            var accountResults: [ImapMessageResult] = []
            var accountErrors: [ImapRunError] = []
            var accountEarliestTouched: Date? = nil
            var accountLatestTouched: Date? = nil
            
            for folder in foldersToProcess {
                let remainingAllowed = (remainingGlobalLimit > 0) ? max(0, remainingGlobalLimit - accountSubmitted) : 0
                let folderResult = await processFolder(
                    folder,
                    remainingGlobalLimit: remainingAllowed,
                    fetchBatchSize: resolvedFetchBatchSize,
                    submissionBatchSize: resolvedSubmissionBatchSize,
                    batchMode: batchMode
                )
                
                logger.info("Folder processing completed", metadata: [
                    "account": account.responseIdentifier,
                    "folder": folder,
                    "totalFound": "\(folderResult.totalFound)",
                    "processed": "\(folderResult.processed)",
                    "submitted": "\(folderResult.submitted)"
                ])
                
                accountTotalFound += folderResult.totalFound
                accountProcessed += folderResult.processed
                accountSubmitted += folderResult.submitted
                accountResults.append(contentsOf: folderResult.results)
                accountErrors.append(contentsOf: folderResult.errors)
                
                if let e = folderResult.earliestTouched {
                    if let prev = accountEarliestTouched { if e < prev { accountEarliestTouched = e } } else { accountEarliestTouched = e }
                }
                if let l = folderResult.latestTouched {
                    if let prev = accountLatestTouched { if l > prev { accountLatestTouched = l } } else { accountLatestTouched = l }
                }
                
                if remainingGlobalLimit > 0 && accountSubmitted >= remainingGlobalLimit {
                    break
                }
            }
            
            return (accountId: account.responseIdentifier, totalFound: accountTotalFound, processed: accountProcessed, submitted: accountSubmitted, results: accountResults, errors: accountErrors, earliestTouched: accountEarliestTouched, latestTouched: accountLatestTouched)
        }
        
        // Iterate accounts, aggregating results
        var totalFoundSum = 0
        var processedSum = 0
        var submittedSum = 0
        var errorsAll: [ImapRunError] = []
        var earliestTouchedGlobal: Date? = nil
        var latestTouchedGlobal: Date? = nil
        
        for account in accountsToProcess {
            let remainingAllowed = (globalLimit > 0) ? max(0, globalLimit - submittedSum) : 0
            let accountResult = await processAccount(account, remainingGlobalLimit: remainingAllowed)
            
            logger.info("Account processing completed", metadata: [
                "account": accountResult.accountId,
                "totalFound": "\(accountResult.totalFound)",
                "processed": "\(accountResult.processed)",
                "submitted": "\(accountResult.submitted)"
            ])
            
            totalFoundSum += accountResult.totalFound
            processedSum += accountResult.processed
            submittedSum += accountResult.submitted
            errorsAll.append(contentsOf: accountResult.errors)
            
            if let e = accountResult.earliestTouched {
                if let prev = earliestTouchedGlobal { if e < prev { earliestTouchedGlobal = e } } else { earliestTouchedGlobal = e }
            }
            if let l = accountResult.latestTouched {
                if let prev = latestTouchedGlobal { if l > prev { latestTouchedGlobal = l } } else { latestTouchedGlobal = l }
            }
            
            if globalLimit > 0 && submittedSum >= globalLimit {
                break
            }
        }
        
        return CollectionResult(
            totalFound: totalFoundSum,
            processed: processedSum,
            submitted: submittedSum,
            errors: errorsAll,
            earliestTouched: earliestTouchedGlobal,
            latestTouched: latestTouchedGlobal
        )
    }
    
    /// Get current collector state
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
    
    /// Direct Swift API for running the IMAP collector
    /// Replaces HTTP-based handleRun for in-app integration
    public func runCollector(
        request: CollectorRunRequest?,
        onProgress: ((Int, Int, Int, Int) -> Void)? = nil
    ) async throws -> RunResponse {
        // Check if already running
        guard !isRunning else {
            throw CollectorError.alreadyRunning("Collector is already running")
        }
        
        // Convert CollectorRunRequest to internal representation
        // Extract parameters from CollectorRunRequest (similar to handleRun logic)
        var accountId: String? = nil
        var folder: String? = nil
        var limit: Int?
        var maxLimit: Int?
        var order: String?
        var reset: Bool?
        var sinceDate: Date?
        var beforeDate: Date?
        var dryRun: Bool = false
        var concurrency: Int = 4
        var credentials: ImapCredentials?
        var batchMode: Bool = true  // Default to true for IMAP
        var batchSize: Int? = 200   // Default to 200 for IMAP
        
        if let req = request {
            // Top-level fields
            limit = req.limit
            order = req.order?.rawValue ?? "desc"
            concurrency = req.concurrency ?? 4
            batchMode = req.batch ?? true
            batchSize = req.batchSize ?? 200
            
            // Date range
            if let dateRange = req.dateRange {
                sinceDate = dateRange.since
                beforeDate = dateRange.until
            }
            
            // Mode -> dryRun
            dryRun = ((req.mode ?? .real) == .simulate)
            
            // Extract IMAP-specific scope
            let scopeDict = req.scope?.value as? [String: Any] ?? [:]
            if let imapScope = scopeDict["imap"] as? [String: Any] {
                reset = (imapScope["reset"] as? Bool) ?? false
                if let folderStr = imapScope["folder"] as? String ?? imapScope["mailbox"] as? String {
                    folder = folderStr
                }
                accountId = imapScope["account_id"] as? String
                maxLimit = imapScope["max_limit"] as? Int
                
                // Handle credentials
                if let creds = imapScope["credentials"] as? [String: Any] {
                    let kindStr = creds["kind"] as? String ?? "secret"
                    credentials = ImapCredentials(
                        kind: kindStr,
                        secret: creds["secret"] as? String,
                        secretRef: creds["secret_ref"] as? String
                    )
                }
            }
        }
        
        // Get accounts to process
        let accountsToProcess: [MailSourceConfig]
        if let accountId = accountId, !accountId.isEmpty {
            guard let account = selectAccount(identifier: accountId) else {
                throw NSError(domain: "EmailImapHandler", code: 400, userInfo: [NSLocalizedDescriptionKey: "IMAP account not found: \(accountId)"])
            }
            accountsToProcess = [account]
        } else {
            let imapAccounts = (config.modules.mail.sources ?? [])
                .filter { $0.type == "imap" && $0.enabled }
            if imapAccounts.isEmpty {
                throw NSError(domain: "EmailImapHandler", code: 400, userInfo: [NSLocalizedDescriptionKey: "No enabled IMAP accounts found"])
            }
            accountsToProcess = imapAccounts
        }
        
        logger.info("Starting IMAP collector run", metadata: [
            "account_count": "\(accountsToProcess.count)",
            "accounts": accountsToProcess.map { $0.responseIdentifier }.joined(separator: ","),
            "batch_mode": batchMode ? "true" : "false",
            "batch_size": batchSize.map(String.init) ?? "default"
        ])
        
        // Initialize response and state tracking
        let runID = UUID().uuidString
        let startTime = Date()
        var response = RunResponse(collector: "email_imap", runID: runID, startedAt: startTime)
        
        isRunning = true
        lastRunTime = startTime
        lastRunStatus = "running"
        lastRunError = nil
        
        // Use defer to ensure isRunning is always reset, even on cancellation
        defer {
            isRunning = false
        }
        
        var stats = CollectorStats(
            messagesProcessed: 0,
            documentsCreated: 0,
            attachmentsProcessed: 0,
            startTime: startTime,
            endTime: nil,
            durationMs: nil,
            scanned: 0,
            matched: 0,
            submitted: 0,
            skipped: 0,
            batches: 0
        )
        
        do {
            // Call the internal collection method
            let result = try await performCollection(
                accountsToProcess: accountsToProcess,
                folder: folder,
                limit: limit,
                maxLimit: maxLimit,
                order: order ?? "desc",
                reset: reset ?? false,
                sinceDate: sinceDate,
                beforeDate: beforeDate,
                dryRun: dryRun,
                concurrency: concurrency,
                credentials: credentials,
                batchMode: batchMode,
                batchSize: batchSize ?? 200,
                onProgress: onProgress
            )
            
            // Update state tracking
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            stats.messagesProcessed = result.processed
            stats.documentsCreated = result.submitted
            stats.scanned = result.totalFound
            stats.matched = result.processed
            stats.submitted = result.submitted
            stats.skipped = result.totalFound - result.processed
            stats.batches = (result.submitted > 0) ? max(1, result.submitted / max(1, batchSize ?? 200)) : 0
            
            lastRunTime = endTime
            lastRunStats = stats
            
            if result.errors.isEmpty {
                lastRunStatus = "ok"
            } else if result.submitted > 0 {
                lastRunStatus = "partial"
            } else {
                lastRunStatus = "failed"
                lastRunError = result.errors.map { $0.reason }.joined(separator: "; ")
            }
            
            // Persist state
            await savePersistedState()
            
            // Build RunResponse
            response.finish(
                status: result.errors.isEmpty ? .ok : (result.submitted > 0 ? .partial : .error),
                finishedAt: endTime
            )
            response.stats = RunResponse.Stats(
                scanned: result.totalFound,
                matched: result.processed,
                submitted: result.submitted,
                skipped: max(0, result.totalFound - result.processed),
                earliest_touched: result.earliestTouched.map { RunResponse.iso8601UTC($0) },
                latest_touched: result.latestTouched.map { RunResponse.iso8601UTC($0) },
                batches: stats.batches
            )
            response.warnings = []
            response.errors = result.errors.map { $0.reason }
            
            return response
        } catch {
            // Check if this is a cancellation error
            let isCancelled = error is CancellationError
            
            // Update state tracking on error
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            lastRunTime = endTime
            lastRunStats = stats
            
            if isCancelled {
                lastRunStatus = "cancelled"
                lastRunError = "Collection was cancelled"
                logger.info("IMAP collection cancelled")
            } else {
                lastRunStatus = "failed"
                lastRunError = error.localizedDescription
                logger.error("IMAP collection failed", metadata: ["error": error.localizedDescription])
            }
            
            // Persist state
            await savePersistedState()
            
            response.finish(status: .error, finishedAt: endTime)
            response.stats = RunResponse.Stats(
                scanned: stats.scanned,
                matched: stats.matched,
                submitted: stats.submitted,
                skipped: stats.skipped,
                earliest_touched: nil,
                latest_touched: nil,
                batches: stats.batches
            )
            response.warnings = []
            response.errors = [error.localizedDescription]
            
            throw error
        }
    }
    
    // MARK: - Helpers
    
    private func selectAccount(identifier: String?) -> MailSourceConfig? {
        // Load accounts from config.modules.mail.sources
        // If identifier is provided, match by id; otherwise return first enabled IMAP account
        let imapAccounts = (config.modules.mail.sources ?? [])
            .filter { $0.type == "imap" && $0.enabled }
        
        if let identifier = identifier, !identifier.isEmpty {
            return imapAccounts.first { $0.id == identifier }
        }
        
        // Return first enabled IMAP account if no identifier provided
        return imapAccounts.first
    }
    
    private struct ImapCredentials {
        var kind: String
        var secret: String?
        var secretRef: String?
    }
    
    private func resolveAuth(for account: MailSourceConfig, credentials: ImapCredentials?) -> AuthResolution? {
        var resolvers: [any SecretResolving] = []
        var secretRef = credentials?.secretRef ?? account.auth?.secretRef ?? ""
        
        if let inlineSecret = credentials?.secret, !inlineSecret.isEmpty {
            let inlineRef = "inline://\(UUID().uuidString)"
            resolvers.append(InlineSecretResolver(storage: [inlineRef: Data(inlineSecret.utf8)]))
            secretRef = inlineRef
        }
        
        resolvers.append(baseSecretResolver)
        if secretRef.isEmpty {
            return nil
        }
        
        let kind = (credentials?.kind ?? account.auth?.kind ?? "app_password").lowercased()
        let auth: ImapSessionConfiguration.Auth
        switch kind {
        case "app_password", "app-password", "password", "basic":
            auth = .appPassword(secretRef: secretRef)
        case "xoauth2":
            auth = .xoauth2(secretRef: secretRef)
        default:
            logger.error("Unsupported IMAP auth kind", metadata: ["kind": kind])
            return nil
        }
        
        let resolver: SecretResolving
        if resolvers.count == 1 {
            resolver = resolvers[0]
        } else {
            resolver = ChainSecretResolver(resolvers)
        }
        
        return AuthResolution(auth: auth, resolver: resolver)
    }
    
    // MARK: - DTOs
    
    private struct AuthResolution {
        let auth: ImapSessionConfiguration.Auth
        let resolver: SecretResolving
    }
    
    private struct ImapRunResponse: Encodable {
        var accountId: String
        var folder: String
        var totalFound: Int
        var processed: Int
        var submitted: Int
        var dryRun: Bool
        var since: Date?
        var before: Date?
        var results: [ImapMessageResult]
        var errors: [ImapRunError]
    }
    
    private struct ImapMessageResult: Encodable {
        var uid: UInt32
        var messageId: String?
        var status: String
        var submissionId: String?
        var docId: String?
        var duplicate: Bool?
    }

    private struct PendingImapSubmission {
        var uid: UInt32
        var payload: EmailDocumentPayload
        var messageDate: Date?
    }
    
    private struct ImapRunError: Encodable {
        var uid: UInt32
        var reason: String
    }
}

extension EmailImapHandler {
    /// Compose the UID processing order based on the server search results (ascending),
    /// the cached-most-recent UID, and the requested order. This mirrors the logic used
    /// by `handleRun` and is exposed for unit testing.
    static func composeProcessingOrder(
        searchResultAsc: [UInt32],
        lastProcessedUid: UInt32,
        order: String?,
        since: Date?,
        before: Date?,
        oldestCachedUid: UInt32? = nil
    ) -> [UInt32] {
        let uidsSortedAsc = searchResultAsc.sorted()
        let normalizedOrder = order?.lowercased()

        // If the caller provides an explicit oldestCachedUid (test-only), use that to
        // determine the cached range. Otherwise, fall back to treating all UIDs <=
        // lastProcessedUid as cached (best-effort given stored state only records
        // the most-recent UID).
        let cachedUIDs: [UInt32]
        if let oldest = oldestCachedUid {
            cachedUIDs = uidsSortedAsc.filter { $0 >= oldest && $0 <= lastProcessedUid }
        } else {
            cachedUIDs = uidsSortedAsc.filter { $0 <= lastProcessedUid }
        }
        let newerUIDsAsc = uidsSortedAsc.filter { $0 > lastProcessedUid }

        if normalizedOrder == "desc" {
            // Process newer messages newest->oldest, then older-than-cache newest->oldest
            let newDesc = Array(newerUIDsAsc.reversed())
            if let oldestCached = cachedUIDs.first {
                let olderThanCacheDesc = Array(uidsSortedAsc.filter { $0 < oldestCached }.reversed())
                return newDesc + olderThanCacheDesc
            } else {
                // No cached uids: just return all in descending order
                return Array(uidsSortedAsc.reversed())
            }
        } else {
            // Ascending ordering
            if since != nil {
                // Start at oldest messages (ascending) until oldest cached. Then append newer-than-cache ascending.
                if let oldestCached = cachedUIDs.first {
                    let beforeCache = uidsSortedAsc.filter { $0 < oldestCached }
                    return beforeCache + newerUIDsAsc
                } else {
                    // No cached uids: process all ascending
                    return uidsSortedAsc
                }
            } else {
                // No since specified: process older-than-cache ascending, then newer-than-cache ascending.
                if let oldestCached = cachedUIDs.first {
                    let beforeCacheAsc = uidsSortedAsc.filter { $0 < oldestCached }
                    return beforeCacheAsc + newerUIDsAsc
                } else {
                    // no cached uids: process all ascending
                    return uidsSortedAsc
                }
            }
        }
    }
    
    /// Test IMAP connection and list folders (direct Swift API)
    public struct TestConnectionResult {
        public let success: Bool
        public let error: String?
        public let folders: [ImapFolder]?
        
        public init(success: Bool, error: String? = nil, folders: [ImapFolder]? = nil) {
            self.success = success
            self.error = error
            self.folders = folders
        }
    }
    
    public func testConnection(
        host: String,
        port: Int,
        tls: Bool,
        username: String,
        authKind: String,
        secretRef: String?
    ) async -> TestConnectionResult {
        do {
            // Resolve authentication
            let auth: ImapSessionConfiguration.Auth
            let resolver: SecretResolving
            
            switch authKind {
            case "app_password":
                if let secretRef = secretRef, !secretRef.isEmpty {
                    resolver = baseSecretResolver
                    auth = .appPassword(secretRef: secretRef)
                } else {
                    return TestConnectionResult(success: false, error: "secretRef must be provided")
                }
            case "xoauth2":
                if let secretRef = secretRef, !secretRef.isEmpty {
                    resolver = baseSecretResolver
                    auth = .xoauth2(secretRef: secretRef)
                } else {
                    return TestConnectionResult(success: false, error: "secretRef must be provided")
                }
            default:
                return TestConnectionResult(success: false, error: "Unsupported auth kind: \(authKind)")
            }
            
            // Create IMAP session configuration
            let security: ImapSessionConfiguration.Security = tls ? .tls : .plaintext
            let imapConfig = ImapSessionConfiguration(
                hostname: host,
                port: UInt32(port),
                username: username,
                security: security,
                auth: auth,
                timeout: 30,
                fetchConcurrency: 1,
                allowsInsecurePlainAuth: !tls
            )
            
            // Create session and test connection by listing folders
            let imapSession = try ImapSession(configuration: imapConfig, secretResolver: resolver)
            let folders = try await imapSession.listFolders()
            
            return TestConnectionResult(success: true, error: nil, folders: folders)
        } catch {
            // Log detailed error information
            let errorDescription: String
            if let imapError = error as? ImapSessionError {
                errorDescription = imapError.localizedDescription
            } else if let resolverError = error as? SecretResolverError {
                errorDescription = resolverError.localizedDescription ?? error.localizedDescription
            } else {
                errorDescription = error.localizedDescription
            }
            
            logger.error("IMAP connection test failed", metadata: [
                "error": errorDescription,
                "error_type": String(describing: type(of: error))
            ])
            
            return TestConnectionResult(success: false, error: errorDescription, folders: nil)
        }
    }
}


// MARK: - Fence Management
// Uses shared FenceManager from HavenCore

// MARK: - IMAP account state persistence

private extension EmailImapHandler {
    func cacheDirURL() -> URL {
        // Use HavenFilePaths for remote mail cache directory
        return HavenFilePaths.remoteMailCacheDirectory
    }

    func cacheFileURL(for account: MailSourceConfig, folder: String) -> URL {
        let dir = cacheDirURL()
        var folderName = folder
        // sanitize folder for filesystem
        folderName = folderName.replacingOccurrences(of: "/", with: "_")
        folderName = folderName.replacingOccurrences(of: " ", with: "_")
        let fileName = "imap_state_\(account.responseIdentifier)_\(folderName).json"
        return dir.appendingPathComponent(fileName)
    }

    func loadImapState(account: MailSourceConfig, folder: String) throws -> [FenceRange] {
        let url = cacheFileURL(for: account, folder: folder)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let fences = try FenceManager.loadFences(from: data, oldFormatType: [String: Int].self)
        if fences.isEmpty && !data.isEmpty {
            logger.info("Detected old IMAP state format, starting fresh with timestamp-based fences", metadata: [
                "account": account.responseIdentifier,
                "folder": folder
            ])
        }
        return fences
    }

    func saveImapState(account: MailSourceConfig, folder: String, fences: [FenceRange]) throws {
        let url = cacheFileURL(for: account, folder: folder)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try FenceManager.saveFences(fences)
        try data.write(to: url, options: .atomic)
    }
    
    /// Calculate gaps in fences (time ranges not covered by fences) within the requested date range
    /// Returns an array of FenceRange objects representing the gaps that need to be searched
    static func calculateGaps(fences: [FenceRange], requestedSince: Date?, requestedBefore: Date?) -> [FenceRange] {
        // If no fences, search the entire requested range (or all if no range specified)
        guard !fences.isEmpty else {
            if let since = requestedSince, let before = requestedBefore {
                // Both dates specified - return single gap
                return [FenceRange(earliest: since, latest: before)]
            } else if let since = requestedSince {
                // Only since specified - search from since to now
                return [FenceRange(earliest: since, latest: Date())]
            } else if let before = requestedBefore {
                // Only before specified - search from beginning to before
                // Use a very old date as beginning (e.g., 1970)
                return [FenceRange(earliest: Date(timeIntervalSince1970: 0), latest: before)]
            } else {
                // No date range - search everything (use very old date to now)
                return [FenceRange(earliest: Date(timeIntervalSince1970: 0), latest: Date())]
            }
        }
        
        // Merge and sort fences
        let mergedFences = FenceManager.mergeFences(fences).sorted { $0.earliest < $1.earliest }
        
        // Determine the effective search range
        let searchStart: Date
        let searchEnd: Date
        
        if let since = requestedSince {
            searchStart = since
        } else {
            // No since date - start from earliest fence or beginning of time
            searchStart = mergedFences.first?.earliest ?? Date(timeIntervalSince1970: 0)
        }
        
        if let before = requestedBefore {
            searchEnd = before
        } else {
            // No before date - end at latest fence or now
            searchEnd = max(mergedFences.last?.latest ?? Date(), Date())
        }
        
        // If search range is invalid, return empty
        guard searchStart < searchEnd else {
            return []
        }
        
        var gaps: [FenceRange] = []
        
        // Check for gap before first fence
        if let firstFence = mergedFences.first, searchStart < firstFence.earliest {
            gaps.append(FenceRange(earliest: searchStart, latest: firstFence.earliest))
        }
        
        // Check for gaps between fences
        for i in 0..<(mergedFences.count - 1) {
            let currentFence = mergedFences[i]
            let nextFence = mergedFences[i + 1]
            
            // If there's a gap between fences and it overlaps with search range
            if currentFence.latest < nextFence.earliest {
                let gapStart = max(currentFence.latest, searchStart)
                let gapEnd = min(nextFence.earliest, searchEnd)
                
                if gapStart < gapEnd {
                    gaps.append(FenceRange(earliest: gapStart, latest: gapEnd))
                }
            }
        }
        
        // Check for gap after last fence
        if let lastFence = mergedFences.last, lastFence.latest < searchEnd {
            gaps.append(FenceRange(earliest: lastFence.latest, latest: searchEnd))
        }
        
        // If no fences overlap with search range, return entire search range as gap
        if gaps.isEmpty {
            // Check if search range is completely outside all fences
            let allFencesBeforeSearch = mergedFences.allSatisfy { $0.latest < searchStart }
            let allFencesAfterSearch = mergedFences.allSatisfy { $0.earliest > searchEnd }
            
            if allFencesBeforeSearch || allFencesAfterSearch {
                gaps.append(FenceRange(earliest: searchStart, latest: searchEnd))
            }
        }
        
        return gaps
    }
    
    // MARK: - Handler State Persistence
    
    private func handlerStateFileURL() -> URL {
        let dir = cacheDirURL()
        return dir.appendingPathComponent("imap_handler_state.json")
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
            
            logger.info("Loaded persisted IMAP handler state", metadata: [
                "lastRunStatus": lastRunStatus,
                "hasLastRunTime": lastRunTime != nil ? "true" : "false"
            ])
        } catch {
            logger.warning("Failed to load persisted IMAP handler state", metadata: ["error": error.localizedDescription])
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
            logger.warning("Failed to save persisted IMAP handler state", metadata: ["error": error.localizedDescription])
        }
    }
}
