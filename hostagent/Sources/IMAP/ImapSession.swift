import Foundation
import MailCore
import HavenCore

public enum ImapSessionError: Error, LocalizedError {
    case invalidSecretReference(String)
    case secretNotFound(String)
    case secretDecodingFailed
    case unsupportedAuthKind(String)
    case searchFailed(String, code: Int?, domain: String)
    case fetchFailed(String, code: Int?, domain: String)
    case cancelled
    case emptyResponse
    
    public var errorDescription: String? {
        switch self {
        case .invalidSecretReference(let ref):
            return "Invalid secret reference: \(ref)"
        case .secretNotFound(let ref):
            return "Secret not found for reference: \(ref)"
        case .secretDecodingFailed:
            return "Failed to decode secret data as UTF-8"
        case .unsupportedAuthKind(let kind):
            return "Unsupported IMAP auth kind: \(kind)"
        case .searchFailed(let reason, let code, let domain):
            if let code {
                return "IMAP search failed (\(domain)#\(code)): \(reason)"
            }
            return "IMAP search failed: \(reason)"
        case .fetchFailed(let reason, let code, let domain):
            if let code {
                return "IMAP fetch failed (\(domain)#\(code)): \(reason)"
            }
            return "IMAP fetch failed: \(reason)"
        case .cancelled:
            return "IMAP operation was cancelled"
        case .emptyResponse:
            return "IMAP server returned an empty response"
        }
    }
}

public struct ImapSessionConfiguration: Sendable {
    public enum Security: Sendable {
        case tls
        case startTLS
        case plaintext
        
        fileprivate var connectionType: MCOConnectionType {
            switch self {
            case .tls:
                return .TLS
            case .startTLS:
                return .startTLS
            case .plaintext:
                return .clear
            }
        }
    }
    
    public enum Auth: Sendable {
        case appPassword(secretRef: String)
        case xoauth2(secretRef: String)
        
        fileprivate var kindIdentifier: String {
            switch self {
            case .appPassword:
                return "app_password"
            case .xoauth2:
                return "xoauth2"
            }
        }
    }
    
    public var hostname: String
    public var port: UInt32
    public var username: String
    public var security: Security
    public var auth: Auth
    public var timeout: TimeInterval
    public var fetchConcurrency: Int
    public var allowsInsecurePlainAuth: Bool
    
    public init(
        hostname: String,
        port: UInt32 = 993,
        username: String,
        security: Security = .tls,
        auth: Auth,
        timeout: TimeInterval = 30,
        fetchConcurrency: Int = 4,
        allowsInsecurePlainAuth: Bool = false
    ) {
        self.hostname = hostname
        self.port = port
        self.username = username
        self.security = security
        self.auth = auth
        self.timeout = timeout
        self.fetchConcurrency = max(1, fetchConcurrency)
        self.allowsInsecurePlainAuth = allowsInsecurePlainAuth
    }
}

