import Foundation
import HavenCore
@_spi(Generated) import OpenAPIRuntime
import Email
import HostAgentEmail
import IMAP

public actor EmailImapHandler {
    private let config: HavenConfig
    private let emailCollector: any EmailCollecting
    private let emailService: EmailService
    private let baseSecretResolver: SecretResolving
    private let logger = HavenLogger(category: "email-imap-handler")
    
    public init(
        config: HavenConfig,
        emailCollector: (any EmailCollecting)? = nil,
        emailService: EmailService? = nil,
        secretResolver: SecretResolving = KeychainSecretResolver()
    ) {
        self.config = config
        if let providedCollector = emailCollector {
            self.emailCollector = providedCollector
        } else {
            self.emailCollector = EmailCollector(
                gatewayConfig: config.gateway,
                authToken: config.auth.secret,
                sourceType: "email",
                sourceIdPrefix: "email_imap",
                moduleRedaction: config.modules.mail.redactPii,
                sourceRedaction: nil // Will be set per-source in handleRun
            )
        }
        self.emailService = emailService ?? EmailService()
        self.baseSecretResolver = secretResolver
    }
    
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.mail.enabled else {
            return HTTPResponse.badRequest(message: "mail module is disabled")
        }
        
        // Parse request using OpenAPI-generated types
        var runRequest: Components.Schemas.RunRequest?
        
        if let body = request.body, !body.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                runRequest = try decoder.decode(Components.Schemas.RunRequest.self, from: body)
            } catch {
                logger.warning("Failed to decode RunRequest", metadata: ["error": error.localizedDescription])
                return HTTPResponse.badRequest(message: "Invalid request format: \(error.localizedDescription)")
            }
        }
        
        // Extract parameters
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
        var batchMode: Bool = false
        var batchSize: Int? = nil
        
        if let req = runRequest {
            // Top-level fields
            limit = req.limit ?? config.defaultLimit
            order = req.order.rawValue
            concurrency = req.concurrency ?? 4
            batchMode = req.batch ?? false
            batchSize = req.batchSize
            
            // Date range
            if let dateRange = req.dateRange {
                sinceDate = dateRange.since
                beforeDate = dateRange.until
            }
            
            // Mode -> dryRun
            dryRun = ((req.mode ?? .real) == .simulate)
            
            // Handle collector-specific options from OpenAPI-generated payload
            if let collectorOptions = req.collectorOptions {
                if case let .ImapCollectorOptions(options) = collectorOptions {
                    reset = options.reset
                    dryRun = options.dryRun ?? dryRun
                    folder = options.folder ?? options.mailbox
                    accountId = options.accountId
                    maxLimit = options.maxLimit

                    // Handle credentials
                    if let creds = options.credentials {
                        credentials = ImapCredentials(
                            kind: creds.kind.rawValue,
                            secret: creds.secret,
                            secretRef: creds.secretRef
                        )
                    }
                }
            }
        }
        
        guard let account = selectAccount(identifier: accountId) else {
            return HTTPResponse.badRequest(message: "IMAP account not found")
        }
        
        // Determine folders to process: explicit folder in the request wins, otherwise
        // process all configured folders (or INBOX if none configured).
        let foldersToProcess: [String]
        if let reqFolder = folder, !reqFolder.isEmpty {
            foldersToProcess = [reqFolder]
        } else if let accountFolders = account.folders, !accountFolders.isEmpty {
            foldersToProcess = accountFolders
        } else {
            foldersToProcess = ["INBOX"]
        }

        logger.info("Starting IMAP collector run", metadata: [
            "account": account.responseIdentifier,
            "folders": foldersToProcess.joined(separator: ","),
            "batch_mode": batchMode ? "true" : "false",
            "batch_size": batchSize.map(String.init) ?? "default"
        ])

        let resolvedFetchBatchSize = max(1, batchSize ?? 200)
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

        guard let authResolution = resolveAuth(for: account, credentials: credentials) else {
            return HTTPResponse.badRequest(message: "Unable to resolve IMAP credentials")
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
            return HTTPResponse.internalError(message: "Failed to initialize IMAP session")
        }

        // Helper: process one folder and return per-folder results. The helper respects
        // the globalLimit (0 == unlimited) by checking submitted counts and stopping
        // early if globalLimit is reached.
        func processFolder(
            _ folder: String,
            remainingGlobalLimit: Int,
            fetchBatchSize: Int,
            submissionBatchSize: Int,
            batchMode: Bool
        ) async -> (totalFound: Int, processed: Int, submitted: Int, results: [ImapMessageResult], errors: [ImapRunError], earliestTouched: Date?, latestTouched: Date?) {
            do {
                logger.info("Starting IMAP search", metadata: [
                    "account": account.responseIdentifier,
                    "folder": folder,
                    "since": sinceDate?.description ?? "nil",
                    "before": beforeDate?.description ?? "nil"
                ])
                let searchResult = try await imapSession.searchMessages(folder: folder, since: sinceDate, before: beforeDate)
                logger.info("IMAP search completed", metadata: [
                    "account": account.responseIdentifier,
                    "folder": folder,
                    "found_count": "\(searchResult.count)"
                ])
                let uidsSortedAsc = searchResult.sorted()

                // Load persisted fences (timestamp-based)
                var fences: [FenceRange] = []
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

                if reset == true {
                    logger.info("IMAP run requested reset; clearing fences", metadata: ["account": account.responseIdentifier, "folder": folder])
                    fences = []
                }

                // Order UIDs based on requested order, but we'll filter by timestamp during iteration
                let orderedUIDs = Self.composeProcessingOrder(
                    searchResultAsc: uidsSortedAsc,
                    lastProcessedUid: 0,  // No longer used - we filter by timestamp during iteration
                    order: order,
                    since: sinceDate,
                    before: beforeDate,
                    oldestCachedUid: nil  // No longer used - we filter by timestamp during iteration
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
                            } else {
                                let reason = outcome.errorMessage ?? outcome.errorCode ?? "Batch submission failed"
                                errors.append(ImapRunError(uid: pending.uid, reason: reason))
                            }
                        }
                        
                        // Update fences with successfully submitted timestamps
                        if !successfulTimestamps.isEmpty {
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
                            if let msgDate = message.date, FenceManager.isTimestampInFences(msgDate, fences: fences) {
                                logger.debug("Skipping message within fence", metadata: [
                                    "account": account.responseIdentifier,
                                    "folder": folder,
                                    "uid": String(uid),
                                    "timestamp": ISO8601DateFormatter().string(from: msgDate)
                                ])
                                continue
                            }

                            // If date bounds are specified, check them and skip/stop based on processing order
                            // In descending order (newest first): skip messages > until, stop when < since
                            // In ascending order (oldest first): skip messages < since, stop when > until
                            if let msgDate = message.date {
                                if order == "desc" {
                                    // Descending order: process from newest to oldest
                                    if let before = beforeDate, msgDate > before {
                                        // Message is too new (after until), skip and continue to older messages
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
                                        // Message is too old (before since), stop processing
                                        logger.info("Reached since date constraint, stopping processing")
                                        stopProcessing = true
                                        break
                                    }
                                } else {
                                    // Ascending order: process from oldest to newest
                                    if let since = sinceDate, msgDate < since {
                                        // Message is too old (before since), skip and continue to newer messages
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
                                        // Message is too new (after until), stop processing
                                        logger.info("Reached until date constraint, stopping processing")
                                        stopProcessing = true
                                        break
                                    }
                                }
                            }

                            let payload = try await emailCollector.buildDocumentPayload(
                                email: message,
                                intent: nil,
                                relevance: nil,
                                sourceType: "email",
                                sourceIdPrefix: sourcePrefix
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

        // Iterate folders, aggregating results. The globalLimit is enforced across folders.
        var totalFoundSum = 0
        var processedSum = 0
        var submittedSum = 0
        var resultsAll: [ImapMessageResult] = []
        var errorsAll: [ImapRunError] = []
        var earliestTouchedGlobal: Date? = nil
        var latestTouchedGlobal: Date? = nil

        for folder in foldersToProcess {
            let remainingAllowed = (globalLimit > 0) ? max(0, globalLimit - submittedSum) : 0
            let folderResult = await processFolder(
                folder,
                remainingGlobalLimit: remainingAllowed,
                fetchBatchSize: resolvedFetchBatchSize,
                submissionBatchSize: resolvedSubmissionBatchSize,
                batchMode: batchMode
            )

            logger.info("Folder processing completed", metadata: [
                "folder": folder,
                "totalFound": "\(folderResult.totalFound)",
                "processed": "\(folderResult.processed)",
                "submitted": "\(folderResult.submitted)"
            ])

            totalFoundSum += folderResult.totalFound
            processedSum += folderResult.processed
            submittedSum += folderResult.submitted
            resultsAll.append(contentsOf: folderResult.results)
            errorsAll.append(contentsOf: folderResult.errors)

            if let e = folderResult.earliestTouched {
                if let prev = earliestTouchedGlobal { if e < prev { earliestTouchedGlobal = e } } else { earliestTouchedGlobal = e }
            }
            if let l = folderResult.latestTouched {
                if let prev = latestTouchedGlobal { if l > prev { latestTouchedGlobal = l } } else { latestTouchedGlobal = l }
            }

            if globalLimit > 0 && submittedSum >= globalLimit {
                break
            }
        }

        let response = ImapRunResponse(
            accountId: account.responseIdentifier,
            folder: foldersToProcess.joined(separator: ","),
            totalFound: totalFoundSum,
            processed: processedSum,
            submitted: submittedSum,
            dryRun: dryRun,
            since: sinceDate,
            before: beforeDate,
            results: resultsAll,
            errors: errorsAll
        )
        
        // Return adapter-format response that RunRouter can wrap in RunResponse envelope
        return encodeResponse(response, earliestTouched: earliestTouchedGlobal, latestTouched: latestTouchedGlobal)
    }
    
    // MARK: - Helpers
    
    private func selectAccount(identifier: String?) -> MailSourceConfig? {
        let imapSources = config.modules.mail.sources.filter { $0.type == "imap" }
        guard !imapSources.isEmpty else { return nil }
        guard let identifier, !identifier.isEmpty else {
            return imapSources.first
        }
        return imapSources.first { $0.id == identifier }
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
    
    private func encodeResponse(_ response: ImapRunResponse, earliestTouched: Date? = nil, latestTouched: Date? = nil) -> HTTPResponse {
        // Emit an adapter-standard payload so RunRouter can decode and incorporate it into
        // the canonical RunResponse envelope. Fields required by RunResponse.AdapterResult
        // are: scanned, matched, submitted, skipped, earliest_touched, latest_touched,
        // warnings, errors.
        var obj: [String: Any] = [:]
        // scanned -> number of messages processed
        obj["scanned"] = response.processed
        // matched -> best-effort: treat as processed (no separate matched count available)
        obj["matched"] = response.processed
        obj["submitted"] = response.submitted
        // skipped -> messages processed but not submitted
        obj["skipped"] = max(0, response.processed - response.submitted)

        // Prefer actual processed message timestamps when available, fallback to request-supplied since/before
        if let et = earliestTouched {
            obj["earliest_touched"] = RunResponse.iso8601UTC(et)
        } else if let since = response.since {
            obj["earliest_touched"] = RunResponse.iso8601UTC(since)
        } else {
            obj["earliest_touched"] = nil
        }

        if let lt = latestTouched {
            obj["latest_touched"] = RunResponse.iso8601UTC(lt)
        } else if let before = response.before {
            obj["latest_touched"] = RunResponse.iso8601UTC(before)
        } else {
            obj["latest_touched"] = nil
        }

        // No explicit warnings in IMAP run results currently.
        obj["warnings"] = [String]()
        // Map errors to their reasons for visibility to the router
        obj["errors"] = response.errors.map { $0.reason }

        do {
            // Use JSONSerialization to allow mixed Any -> Data conversion with sorted keys
            let final = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: final
            )
        } catch {
            logger.error("Failed to encode IMAP adapter payload", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "Failed to encode response")
        }
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
}

// MARK: - Fence Management
// Uses shared FenceManager from HavenCore

// MARK: - IMAP account state persistence

private extension EmailImapHandler {
    func cacheDirURL() -> URL {
        // Use a default cache directory since we removed the cache config
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/Haven/remote_mail")
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
}
