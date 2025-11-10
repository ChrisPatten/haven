import Foundation
import CryptoKit
import UniformTypeIdentifiers
import HavenCore
import HostAgentEmail

public actor ICloudDriveHandler {
    private let config: HavenConfig
    private let logger = HavenLogger(category: "icloud-drive-handler")
    
    // Enrichment support
    private let enrichmentOrchestrator: EnrichmentOrchestrator?
    private let submitter: DocumentSubmitter?
    private let skipEnrichment: Bool
    
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
    
    public init(
        config: HavenConfig,
        enrichmentOrchestrator: EnrichmentOrchestrator? = nil,
        submitter: DocumentSubmitter? = nil,
        skipEnrichment: Bool = false
    ) {
        self.config = config
        self.enrichmentOrchestrator = enrichmentOrchestrator
        self.submitter = submitter
        self.skipEnrichment = skipEnrichment
    }
    
    /// Submit file with enrichment using new architecture
    private static func submitFileWithEnrichment(
        fileURL: URL,
        data: Data,
        metadata: LocalFSUploadMeta,
        filename: String,
        idempotencyKey: String,
        mimeType: String,
        orchestrator: EnrichmentOrchestrator,
        submitter: DocumentSubmitter,
        gatewayConfig: GatewayConfig,
        authToken: String
    ) async throws -> GatewayFileSubmissionResponse {
        let textExtractor = TextExtractor()
        let imageExtractor = ImageExtractor()
        
        // Extract text content
        var content = ""
        if mimeType.hasPrefix("text/") {
            // Extract text from text files
            if let text = String(data: data, encoding: .utf8) {
                content = await textExtractor.extractText(from: text, mimeType: mimeType)
            }
        }
        
        // Extract images
        let images = await imageExtractor.extractImages(from: data, mimeType: mimeType, filePath: fileURL.path)
        
        // Build CollectorDocument
        let contentHash = sha256Hex(of: data)
        let timestamp = metadata.mtime.map { Date(timeIntervalSince1970: $0) } ?? Date()
        
        let document = CollectorDocument(
            content: content.isEmpty ? "[File: \(filename)]" : content,
            sourceType: "icloud_drive",
            sourceId: "icloud_drive:\(idempotencyKey)",
            metadata: DocumentMetadata(
                contentHash: contentHash,
                mimeType: mimeType,
                timestamp: timestamp,
                timestampType: "modified",
                createdAt: metadata.ctime.map { Date(timeIntervalSince1970: $0) } ?? timestamp,
                modifiedAt: timestamp
            ),
            images: images,
            contentType: .localfs,
            title: filename,
            canonicalUri: fileURL.path
        )
        
        // Enrich document
        let enrichedDocument = try await orchestrator.enrich(document)
        
        // Submit via DocumentSubmitter
        let submissionResult = try await submitter.submit(enrichedDocument)
        
        // Convert submission result to GatewayFileSubmissionResponse
        guard submissionResult.success, let submission = submissionResult.submission else {
            throw NSError(
                domain: "ICloudDriveHandler",
                code: submissionResult.statusCode ?? 500,
                userInfo: [NSLocalizedDescriptionKey: submissionResult.error ?? "Unknown error"]
            )
        }
        
        // Create response from submission
        var response = GatewayFileSubmissionResponse(
            submissionId: submission.submissionId,
            docId: submission.docId,
            externalId: submission.externalId,
            status: submission.status,
            threadId: submission.threadId,
            fileIds: [],
            duplicate: false,
            totalChunks: 0,
            fileSha256: "",
            objectKey: "",
            extractionStatus: "completed"
        )
        return response
    }
    
    /// Compute SHA-256 hash of data
    private static func sha256Hex(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Direct Swift APIs
    
    /// Direct Swift API for running the iCloud Drive collector
    public func runCollector(
        request: CollectorRunRequest?,
        onProgress: ((Int, Int, Int, Int) -> Void)? = nil
    ) async throws -> RunResponse {
        
        guard !isRunning else {
            throw ICloudDriveCollectorError.collectorAlreadyRunning
        }
        
        let options: ICloudDriveCollectorOptions
        do {
            options = try buildOptions(from: request)
        } catch let error as ICloudDriveCollectorError {
            throw error
        } catch {
            throw ICloudDriveCollectorError.failedToBuildOptions(error.localizedDescription)
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
        var response = RunResponse(collector: "icloud_drive", runID: runID, startedAt: startTime)
        
        do {
            logger.info("Starting iCloud Drive collector", metadata: [
                "path": options.searchPath.path,
                "limit": options.limit.map(String.init) ?? "unlimited",
                "dry_run": options.dryRun ? "true" : "false"
            ])
            
            let result = try await runICloudDriveCollector(options: options, onProgress: onProgress)
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
            
            logger.info("iCloud Drive collection completed", metadata: [
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
            
        } catch let error as ICloudDriveCollectorError {
            isRunning = false
            lastRunStatus = "failed"
            lastRunError = error.localizedDescription
            logger.error("iCloud Drive collector failed", metadata: ["error": error.localizedDescription])
            
            let endTime = Date()
            response.finish(status: .error, finishedAt: endTime)
            response.errors = [error.localizedDescription]
            
            throw error
        } catch {
            isRunning = false
            lastRunStatus = "failed"
            lastRunError = error.localizedDescription
            logger.error("iCloud Drive collector failed", metadata: ["error": error.localizedDescription])
            
            let endTime = Date()
            response.finish(status: .error, finishedAt: endTime)
            response.errors = [error.localizedDescription]
            
            throw error
        }
    }
    
    /// Direct Swift API for getting collector state
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
    
    private func buildOptions(from runRequest: CollectorRunRequest?) throws -> ICloudDriveCollectorOptions {
        let moduleConfig = config.modules.localfs  // Reuse localfs config for max file size
        let scope = runRequest?.getICloudDriveScope()
        
        // Get iCloud Drive root path
        let searchPath: URL
        if let path = scope?.path, !path.isEmpty {
            let expandedPath = NSString(string: path).expandingTildeInPath
            searchPath = URL(fileURLWithPath: expandedPath, isDirectory: true)
        } else {
            // Default to iCloud Drive root
            guard let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                throw ICloudDriveCollectorError.iCloudDriveNotAvailable
            }
            searchPath = ubiquityURL.appendingPathComponent("Documents", isDirectory: true)
        }
        
        // Default include patterns: text files, markdown, PDFs, and images
        let defaultInclude = ["*.txt", "*.md", "*.markdown", "*.pdf", "*.jpg", "*.jpeg", "*.png", "*.gif", "*.heic", "*.heif"]
        let include = scope?.includeGlobs ?? defaultInclude
        let exclude = scope?.excludeGlobs ?? []
        
        // Extract other options from scope if present (as dictionary)
        let scopeDict = runRequest?.scope?.value as? [String: Any] ?? [:]
        
        let tags = (scopeDict["tags"] as? [String]) ?? []
        let dryRun = runRequest?.mode == .simulate
        
        let stateFileString = (scopeDict["state_file"] as? String)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let stateFileURL: URL
        if let statePath = stateFileString {
            stateFileURL = URL(fileURLWithPath: expandTilde(in: statePath))
        } else {
            // Use HavenFilePaths for default state file
            stateFileURL = HavenFilePaths.stateFile("icloud_drive_collector_state.json")
        }
        
        let maxFileBytes = moduleConfig.maxFileBytes
        let requestTimeout: TimeInterval = 30.0 // Default 30 seconds
        
        let limit = runRequest?.limit
        
        return ICloudDriveCollectorOptions(
            searchPath: searchPath,
            include: include,
            exclude: exclude,
            tags: tags,
            dryRun: dryRun,
            stateFile: stateFileURL,
            maxFileBytes: maxFileBytes,
            requestTimeout: requestTimeout,
            limit: limit
        )
    }
    
    private func expandTilde(in path: String) -> String {
        return NSString(string: path).expandingTildeInPath
    }
    
    /// Run the iCloud Drive collector using NSMetadataQuery
    private func runICloudDriveCollector(options: ICloudDriveCollectorOptions, onProgress: ((Int, Int, Int, Int) -> Void)? = nil) async throws -> ICloudDriveCollectorResult {
        // Load state
        var state = try loadState(at: options.stateFile)
        var stateDirty = false
        
        var scanned = 0
        var matched = 0
        var submitted = 0
        var skipped = 0
        var warnings: [String] = []
        var errors: [String] = []
        let startTime = Date()
        
        // Use NSMetadataQuery to discover files in iCloud Drive
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        
        // Build predicate for search path
        if options.searchPath.path != FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents").path {
            query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, options.searchPath.path)
        }
        
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        
        // Use continuation to wait for query results
        let results = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NSMetadataItem], Error>) in
            var finishObserver: NSObjectProtocol?
            var updateObserver: NSObjectProtocol?
            
            finishObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { _ in
                if let observer = finishObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                if let observer = updateObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                query.stop()
                continuation.resume(returning: query.results as? [NSMetadataItem] ?? [])
            }
            
            updateObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main
            ) { _ in
                // Query updated - continue waiting for finish
            }
            
            query.start()
            
            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let observer = finishObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                if let observer = updateObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                query.stop()
                continuation.resume(returning: query.results as? [NSMetadataItem] ?? [])
            }
        }
        
        var gatewayConfig = config.gateway
        let timeoutSeconds = max(1, Int(options.requestTimeout.rounded()))
        gatewayConfig.timeoutMs = timeoutSeconds * 1000
        
        for item in results {
            scanned += 1
            
            guard let itemURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else {
                skipped += 1
                continue
            }
            
            // Check if file is downloaded and available
            // Check if file is downloaded using NSMetadataItem attributes
            // Note: We check if the file exists locally before processing
            // Files that aren't downloaded yet will be skipped
            let fileExists = FileManager.default.fileExists(atPath: itemURL.path)
            if !fileExists {
                // File not downloaded yet, trigger download
                do {
                    try FileManager.default.startDownloadingUbiquitousItem(at: itemURL)
                } catch {
                    warnings.append("Failed to start download for \(itemURL.path): \(error.localizedDescription)")
                }
                skipped += 1
                continue
            }
            
            // Get file attributes
            guard let resourceValues = try? itemURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey
            ]) else {
                skipped += 1
                continue
            }
            
            guard resourceValues.isRegularFile == true else {
                continue
            }
            
            let relativePath = makeRelativePath(for: itemURL, root: options.searchPath)
            if !shouldInclude(path: relativePath, include: options.include) {
                skipped += 1
                continue
            }
            if shouldExclude(path: relativePath, exclude: options.exclude) {
                skipped += 1
                continue
            }
            matched += 1
            
            let fileSize = resourceValues.fileSize ?? 0
            if fileSize > options.maxFileBytes {
                warnings.append("Skipped \(relativePath) (size \(fileSize) exceeds limit \(options.maxFileBytes) bytes)")
                skipped += 1
                continue
            }
            
            // Use NSFileCoordinator to read file safely
            var fileData: Data?
            var readError: Error?
            let coordinator = NSFileCoordinator()
            
            var coordinationError: NSError?
            coordinator.coordinate(readingItemAt: itemURL, options: [], error: &coordinationError) { (coordinatedURL) in
                // Read file data inside the coordination block
                do {
                    fileData = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
                } catch {
                    // Capture error in a separate variable to avoid overlapping access
                    readError = error
                }
            }
            
            // Check coordination error first
            if let error = coordinationError {
                errors.append("Failed to coordinate access to \(relativePath): \(error.localizedDescription)")
                skipped += 1
                continue
            }
            
            // Check read error
            if let error = readError {
                errors.append("Failed reading \(relativePath): \(error.localizedDescription)")
                skipped += 1
                continue
            }
            
            guard let data = fileData else {
                errors.append("Failed to read data from \(relativePath)")
                skipped += 1
                continue
            }
            
            let sha256 = shaHex(for: data)
            if var entry = state.byHash[sha256] {
                entry.lastSeen = Date()
                entry.path = relativePath
                entry.size = fileSize
                state.byHash[sha256] = entry
                stateDirty = true
                skipped += 1
                continue
            }
            
            // New file - process it
            let filename = itemURL.lastPathComponent
            let mimeType = mimeType(for: itemURL)
            let idempotencyKey = sha256
            
            let metadata = LocalFSUploadMeta(
                source: "icloud_drive",
                path: relativePath,
                filename: filename,
                mtime: resourceValues.contentModificationDate?.timeIntervalSince1970,
                ctime: resourceValues.creationDate?.timeIntervalSince1970,
                tags: options.tags
            )
            
            if !options.dryRun {
                do {
                    if !skipEnrichment, let orchestrator = enrichmentOrchestrator, let submitter = submitter {
                        _ = try await Self.submitFileWithEnrichment(
                            fileURL: itemURL,
                            data: data,
                            metadata: metadata,
                            filename: filename,
                            idempotencyKey: idempotencyKey,
                            mimeType: mimeType,
                            orchestrator: orchestrator,
                            submitter: submitter,
                            gatewayConfig: gatewayConfig,
                            authToken: config.service.auth.secret
                        )
                    } else {
                        let client = GatewaySubmissionClient(config: gatewayConfig, authToken: config.service.auth.secret)
                        _ = try await client.submitFile(
                            fileURL: itemURL,
                            data: data,
                            metadata: metadata,
                            filename: filename,
                            idempotencyKey: idempotencyKey,
                            mimeType: mimeType
                        )
                    }
                    
                    submitted += 1
                    
                    // Update state
                    let entry = LocalFSStateEntry(
                        path: relativePath,
                        firstSeen: Date(),
                        lastSeen: Date(),
                        size: fileSize,
                        tags: options.tags
                    )
                    state.byHash[sha256] = entry
                    stateDirty = true
                    
                    // Report progress
                    onProgress?(scanned, matched, submitted, skipped)
                    
                    // Check limit
                    if let limit = options.limit, submitted >= limit {
                        break
                    }
                } catch {
                    errors.append("Failed to submit \(relativePath): \(error.localizedDescription)")
                    skipped += 1
                }
            } else {
                submitted += 1  // Count as submitted in dry run
            }
        }
        
        // Query already stopped in continuation
        
        // Save state if dirty
        if stateDirty {
            try saveState(state, at: options.stateFile)
        }
        
        let endTime = Date()
        return ICloudDriveCollectorResult(
            scanned: scanned,
            matched: matched,
            submitted: submitted,
            skipped: skipped,
            warnings: warnings,
            errors: errors,
            startTime: startTime,
            endTime: endTime
        )
    }
    
    // MARK: - Helper Functions
    
    private func makeRelativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path
        let itemPath = url.path
        if itemPath.hasPrefix(rootPath) {
            let relative = String(itemPath.dropFirst(rootPath.count))
            return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        }
        return url.lastPathComponent
    }
    
    private func shouldInclude(path: String, include: [String]) -> Bool {
        if include.isEmpty {
            return true
        }
        return include.contains { pattern in
            matchesGlob(filename: path, pattern: pattern)
        }
    }
    
    private func shouldExclude(path: String, exclude: [String]) -> Bool {
        return exclude.contains { pattern in
            matchesGlob(filename: path, pattern: pattern)
        }
    }
    
    private func matchesGlob(filename: String, pattern: String) -> Bool {
        // Simple glob matching - can be enhanced later
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
        let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$", options: .caseInsensitive)
        let range = NSRange(location: 0, length: filename.utf16.count)
        return regex?.firstMatch(in: filename, options: [], range: range) != nil
    }
    
    private func mimeType(for url: URL) -> String {
        if let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
            if let mimeType = UTType(uti)?.preferredMIMEType {
                return mimeType
            }
        }
        return "application/octet-stream"
    }
    
    private func shaHex(for data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func loadState(at url: URL) throws -> LocalFSState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LocalFSState()
        }
        
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(LocalFSState.self, from: data)
    }
    
    private func saveState(_ state: LocalFSState, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        try data.write(to: url)
    }
}

