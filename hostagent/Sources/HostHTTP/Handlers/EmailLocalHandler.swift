import Foundation
import HavenCore
import Email

/// Handler for local email collector orchestration
public actor EmailLocalHandler {
    private let config: HavenConfig
    private let emailService: EmailService
    private let logger = HavenLogger(category: "email-local-handler")
    private let indexedCollector: EmailIndexedCollector
    
    // State tracking
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: RunStatus = .idle
    private var lastRunStats: CollectorStats?
    private var lastRunError: String?
    
    private enum RunStatus: String {
        case idle
        case running
        case completed
        case partial
        case failed
    }
    
    private struct CollectorStats: Codable {
        var messagesProcessed: Int
        var documentsCreated: Int
        var attachmentsProcessed: Int
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
    
    private struct RunRequest: Decodable {
        let mode: String?
        let limit: Int?
        let simulatePath: String?
        
        enum CodingKeys: String, CodingKey {
            case mode
            case limit
            case simulatePath = "simulate_path"
        }
    }
    
    private enum HandlerError: LocalizedError {
        case moduleDisabled
        case alreadyRunning
        case invalidMode(String)
        case invalidLimit(Int)
        case simulatePathRequired
        case pathNotFound(String)
        case noEmlxFiles(String)
        case invalidRequestBody
        
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
            case .pathNotFound(let path):
                return "No file or directory found at path '\(path)'"
            case .noEmlxFiles(let path):
                return "No .emlx files found under '\(path)'"
            case .invalidRequestBody:
                return "Request body must be valid JSON"
            }
        }
        
        var statusCode: Int {
            switch self {
            case .moduleDisabled:
                return 503
            case .alreadyRunning:
                return 409
            case .invalidMode, .invalidLimit, .simulatePathRequired:
                return 400
            case .pathNotFound, .noEmlxFiles:
                return 404
            case .invalidRequestBody:
                return 400
            }
        }
    }
    
    public init(config: HavenConfig, indexedCollector: EmailIndexedCollector = EmailIndexedCollector()) {
        self.config = config
        self.emailService = EmailService()
        self.indexedCollector = indexedCollector
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
        
        isRunning = true
        defer { isRunning = false }
        
        logger.info("Starting email_local run", metadata: [
            "mode": params.mode,
            "limit": "\(params.limit)",
            "simulate_path": params.simulatePath ?? "nil"
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
        let simulatePath: String?
    }
    
    private struct RunOutcome {
        let partial: Bool
        let warnings: [String]
        
        static let success = RunOutcome(partial: false, warnings: [])
    }
    
    private func runCollector(with params: RunParameters, stats: inout CollectorStats) async throws -> RunOutcome {
        switch params.mode {
        case "simulate":
            guard let path = params.simulatePath else {
                throw HandlerError.simulatePathRequired
            }
            return try await runSimulateMode(at: path, limit: params.limit, stats: &stats)
        case "real":
            return try await runRealMode(limit: params.limit, stats: &stats)
        default:
            throw HandlerError.invalidMode(params.mode)
        }
    }
    
    private func runSimulateMode(at path: String, limit: Int, stats: inout CollectorStats) async throws -> RunOutcome {
        let expandedPath = (path as NSString).expandingTildeInPath
        
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expandedPath, isDirectory: &isDir) else {
            throw HandlerError.pathNotFound(expandedPath)
        }
        
        var emlxFiles: [URL] = []
        if isDir.boolValue {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: expandedPath), includingPropertiesForKeys: nil) else {
                throw HandlerError.pathNotFound(expandedPath)
            }
            while let next = enumerator.nextObject() as? URL {
                if next.pathExtension.lowercased() == "emlx" {
                    emlxFiles.append(next)
                }
            }
        } else {
            let url = URL(fileURLWithPath: expandedPath)
            if url.pathExtension.lowercased() == "emlx" {
                emlxFiles = [url]
            }
        }
        
        guard !emlxFiles.isEmpty else {
            throw HandlerError.noEmlxFiles(expandedPath)
        }
        
        let limitedFiles = emlxFiles.prefix(limit)
        var warnings: [String] = []
        
        for fileURL in limitedFiles {
            do {
                let message = try await emailService.parseEmlxFile(at: fileURL)
                stats.messagesProcessed += 1
                stats.documentsCreated += 1
                stats.attachmentsProcessed += message.attachments.count
            } catch {
                stats.errorsEncountered += 1
                warnings.append("Failed to parse \(fileURL.lastPathComponent): \(error.localizedDescription)")
                logger.error("Failed to parse simulated email", metadata: [
                    "path": fileURL.path,
                    "error": error.localizedDescription
                ])
            }
        }
        
        let hadErrors = stats.errorsEncountered > 0
        return RunOutcome(partial: hadErrors, warnings: warnings)
    }
    
    private func runRealMode(limit: Int, stats: inout CollectorStats) async throws -> RunOutcome {
        do {
            let result = try await indexedCollector.run(limit: limit)
            stats.messagesProcessed += result.messages.count
            stats.documentsCreated += result.messages.count
            let partial = !result.warnings.isEmpty
            if partial {
                return RunOutcome(partial: true, warnings: result.warnings)
            }
            return .success
        } catch let error as EmailCollectorError {
            if case .envelopeIndexNotFound = error {
                let warning = "Envelope Index not found; falling back to crawler mode (not yet implemented)"
                logger.warning("Indexed mode unavailable, falling back to crawler placeholder", metadata: ["warning": warning])
                return RunOutcome(partial: true, warnings: [warning])
            }
            throw error
        }
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
        var mode = "simulate"
        var limit = 100
        var simulatePath: String?
        
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
                if let providedPath = runRequest.simulatePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !providedPath.isEmpty {
                    simulatePath = providedPath
                }
            } catch {
                throw HandlerError.invalidRequestBody
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
        
        return RunParameters(mode: mode, limit: limit, simulatePath: simulatePath)
    }
    
    // MARK: - Response Helpers
    
    private func successResponse(status: RunStatus, params: RunParameters, stats: CollectorStats, warnings: [String]) -> HTTPResponse {
        var response: [String: Any] = [
            "status": status.rawValue,
            "mode": params.mode,
            "limit": params.limit,
            "stats": stats.toDictionary()
        ]
        if let path = params.simulatePath {
            response["simulate_path"] = path
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
        
        return response
    }
    
    private func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
