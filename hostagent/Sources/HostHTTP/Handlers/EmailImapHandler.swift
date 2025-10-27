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
                sourceIdPrefix: "email_imap"
            )
        }
        self.emailService = emailService ?? EmailService()
        self.baseSecretResolver = secretResolver
    }
    
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.mailImap.enabled else {
            return HTTPResponse.badRequest(message: "mail_imap module is disabled")
        }
        
        let runRequest: ImapRunRequest
        do {
            runRequest = try decodeRunRequest(request)
        } catch {
            logger.warning("Failed to decode IMAP run request", metadata: ["error": error.localizedDescription])
            return HTTPResponse.badRequest(message: "Invalid request payload")
        }
        
        guard let account = selectAccount(identifier: runRequest.accountId) else {
            return HTTPResponse.badRequest(message: "IMAP account not found")
        }
        
        // Determine folders to process: explicit folder in the request wins, otherwise
        // process all configured folders (or INBOX if none configured).
        let foldersToProcess: [String]
        if let reqFolder = runRequest.folder, !reqFolder.isEmpty {
            foldersToProcess = [reqFolder]
        } else if !account.folders.isEmpty {
            foldersToProcess = account.folders
        } else {
            foldersToProcess = ["INBOX"]
        }

        // limit: if omitted or 0 -> unlimited. If provided >0, honor it but clamp to maxLimit when maxLimit > 0.
        let providedLimit = runRequest.limit ?? 0
        let maxLimit = runRequest.maxLimit ?? 0
        let globalLimit: Int
        if providedLimit == 0 {
            globalLimit = 0 // 0 means unlimited
        } else if maxLimit > 0 {
            globalLimit = min(max(providedLimit, 1), maxLimit)
        } else {
            globalLimit = max(providedLimit, 1)
        }
        let fetchConcurrency = max(1, min(runRequest.concurrency ?? 4, 12))
        let dryRun = runRequest.dryRun ?? false

        let sinceDate = runRequest.since
        let beforeDate = runRequest.before

        guard let authResolution = resolveAuth(for: account, request: runRequest) else {
            return HTTPResponse.badRequest(message: "Unable to resolve IMAP credentials")
        }

        let security: ImapSessionConfiguration.Security = account.tls ? .tls : .plaintext
        let imapConfig = ImapSessionConfiguration(
            hostname: account.host,
            port: UInt32(account.port),
            username: account.username,
            security: security,
            auth: authResolution.auth,
            timeout: 60,
            fetchConcurrency: fetchConcurrency,
            allowsInsecurePlainAuth: !account.tls
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
        func processFolder(_ folder: String, remainingGlobalLimit: Int) async -> (totalFound: Int, processed: Int, submitted: Int, results: [ImapMessageResult], errors: [ImapRunError], earliestTouched: Date?, latestTouched: Date?) {
            do {
                let searchResult = try await imapSession.searchMessages(folder: folder, since: sinceDate, before: beforeDate)
                let uidsSortedAsc = searchResult.sorted()

                var lastProcessedUid: UInt32 = 0
                var earliestProcessedUidCache: UInt32? = nil
                do {
                    if let state = try loadImapState(account: account, folder: folder) {
                        if let v = state.last { lastProcessedUid = v }
                        if let e = state.earliest { earliestProcessedUidCache = e }
                    }
                } catch {
                    logger.warning("Failed to load IMAP account state", metadata: ["account": account.responseIdentifier, "folder": folder, "error": error.localizedDescription])
                }

                if runRequest.reset ?? false {
                    logger.info("IMAP run requested reset; ignoring persisted last_processed_uid", metadata: ["account": account.responseIdentifier, "folder": folder])
                    lastProcessedUid = 0
                }

                let orderedUIDs = Self.composeProcessingOrder(
                    searchResultAsc: uidsSortedAsc,
                    lastProcessedUid: lastProcessedUid,
                    order: runRequest.order,
                    since: runRequest.since,
                    before: runRequest.before,
                    oldestCachedUid: earliestProcessedUidCache
                )

                var processedCount = 0
                var submittedCount = 0
                var results: [ImapMessageResult] = []
                var errors: [ImapRunError] = []
                var earliestProcessedDate: Date? = nil
                var latestProcessedDate: Date? = nil
                var earliestProcessedUid: UInt32? = nil

                let sourcePrefix = "email_imap/\(account.responseIdentifier)"
                let defaultBatchSize = runRequest.batchSize ?? 200
                let batchSize = max(1, defaultBatchSize)

                var processedSoFar = 0
                var stopProcessing = false
                while processedSoFar < orderedUIDs.count && !stopProcessing {
                    let remaining = orderedUIDs.count - processedSoFar
                    let thisBatchSize = min(batchSize, remaining)
                    let startIndex = processedSoFar
                    let endIndex = processedSoFar + thisBatchSize
                    let batchUIDs = Array(orderedUIDs[startIndex..<endIndex])

                    logger.info("Processing IMAP batch", metadata: ["account": account.responseIdentifier, "folder": folder, "batch_start": "\(startIndex)", "batch_count": "\(batchUIDs.count)"])

                    for uid in batchUIDs {
                        do {
                            let data = try await imapSession.fetchRFC822(folder: folder, uid: uid)
                            let message = try await emailService.parseRFC822Data(data)
                            // NOTE: Do not set earliest/latest here. These should reflect
                            // only successfully submitted documents — update after submit.
                            processedCount += 1

                            if let prev = earliestProcessedUid {
                                if uid < prev { earliestProcessedUid = uid }
                            } else {
                                earliestProcessedUid = uid
                            }

                            if let since = sinceDate, let msgDate = message.date, msgDate < since {
                                stopProcessing = true
                                break
                            }
                            if let before = beforeDate, let msgDate = message.date, msgDate > before {
                                stopProcessing = true
                                break
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

                            // If a globalLimit is specified, and remainingGlobalLimit is 0, stop submitting.
                            if globalLimit > 0 && remainingGlobalLimit <= 0 {
                                stopProcessing = true
                                break
                            }

                            let submission = try await emailCollector.submitEmailDocument(payload)
                            submittedCount += 1

                            let entry = ImapMessageResult(
                                uid: uid,
                                messageId: payload.metadata.messageId,
                                status: submission.status,
                                submissionId: submission.submissionId,
                                docId: submission.docId,
                                duplicate: submission.duplicate
                            )
                            results.append(entry)

                            // Update earliest/latest only for actually submitted documents
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

                            do {
                                let newLast = max(lastProcessedUid, uid)
                                lastProcessedUid = newLast
                                try saveImapState(account: account, folder: folder, last: lastProcessedUid, earliest: earliestProcessedUid)
                            } catch {
                                logger.warning("Failed to save IMAP account state", metadata: ["account": account.responseIdentifier, "folder": folder, "error": error.localizedDescription])
                            }

                            if globalLimit > 0 && submittedCount >= globalLimit {
                                stopProcessing = true
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
                    processedSoFar += batchUIDs.count
                    if stopProcessing { break }
                }

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
            let folderResult = await processFolder(folder, remainingGlobalLimit: remainingAllowed)

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
        return encodeResponse(response, earliestTouched: earliestTouchedGlobal, latestTouched: latestTouchedGlobal)
    }
    
    // MARK: - Helpers
    
    private func decodeRunRequest(_ request: HTTPRequest) throws -> ImapRunRequest {
        guard let body = request.body, !body.isEmpty else {
            return ImapRunRequest()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // First, try to decode a lightweight local DTO matching the unified
        // CollectorRunRequest shape for the fields we care about. We avoid
        // importing HostAgent here to prevent circular module dependencies.
        struct UnifiedRunDTO: Codable {
            struct DateRange: Codable {
                let since: Date?
                let until: Date?
            }
            let limit: Int?
            let order: String?
            let concurrency: Int?
            let dateRange: DateRange?
            let mode: String?
            let timeWindow: Int?
            enum CodingKeys: String, CodingKey {
                case limit, order, concurrency, mode
                case dateRange = "date_range"
                case timeWindow = "time_window"
            }
        }

        if let unified = try? decoder.decode(UnifiedRunDTO.self, from: body) {
            var mapped = ImapRunRequest()
            mapped.limit = unified.limit
            mapped.order = unified.order
            mapped.concurrency = unified.concurrency
            mapped.since = unified.dateRange?.since
            mapped.before = unified.dateRange?.until
            // mode.simulate -> dry run
            if let m = unified.mode {
                mapped.dryRun = (m == "simulate")
            }
            // time_window has no direct IMAP equivalent; map conservatively to batchSize
            mapped.batchSize = unified.timeWindow
            // Allow collector-specific options to be passed under `collector_options`.
            if let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
               let coll = json["collector_options"] as? [String: Any] {
                if let r = coll["reset"] as? Bool {
                    mapped.reset = r
                }
                // Support dry_run variants
                if let dr = coll["dry_run"] as? Bool {
                    mapped.dryRun = dr
                } else if let dr = coll["dryRun"] as? Bool {
                    mapped.dryRun = dr
                }
                // Map collector_options.folder -> imap run folder (also accept mailbox)
                if let f = coll["folder"] as? String {
                    mapped.folder = f
                } else if let f = coll["mailbox"] as? String {
                    mapped.folder = f
                }
                // Allow mapping of account identifier
                if let a = coll["account_id"] as? String {
                    mapped.accountId = a
                } else if let a = coll["accountId"] as? String {
                    mapped.accountId = a
                }
                // Map max limit (clamp applied later)
                if let m = coll["max_limit"] as? Int {
                    mapped.maxLimit = m
                } else if let m = coll["maxLimit"] as? Int {
                    mapped.maxLimit = m
                }
                // Map nested credentials object if provided
                if let creds = coll["credentials"] as? [String: Any] {
                    var c = ImapRunRequest.Credentials()
                    if let k = creds["kind"] as? String { c.kind = k }
                    if let s = creds["secret"] as? String { c.secret = s }
                    if let sr = creds["secret_ref"] as? String { c.secretRef = sr }
                    if let sr = creds["secretRef"] as? String { c.secretRef = sr }
                    mapped.credentials = c
                }
            }
            return mapped
        }

        // Fallback: try to decode the IMAP-specific DTO directly. This branch
        // maintains backwards compatibility for callers that send the adapter-
        // specific request shape. When this succeeds we still accept an optional
        // nested `collector_options` object to provide extra hints like reset.
        if var specific = try? decoder.decode(ImapRunRequest.self, from: body) {
            if let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
               let coll = json["collector_options"] as? [String: Any] {
                if let r = coll["reset"] as? Bool {
                    specific.reset = r
                }
                if let dr = coll["dry_run"] as? Bool {
                    specific.dryRun = dr
                } else if let dr = coll["dryRun"] as? Bool {
                    specific.dryRun = dr
                }
                // Allow callers to specify collector-specific options under collector_options
                if let f = coll["folder"] as? String {
                    specific.folder = f
                } else if let f = coll["mailbox"] as? String {
                    specific.folder = f
                }
                if let a = coll["account_id"] as? String {
                    specific.accountId = a
                } else if let a = coll["accountId"] as? String {
                    specific.accountId = a
                }
                if let m = coll["max_limit"] as? Int {
                    specific.maxLimit = m
                } else if let m = coll["maxLimit"] as? Int {
                    specific.maxLimit = m
                }
                if let creds = coll["credentials"] as? [String: Any] {
                    var c = ImapRunRequest.Credentials()
                    if let k = creds["kind"] as? String { c.kind = k }
                    if let s = creds["secret"] as? String { c.secret = s }
                    if let sr = creds["secret_ref"] as? String { c.secretRef = sr }
                    if let sr = creds["secretRef"] as? String { c.secretRef = sr }
                    specific.credentials = c
                }
            }
            return specific
        }

        // If we reached here, throw the decoding error from a strict decode to provide
        // a helpful diagnostic to the caller.
        return try decoder.decode(ImapRunRequest.self, from: body)
    }
    
    private func selectAccount(identifier: String?) -> MailImapAccountConfig? {
        let accounts = config.modules.mailImap.accounts
        guard !accounts.isEmpty else { return nil }
        guard let identifier, !identifier.isEmpty else {
            return accounts.first
        }
        return accounts.first { $0.id == identifier }
    }
    
    private func resolveAuth(for account: MailImapAccountConfig, request: ImapRunRequest) -> AuthResolution? {
        var resolvers: [any SecretResolving] = []
        var secretRef = request.credentials?.secretRef ?? account.auth.secretRef
        
        if let inlineSecret = request.credentials?.secret, !inlineSecret.isEmpty {
            let inlineRef = "inline://\(UUID().uuidString)"
            resolvers.append(InlineSecretResolver(storage: [inlineRef: Data(inlineSecret.utf8)]))
            secretRef = inlineRef
        }
        
        resolvers.append(baseSecretResolver)
        if secretRef.isEmpty {
            return nil
        }
        
        let kind = (request.credentials?.kind ?? account.auth.kind).lowercased()
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
    
    private struct ImapRunRequest: Decodable {
        struct Credentials: Decodable {
            var kind: String?
            var secret: String?
            var secretRef: String?
        }
        
        var accountId: String?
        var folder: String?
        var limit: Int?
        var maxLimit: Int?
        var order: String?
        var reset: Bool?
        var batchSize: Int?
        var since: Date?
        var before: Date?
        var dryRun: Bool?
        var concurrency: Int?
        var credentials: Credentials?
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

// MARK: - IMAP account state persistence

private extension EmailImapHandler {
    func cacheDirURL() -> URL {
        let raw = config.modules.mailImap.cache.dir
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    func cacheFileURL(for account: MailImapAccountConfig, folder: String) -> URL {
        let dir = cacheDirURL()
        var folderName = folder
        // sanitize folder for filesystem
        folderName = folderName.replacingOccurrences(of: "/", with: "_")
        folderName = folderName.replacingOccurrences(of: " ", with: "_")
        let fileName = "imap_state_\(account.responseIdentifier)_\(folderName).json"
        return dir.appendingPathComponent(fileName)
    }

    func loadImapState(account: MailImapAccountConfig, folder: String) throws -> (last: UInt32?, earliest: UInt32?)? {
        let url = cacheFileURL(for: account, folder: folder)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let obj = try decoder.decode([String: Int].self, from: data)
        let last = obj["last_processed_uid"].map { UInt32($0) }
        let earliest = obj["earliest_processed_uid"].map { UInt32($0) }
        return (last: last, earliest: earliest)
    }

    func saveImapState(account: MailImapAccountConfig, folder: String, last: UInt32, earliest: UInt32?) throws {
        let url = cacheFileURL(for: account, folder: folder)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var obj: [String: Int] = ["last_processed_uid": Int(last)]
        if let e = earliest {
            obj["earliest_processed_uid"] = Int(e)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(obj)
        try data.write(to: url, options: .atomic)
    }
}

private extension MailImapAccountConfig {
    var responseIdentifier: String {
        if !id.isEmpty {
            return id
        }
        return username.isEmpty ? host : username
    }
    
    var debugIdentifier: String {
        "\(responseIdentifier)@\(host)"
    }
}