// MARK: - Error Types

public enum ICloudDriveCollectorError: Error, LocalizedError {
    case collectorAlreadyRunning
    case failedToBuildOptions(String)
    case iCloudDriveNotAvailable
    case queryFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .collectorAlreadyRunning:
            return "iCloud Drive collector is already running"
        case .failedToBuildOptions(let message):
            return "Failed to build collector options: \(message)"
        case .iCloudDriveNotAvailable:
            return "iCloud Drive is not available. Please ensure you are signed in to iCloud and iCloud Drive is enabled."
        case .queryFailed(let message):
            return "NSMetadataQuery failed: \(message)"
        }
    }
}

// MARK: - Options and Result Types

public struct ICloudDriveCollectorOptions: Sendable {
    public let searchPath: URL
    public let include: [String]
    public let exclude: [String]
    public let tags: [String]
    public let dryRun: Bool
    public let stateFile: URL
    public let maxFileBytes: Int
    public let requestTimeout: TimeInterval
    public let limit: Int?
}

public struct ICloudDriveCollectorResult: Sendable {
    public let scanned: Int
    public let matched: Int
    public let submitted: Int
    public let skipped: Int
    public let warnings: [String]
    public let errors: [String]
    public let startTime: Date
    public let endTime: Date
}

// MARK: - CollectorRunRequest Extension

extension CollectorRunRequest {
    func getICloudDriveScope() -> ICloudDriveScope? {
        guard let scopeDict = scope?.value as? [String: Any] else {
            return nil
        }
        
        return ICloudDriveScope(
            path: scopeDict["path"] as? String,
            includeGlobs: scopeDict["include_globs"] as? [String],
            excludeGlobs: scopeDict["exclude_globs"] as? [String]
        )
    }
}

struct ICloudDriveScope {
    let path: String?
    let includeGlobs: [String]?
    let excludeGlobs: [String]?
}