public actor ImapSession {
    private let session: MCOIMAPSession
    private let secretResolver: SecretResolving
    private let semaphore: AsyncSemaphore
    private let logger = HavenLogger(category: "imap-session")
    private let retryPolicy: RetryPolicy
    private let searchOverride: ((MCOIMAPSession, String, MCOIMAPSearchExpression) async throws -> MCOIndexSet)?
    private let fetchOverride: ((MCOIMAPSession, String, UInt32) async throws -> Data)?
    
    public init(
        configuration: ImapSessionConfiguration,
        secretResolver: SecretResolving = KeychainSecretResolver(),
        session: MCOIMAPSession = MCOIMAPSession(),
        searchExecutor: ((MCOIMAPSession, String, MCOIMAPSearchExpression) async throws -> MCOIndexSet)? = nil,
        fetchExecutor: ((MCOIMAPSession, String, UInt32) async throws -> Data)? = nil
    ) throws {
        self.secretResolver = secretResolver
        self.session = session
        self.semaphore = AsyncSemaphore(value: configuration.fetchConcurrency)
        self.retryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.8)
        
        session.hostname = configuration.hostname
        session.port = configuration.port
        session.username = configuration.username
        session.timeout = configuration.timeout
        session.connectionType = configuration.security.connectionType
        
        switch configuration.auth {
        case .appPassword(let secretRef):
            let secret = try Self.resolveSecret(ref: secretRef, resolver: secretResolver, logger: logger)
            session.password = secret
            session.authType = .saslPlain
        case .xoauth2(let secretRef):
            let token = try Self.resolveSecret(ref: secretRef, resolver: secretResolver, logger: logger)
            session.oAuth2Token = token
            session.authType = .xoAuth2
        }
        self.searchOverride = searchExecutor
        self.fetchOverride = fetchExecutor
    }
    
    public func searchMessages(folder: String, since: Date?, before: Date?) async throws -> [UInt32] {
        let expression = makeSearchExpression(since: since, before: before)
        logger.debug("Searching IMAP folder", metadata: [
            "folder": folder,
            "since": since.map { ISO8601DateFormatter().string(from: $0) } ?? "nil",
            "before": before.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        ])
        
        return try await retryPolicy.execute { [self] attempt in
            let indexSet = try await performSearch(folder: folder, expression: expression)
            var uids: [UInt32] = []
            indexSet.enumerate { index in
                if index <= UInt64(UInt32.max) {
                    uids.append(UInt32(index))
                }
            }
            let ordered = uids.sorted(by: >)
            logger.debug("IMAP search completed", metadata: [
                "folder": folder,
                "attempt": "\(attempt)",
                "found": "\(ordered.count)"
            ])
            return ordered
        }
    }
    
    public func fetchRFC822(folder: String, uid: UInt32) async throws -> Data {
        await semaphore.acquire()
        defer { Task { await semaphore.release() } }
        
        return try await retryPolicy.execute { [self] attempt in
            logger.debug("Fetching RFC822 message", metadata: [
                "folder": folder,
                "uid": "\(uid)",
                "attempt": "\(attempt)"
            ])
            return try await performFetch(folder: folder, uid: uid)
        }
    }
    
    // MARK: - Private

    private func performSearch(folder: String, expression: MCOIMAPSearchExpression) async throws -> MCOIndexSet {
        if let override = searchOverride {
            return try await override(session, folder, expression)
        }
        guard let operation = session.searchExpressionOperation(withFolder: folder, expression: expression) else {
            throw ImapSessionError.searchFailed("Failed to create search operation", code: nil, domain: "client")
        }
        return try await startSearchOperation(operation)
    }
    
    private func performFetch(folder: String, uid: UInt32) async throws -> Data {
        if let override = fetchOverride {
            return try await override(session, folder, uid)
        }
        guard let operation = session.fetchMessageOperation(withFolder: folder, uid: uid) else {
            throw ImapSessionError.fetchFailed("Failed to create fetch operation", code: nil, domain: "client")
        }
        return try await startFetchOperation(operation)
    }
    
    private static func resolveSecret(ref: String, resolver: SecretResolving, logger: HavenLogger) throws -> String {
        guard !ref.isEmpty else {
            throw ImapSessionError.invalidSecretReference(ref)
        }
        do {
            let data = try resolver.resolve(secretRef: ref)
            guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw ImapSessionError.secretDecodingFailed
            }
            return value
        } catch let resolverError as SecretResolverError {
            switch resolverError {
            case .invalidReference:
                throw ImapSessionError.invalidSecretReference(ref)
            case .itemNotFound:
                throw ImapSessionError.secretNotFound(ref)
            case .unexpectedResult, .keychainError:
                logger.error("Secret resolver returned unexpected error", metadata: [
                    "ref": ref,
                    "error": resolverError.localizedDescription
                ])
                throw ImapSessionError.secretNotFound(ref)
            }
        } catch let error as ImapSessionError {
            throw error
        } catch {
            logger.error("Failed to resolve secret", metadata: [
                "ref": ref,
                "error": error.localizedDescription
            ])
            throw ImapSessionError.secretNotFound(ref)
        }
    }
    
    private func makeSearchExpression(since: Date?, before: Date?) -> MCOIMAPSearchExpression {
        var expressions: [MCOIMAPSearchExpression] = []
        if let since {
            expressions.append(MCOIMAPSearchExpression.search(sinceReceivedDate: since))
        }
        if let before {
            expressions.append(MCOIMAPSearchExpression.search(beforeReceivedDate: before))
        }
        guard var combined = expressions.first else {
            return MCOIMAPSearchExpression.searchAll()
        }
        for expression in expressions.dropFirst() {
            combined = MCOIMAPSearchExpression.searchAnd(combined, other: expression)
        }
        return combined
    }
    
    private func startSearchOperation(_ operation: MCOIMAPSearchOperation) async throws -> MCOIndexSet {
        try await withCheckedThrowingContinuation { continuation in
            operation.start { error, result in
                if let error = error as NSError? {
                    continuation.resume(throwing: self.wrap(error: error, context: .search))
                    return
                }
                guard let result else {
                    continuation.resume(throwing: ImapSessionError.emptyResponse)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    private func startFetchOperation(_ operation: MCOIMAPFetchContentOperation) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            operation.start { error, data in
                if let error = error as NSError? {
                    continuation.resume(throwing: self.wrap(error: error, context: .fetch))
                    return
                }
                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: ImapSessionError.emptyResponse)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
    
    nonisolated private func wrap(error: NSError, context: OperationContext) -> Error {
        if error.domain == MCOErrorDomain {
            switch context {
            case .search:
                return ImapSessionError.searchFailed(error.localizedDescription, code: error.code, domain: error.domain)
            case .fetch:
                return ImapSessionError.fetchFailed(error.localizedDescription, code: error.code, domain: error.domain)
            }
        }
        if error.domain == NSURLErrorDomain {
            switch context {
            case .search:
                return ImapSessionError.searchFailed(error.localizedDescription, code: error.code, domain: error.domain)
            case .fetch:
                return ImapSessionError.fetchFailed(error.localizedDescription, code: error.code, domain: error.domain)
            }
        }
        return error
    }
}

// MARK: - Support types

private enum OperationContext {
    case search
    case fetch
}

public struct RetryPolicy: Sendable {
    private let maxAttempts: Int
    private let baseDelay: TimeInterval
    
    public init(maxAttempts: Int, baseDelay: TimeInterval) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0.1, baseDelay)
    }
    
    public func execute<T>(_ operation: @escaping (_ attempt: Int) async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation(attempt)
            } catch {
                lastError = error
                if attempt < maxAttempts, shouldRetry(error: error) {
                    let delay = pow(2.0, Double(attempt - 1)) * baseDelay
                    try await Task.sleep(nanoseconds: UInt64(delay * Double(NSEC_PER_SEC)))
                    continue
                } else {
                    throw error
                }
            }
        }
        throw lastError ?? ImapSessionError.fetchFailed("Unknown error", code: nil, domain: "unknown")
    }
    
    private func shouldRetry(error: Error) -> Bool {
        if let imapError = error as? ImapSessionError {
            switch imapError {
            case .fetchFailed(_, let code, let domain),
                 .searchFailed(_, let code, let domain):
                return shouldRetry(domain: domain, code: code)
            case .invalidSecretReference, .secretNotFound, .secretDecodingFailed, .unsupportedAuthKind, .cancelled, .emptyResponse:
                return false
            }
        }
        let nsError = error as NSError
        return shouldRetry(domain: nsError.domain, code: nsError.code)
    }
    
    private func shouldRetry(domain: String, code: Int?) -> Bool {
        if domain == NSURLErrorDomain {
            return true
        }
        guard domain == MCOErrorDomain, let code, let errorCode = MCOErrorCode(rawValue: code) else {
            return false
        }
        switch errorCode {
        case .connection,
             .tlsNotAvailable,
             .parse,
             .certificate,
             .gmailTooManySimultaneousConnections,
             .gmailExceededBandwidthLimit,
             .fetch,
             .idle,
             .noop,
             .identity:
            return true
        case .authentication,
             .gmailIMAPNotEnabled:
            return false
        default:
            return false
        }
    }
}

public actor AsyncSemaphore {
    private let maximum: Int
    private var current: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    public init(value: Int) {
        self.maximum = max(1, value)
        self.current = value
    }
    
    public func acquire() async {
        if current > 0 {
            current -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    public func release() {
        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            continuation.resume()
        } else {
            current = min(current + 1, maximum)
        }
    }
}
