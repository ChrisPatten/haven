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
        self.collector = LocalFSCollector(gatewayConfig: config.gateway, authToken: config.service.auth.secret)
    }
    
    // MARK: - Direct Swift APIs
    
    /// Direct Swift API for running the LocalFS collector
    /// Replaces HTTP-based handleRun for in-app integration
    public func runCollector(
        request: CollectorRunRequest?,
        onProgress: ((Int, Int, Int, Int) -> Void)? = nil
    ) async throws -> RunResponse {
        
        guard !isRunning else {
            throw LocalFSCollectorError.watchDirectoryNotFound("Collector is already running")
        }
        
        let options: LocalFSCollectorOptions
        do {
            options = try buildOptions(from: request)
        } catch let error as LocalFSCollectorError {
            throw error
        } catch {
            throw LocalFSCollectorError.watchDirectoryNotFound("Failed to build collector options: \(error.localizedDescription)")
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
        
        // Initialize response
        let runID = UUID().uuidString
        var response = RunResponse(collector: "localfs", runID: runID, startedAt: startTime)
        
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
            
            // Convert stats to RunResponse
            response.finish(status: .ok, finishedAt: endTime)
            response.stats = RunResponse.Stats(
                scanned: result.scanned,
                matched: result.matched,
                submitted: result.submitted,
                skipped: result.skipped,
                earliest_touched: nil,
                latest_touched: nil,
                batches: 0
            )
            response.warnings = result.warnings
            response.errors = result.errors
            
            // Report final progress
            onProgress?(result.scanned, result.matched, result.submitted, result.skipped)
            
            return response
            
        } catch let error as LocalFSCollectorError {
            isRunning = false
            lastRunStatus = "failed"
            lastRunError = error.localizedDescription
            logger.error("LocalFS collector failed", metadata: ["error": error.localizedDescription])
            
            let endTime = Date()
            response.finish(status: .error, finishedAt: endTime)
            response.errors = [error.localizedDescription]
            
            throw error
        } catch {
            isRunning = false
            lastRunStatus = "failed"
            lastRunError = error.localizedDescription
            logger.error("LocalFS collector failed", metadata: ["error": error.localizedDescription])
            
            let endTime = Date()
            response.finish(status: .error, finishedAt: endTime)
            response.errors = [error.localizedDescription]
            
            throw error
        }
    }
    
    /// Direct Swift API for getting collector state
    /// Replaces HTTP-based handleState for in-app integration
    public func getCollectorState() async -> CollectorStateInfo {
        // Convert lastRunStats to [String: HavenCore.AnyCodable]
        var statsDict: [String: HavenCore.AnyCodable]? = nil
        if let stats = lastRunStats {
            var dict: [String: HavenCore.AnyCodable] = [:]
            let statsDictAny = stats.toDict()
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
    
    // MARK: - Helpers
    
    private func buildOptions(from runRequest: CollectorRunRequest?) throws -> LocalFSCollectorOptions {
        let moduleConfig = config.modules.localfs
        let scope = runRequest?.getLocalfsScope()
        
        // Extract watch directory from scope paths (first path) or require it
        let watchDir: String
        if let paths = scope?.paths, !paths.isEmpty, let firstPath = paths.first {
            watchDir = firstPath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else {
            throw LocalFSCollectorError.watchDirectoryMissing
        }
        guard !watchDir.isEmpty else {
            throw LocalFSCollectorError.watchDirectoryMissing
        }
        
        // Default include patterns: text files, markdown, PDFs, and images
        let defaultInclude = ["*.txt", "*.md", "*.markdown", "*.pdf", "*.jpg", "*.jpeg", "*.png", "*.gif", "*.heic", "*.heif"]
        let include = scope?.includeGlobs ?? defaultInclude
        let exclude = scope?.excludeGlobs ?? []
        
        // Extract other options from scope if present (as dictionary)
        let scopeDict = runRequest?.scope?.value as? [String: Any] ?? [:]
        
        let tags = (scopeDict["tags"] as? [String]) ?? []
        let moveToString = (scopeDict["move_to"] as? String)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let moveToURL: URL?
        if let moveTo = moveToString, !moveTo.isEmpty {
            moveToURL = URL(fileURLWithPath: expandTilde(in: moveTo), isDirectory: true)
        } else {
            moveToURL = nil
        }
        
        let deleteAfter = (scopeDict["delete_after"] as? Bool) ?? false
        let dryRun = runRequest?.mode == .simulate
        let oneShot = (scopeDict["one_shot"] as? Bool) ?? false
        
        let stateFileString = (scopeDict["state_file"] as? String)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            ?? "~/.haven/localfs_collector_state.json"
        let stateFileURL = URL(fileURLWithPath: expandTilde(in: stateFileString))
        
        let maxFileBytes = moduleConfig.maxFileBytes
        let requestTimeout: TimeInterval = 30.0 // Default 30 seconds
        let followSymlinks = (scopeDict["follow_symlinks"] as? Bool) ?? false
        
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
        let statePath = "~/.haven/localfs_collector_state.json"
        return URL(fileURLWithPath: expandTilde(in: statePath))
    }

    private func resolveStateFileURL(from request: CollectorRunRequest?) -> URL {
        if let scope = request?.getLocalfsScope(),
           let statePath = scope.paths?.first {
            let expanded = NSString(string: statePath).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return defaultStateFileURL() ?? URL(fileURLWithPath: "~/.haven/localfs_collector_state.json")
    }
}
