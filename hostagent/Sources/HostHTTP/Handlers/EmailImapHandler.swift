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
        
        let folder = runRequest.folder ?? account.folders.first ?? "INBOX"
        // limit: if omitted or 0 -> unlimited. If provided >0, honor it but clamp to maxLimit when maxLimit > 0.
        let providedLimit = runRequest.limit ?? 0
        let maxLimit = runRequest.maxLimit ?? 0
        let limit: Int
        if providedLimit == 0 {
            limit = 0 // 0 means unlimited
        } else if maxLimit > 0 {
            limit = min(max(providedLimit, 1), maxLimit)
        } else {
            limit = max(providedLimit, 1)
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
        
        let searchResult: [UInt32]
        do {
            searchResult = try await imapSession.searchMessages(folder: folder, since: sinceDate, before: beforeDate)
        } catch {
            logger.error("IMAP search failed", metadata: [
                "account": account.debugIdentifier,
                "folder": folder,
                "error": error.localizedDescription
            ])
            return HTTPResponse.internalError(message: "IMAP search failed: \(error.localizedDescription)")
        }
        
        // Determine ordering and skip previously processed messages using a small on-disk cache
        let uidsSortedAsc = searchResult.sorted()
        var lastProcessedUid: UInt32 = 0
        do {
            if let v = try loadLastProcessedUid(account: account, folder: folder) {
                lastProcessedUid = v
            }
        } catch {
            logger.warning("Failed to load IMAP account state", metadata: ["account": account.responseIdentifier, "folder": folder, "error": error.localizedDescription])
        }

        if runRequest.reset ?? false {
            logger.info("IMAP run requested reset; ignoring persisted last_processed_uid", metadata: ["account": account.responseIdentifier, "folder": folder])
            lastProcessedUid = 0
        }

        let normalizedOrder = runRequest.order?.lowercased()
        let unprocessed: [UInt32] = uidsSortedAsc.filter { $0 > lastProcessedUid }
        let orderedUIDsAsc: [UInt32] = unprocessed
        let orderedUIDsDesc: [UInt32] = Array(unprocessed.reversed())

        let orderedUIDs: [UInt32]
        if normalizedOrder == "desc" {
            orderedUIDs = orderedUIDsDesc
        } else {
            // default to asc
            orderedUIDs = orderedUIDsAsc
        }

        // Determine how many to process. limit == 0 means unlimited -> process all available
        let totalAvailable = orderedUIDs.count
        let toProcessCount: Int = (limit == 0) ? totalAvailable : min(limit, totalAvailable)
        if toProcessCount == 0 {
            let response = ImapRunResponse(
                accountId: account.responseIdentifier,
                folder: folder,
                totalFound: searchResult.count,
                processed: 0,
                submitted: 0,
                dryRun: dryRun,
                since: sinceDate,
                before: beforeDate,
                results: [],
                errors: []
            )
            return encodeResponse(response)
        }
        
        var processedCount = 0
        var submittedCount = 0
        var results: [ImapMessageResult] = []
        var errors: [ImapRunError] = []
        let sourcePrefix = "email_imap/\(account.responseIdentifier)"

        // Batch parameters
        let defaultBatchSize = runRequest.batchSize ?? 200
        let batchSize = max(1, defaultBatchSize)

        // Process in batches of `batchSize` up to toProcessCount
        var processedSoFar = 0
        while processedSoFar < toProcessCount {
            let remaining = toProcessCount - processedSoFar
            let thisBatchSize = min(batchSize, remaining)
            let startIndex = processedSoFar
            let endIndex = processedSoFar + thisBatchSize
            let batchUIDs = Array(orderedUIDs[startIndex..<endIndex])

            logger.info("Processing IMAP batch", metadata: ["account": account.responseIdentifier, "folder": folder, "batch_start": "\(startIndex)", "batch_count": "\(batchUIDs.count)"])

            for uid in batchUIDs {
                do {
                    let data = try await imapSession.fetchRFC822(folder: folder, uid: uid)
                    let message = try await emailService.parseRFC822Data(data)
                    processedCount += 1

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

                    // Persist last-processed UID so future runs can resume/skip already-processed messages.
                    do {
                        let newLast = max(lastProcessedUid, uid)
                        lastProcessedUid = newLast
                        try saveLastProcessedUid(account: account, folder: folder, uid: lastProcessedUid)
                    } catch {
                        logger.warning("Failed to save IMAP account state", metadata: ["account": account.responseIdentifier, "folder": folder, "error": error.localizedDescription])
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

            // Small pause between batches could be added here if desired to reduce load.
        }
        
        let response = ImapRunResponse(
            accountId: account.responseIdentifier,
            folder: folder,
            totalFound: searchResult.count,
            processed: processedCount,
            submitted: submittedCount,
            dryRun: dryRun,
            since: sinceDate,
            before: beforeDate,
            results: results,
            errors: errors
        )
        return encodeResponse(response)
    }
    
    // MARK: - Helpers
    
    private func decodeRunRequest(_ request: HTTPRequest) throws -> ImapRunRequest {
        guard let body = request.body, !body.isEmpty else {
            return ImapRunRequest()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // First, try to decode the collector-specific IMAP request shape.
        if let specific = try? decoder.decode(ImapRunRequest.self, from: body) {
            return specific
        }

        // Fallback: decode the unified CollectorRunRequest and map fields.
        // RunRouter already strictly validates the unified DTO shape, so decoding
        // should succeed for requests that use the unified format.
        if let unified = try? decoder.decode(CollectorRunRequest.self, from: body) {
            var mapped = ImapRunRequest()
            mapped.limit = unified.limit
            mapped.order = unified.order?.rawValue
            mapped.concurrency = unified.concurrency
            mapped.since = unified.dateRange?.since
            mapped.before = unified.dateRange?.until
            // mode.simulate -> dry run
            if let m = unified.mode {
                mapped.dryRun = (m == .simulate)
            }
            // time_window has no direct IMAP equivalent; map conservatively to batchSize
            mapped.batchSize = unified.timeWindow
            return mapped
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
    
    private func encodeResponse(_ response: ImapRunResponse) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let data = try encoder.encode(response)
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        } catch {
            logger.error("Failed to encode IMAP run response", metadata: ["error": error.localizedDescription])
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

    func loadLastProcessedUid(account: MailImapAccountConfig, folder: String) throws -> UInt32? {
        let url = cacheFileURL(for: account, folder: folder)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let obj = try decoder.decode([String: Int].self, from: data)
        if let n = obj["last_processed_uid"] {
            return UInt32(n)
        }
        return nil
    }

    func saveLastProcessedUid(account: MailImapAccountConfig, folder: String, uid: UInt32) throws {
        let url = cacheFileURL(for: account, folder: folder)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let obj: [String: Int] = ["last_processed_uid": Int(uid)]
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
