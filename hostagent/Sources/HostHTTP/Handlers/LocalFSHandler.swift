import Foundation
import HavenCore
import HostAgentEmail

public actor LocalFSHandler {
    private let config: HavenConfig
    private let collector: LocalFSCollector
    private let logger = HavenLogger(category: "localfs-handler")
    
    private struct CollectorStats: Codable {
        var scanned: Int
        var matched: Int
        var submitted: Int
        var skipped: Int
        var startTime: Date
        var endTime: Date?
        var durationMs: Int?
        
        func toDict() -> [String: Any] {
            var dict: [String: Any] = [
                "scanned": scanned,
                "matched": matched,
                "submitted": submitted,
                "skipped": skipped,
                "start_time": ISO8601DateFormatter().string(from: startTime)
            ]
            if let endTime {
                dict["end_time"] = ISO8601DateFormatter().string(from: endTime)
            }
            if let durationMs {
                dict["duration_ms"] = durationMs
            }
            return dict
        }
    }
    
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunStats: CollectorStats?
    private var lastRunError: String?
    private var lastStateFileURL: URL?
    
    public init(config: HavenConfig) {
        self.config = config
        self.collector = LocalFSCollector(gatewayConfig: config.gateway, authToken: config.auth.secret)
    }
    
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        guard config.modules.localfs.enabled else {
            logger.warning("LocalFS collector request rejected - module disabled")
            return HTTPResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"LocalFS collector module is disabled"}"#.data(using: .utf8)
            )
        }
        
        guard !isRunning else {
            logger.warning("LocalFS collector already running")
            return HTTPResponse(
                statusCode: 409,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Collector is already running"}"#.data(using: .utf8)
            )
        }
        
        let runRequest: CollectorRunRequest?
        if let body = request.body, !body.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                runRequest = try decoder.decode(CollectorRunRequest.self, from: body)
            } catch {
                logger.error("Failed to decode CollectorRunRequest", metadata: ["error": error.localizedDescription])
                return HTTPResponse.badRequest(message: "Invalid request format: \(error.localizedDescription)")
            }
        } else {
            runRequest = nil
        }
        
        let options: LocalFSCollectorOptions
        do {
            options = try buildOptions(from: runRequest)
        } catch let error as LocalFSCollectorError {
            return mapCollectorError(error)
        } catch {
            logger.error("Failed to build collector options", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "Failed to build collector options: \(error.localizedDescription)")
        }
        
        lastStateFileURL = options.stateFile
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        lastRunError = nil
        
        let startTime = Date()
        var stats = CollectorStats(
            scanned: 0,
            matched: 0,
            submitted: 0,
            skipped: 0,
            startTime: startTime,
            endTime: nil,
            durationMs: nil
        )
        
        do {
            logger.info("Starting LocalFS collector", metadata: [
                "watch_dir": options.watchDirectory.path,
                "limit": options.limit.map(String.init) ?? "unlimited",
                "dry_run": options.dryRun ? "true" : "false"
            ])
            
            let result = try await collector.run(options: options)
            let endTime = Date()
            
            stats.scanned = result.scanned
            stats.matched = result.matched
            stats.submitted = result.submitted
            stats.skipped = result.skipped
            stats.endTime = endTime
            stats.durationMs = Int(endTime.timeIntervalSince(startTime) * 1000)
            
            isRunning = false
            lastRunStatus = "completed"
            lastRunStats = stats
            
            logger.info("LocalFS collection completed", metadata: [
                "scanned": String(result.scanned),
                "submitted": String(result.submitted),
                "skipped": String(result.skipped),
                "warnings": String(result.warnings.count),
                "errors": String(result.errors.count)
            ])
            
            return encodeAdapterResponse(
                scanned: result.scanned,
                matched: result.matched,
                submitted: result.submitted,
                skipped: result.skipped,
                warnings: result.warnings,
                errors: result.errors
            )
        } catch let error as LocalFSCollectorError {
            isRunning = false
            lastRunStatus = "failed"
            lastRunError = error.localizedDescription
            logger.error("LocalFS collector failed", metadata: ["error": error.localizedDescription])
            return mapCollectorError(error)
        } catch {
            isRunning = false
            lastRunStatus = "failed"
            lastRunError = error.localizedDescription
            logger.error("LocalFS collector failed", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "Collection failed: \(error.localizedDescription)")
        }
    }
    
    public func handleState(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        var statePayload: [String: Any] = [
            "is_running": isRunning,
            "last_run_status": lastRunStatus
        ]
        
        if let lastRunTime {
            statePayload["last_run_time"] = ISO8601DateFormatter().string(from: lastRunTime)
        }
        if let lastRunStats {
            statePayload["last_run_stats"] = lastRunStats.toDict()
        }
        if let lastRunError {
            statePayload["last_run_error"] = lastRunError
        }
        
        if let stateURL = lastStateFileURL ?? defaultStateFileURL(),
           let state = collector.readState(at: stateURL) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(state),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                statePayload["persisted_state"] = obj
            }
            statePayload["state_file_path"] = stateURL.path
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: statePayload, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            return HTTPResponse.internalError(message: "Failed to encode state: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    private func buildOptions(from runRequest: CollectorRunRequest?) throws -> LocalFSCollectorOptions {
        let moduleConfig = config.modules.localfs
        let watchDirString = runRequest?.collectorOptions?.watchDir?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? moduleConfig.defaultWatchDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let watchDir = watchDirString, !watchDir.isEmpty else {
            throw LocalFSCollectorError.watchDirectoryMissing
        }
        
        let include = runRequest?.collectorOptions?.include ?? moduleConfig.include
        let exclude = runRequest?.collectorOptions?.exclude ?? moduleConfig.exclude
        let tags = runRequest?.collectorOptions?.tags ?? moduleConfig.tags
        
        let moveToString = runRequest?.collectorOptions?.moveTo?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? moduleConfig.moveTo?.trimmingCharacters(in: .whitespacesAndNewlines)
        let moveToURL: URL?
        if let moveTo = moveToString, !moveTo.isEmpty {
            moveToURL = URL(fileURLWithPath: expandTilde(in: moveTo), isDirectory: true)
        } else {
            moveToURL = nil
        }
        
        let deleteAfter = runRequest?.collectorOptions?.deleteAfter ?? moduleConfig.deleteAfter
        let dryRun = runRequest?.collectorOptions?.dryRun ?? moduleConfig.dryRun
        let oneShot = runRequest?.collectorOptions?.oneShot ?? moduleConfig.oneShot
        
        let stateFileString = runRequest?.collectorOptions?.stateFile?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? moduleConfig.stateFile
        let stateFileURL = URL(fileURLWithPath: expandTilde(in: stateFileString))
        
        let maxFileBytes = runRequest?.collectorOptions?.maxFileBytes ?? moduleConfig.maxFileBytes
        let requestTimeout = runRequest?.collectorOptions?.requestTimeout ?? moduleConfig.requestTimeout
        let followSymlinks = runRequest?.collectorOptions?.followSymlinks ?? moduleConfig.followSymlinks
        
        let limit = runRequest?.limit
        
        return LocalFSCollectorOptions(
            watchDirectory: URL(fileURLWithPath: expandTilde(in: watchDir), isDirectory: true),
            include: include,
            exclude: exclude,
            tags: tags,
            moveToDirectory: moveToURL,
            deleteAfter: deleteAfter,
            dryRun: dryRun,
            oneShot: oneShot,
            stateFile: stateFileURL,
            maxFileBytes: maxFileBytes,
            requestTimeout: requestTimeout,
            followSymlinks: followSymlinks,
            limit: limit
        )
    }
    
    private func expandTilde(in path: String) -> String {
        return NSString(string: path).expandingTildeInPath
    }
    
    private func defaultStateFileURL() -> URL? {
        let statePath = config.modules.localfs.stateFile
        guard !statePath.isEmpty else { return nil }
        return URL(fileURLWithPath: expandTilde(in: statePath))
    }
    
    private func encodeAdapterResponse(
        scanned: Int,
        matched: Int,
        submitted: Int,
        skipped: Int,
        warnings: [String],
        errors: [String]
    ) -> HTTPResponse {
        let payload: [String: Any] = [
            "scanned": scanned,
            "matched": matched,
            "submitted": submitted,
            "skipped": skipped,
            "batches": 0,
            "warnings": warnings,
            "errors": errors
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            return HTTPResponse.internalError(message: "Failed to encode response: \(error.localizedDescription)")
        }
    }
    
    private func mapCollectorError(_ error: LocalFSCollectorError) -> HTTPResponse {
        switch error {
        case .watchDirectoryMissing:
            return HTTPResponse.badRequest(message: error.localizedDescription ?? "Watch directory missing")
        case .watchDirectoryNotFound:
            return HTTPResponse.notFound(message: error.localizedDescription ?? "Watch directory not found")
        case .watchDirectoryNotDirectory:
            return HTTPResponse.badRequest(message: error.localizedDescription ?? "Watch path is not a directory")
        case .moveDirectoryCreationFailed:
            return HTTPResponse.badRequest(message: error.localizedDescription ?? "Failed to prepare move directory")
        case .statePersistenceFailed:
            return HTTPResponse.internalError(message: error.localizedDescription ?? "Failed to persist collector state")
        }
    }
}
