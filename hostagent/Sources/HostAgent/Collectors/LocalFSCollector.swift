import Foundation
import CryptoKit
import UniformTypeIdentifiers
import HavenCore
import Darwin

public struct LocalFSCollectorOptions: Sendable {
    public let watchDirectory: URL
    public let include: [String]
    public let exclude: [String]
    public let tags: [String]
    public let moveToDirectory: URL?
    public let deleteAfter: Bool
    public let dryRun: Bool
    public let oneShot: Bool
    public let stateFile: URL
    public let maxFileBytes: Int
    public let requestTimeout: TimeInterval
    public let followSymlinks: Bool
    public let limit: Int?

    public init(
        watchDirectory: URL,
        include: [String],
        exclude: [String],
        tags: [String],
        moveToDirectory: URL?,
        deleteAfter: Bool,
        dryRun: Bool,
        oneShot: Bool,
        stateFile: URL,
        maxFileBytes: Int,
        requestTimeout: TimeInterval,
        followSymlinks: Bool,
        limit: Int?
    ) {
        self.watchDirectory = watchDirectory
        self.include = include
        self.exclude = exclude
        self.tags = tags
        self.moveToDirectory = moveToDirectory
        self.deleteAfter = deleteAfter
        self.dryRun = dryRun
        self.oneShot = oneShot
        self.stateFile = stateFile
        self.maxFileBytes = maxFileBytes
        self.requestTimeout = requestTimeout
        self.followSymlinks = followSymlinks
        self.limit = limit
    }
}

public struct LocalFSCollectorResult: Sendable {
    public let scanned: Int
    public let matched: Int
    public let submitted: Int
    public let skipped: Int
    public let warnings: [String]
    public let errors: [String]
    public let startTime: Date
    public let endTime: Date
}

public struct LocalFSStateEntry: Codable, Sendable {
    public var path: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var size: Int
    public var tags: [String]
    
    public init(
        path: String,
        firstSeen: Date,
        lastSeen: Date,
        size: Int,
        tags: [String] = []
    ) {
        self.path = path
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.size = size
        self.tags = tags
    }
    
    enum CodingKeys: String, CodingKey {
        case path
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case size
        case tags
    }
}

public struct LocalFSState: Codable, Sendable {
    public var version: Int
    public var byHash: [String: LocalFSStateEntry]
    
    enum CodingKeys: String, CodingKey {
        case version
        case byHash = "by_hash"
    }
    
    public init(version: Int = 1, byHash: [String: LocalFSStateEntry] = [:]) {
        self.version = version
        self.byHash = byHash
    }
}

public enum LocalFSCollectorError: Error, LocalizedError {
    case watchDirectoryMissing
    case watchDirectoryNotFound(String)
    case watchDirectoryNotDirectory(String)
    case moveDirectoryCreationFailed(String, String)
    case statePersistenceFailed(message: String, path: String)
    
    public var errorDescription: String? {
        switch self {
        case .watchDirectoryMissing:
            return "Watch directory not provided; supply collector_options.watch_dir or configure modules.localfs.default_watch_dir"
        case .watchDirectoryNotFound(let path):
            return "Watch directory not found: \(path)"
        case .watchDirectoryNotDirectory(let path):
            return "Watch path is not a directory: \(path)"
        case .moveDirectoryCreationFailed(let path, let reason):
            return "Failed to prepare move-to directory '\(path)': \(reason)"
        case .statePersistenceFailed(let message, let path):
            return "Failed to persist collector state to \(path): \(message)"
        }
    }
}

public final class LocalFSCollector: @unchecked Sendable {
    public typealias UploadFunction = @Sendable (_ config: GatewayConfig, _ authToken: String, _ fileURL: URL, _ data: Data, _ metadata: LocalFSUploadMeta, _ filename: String, _ idempotencyKey: String, _ mimeType: String) async throws -> GatewayFileSubmissionResponse
    
    private let baseGatewayConfig: GatewayConfig
    private let authToken: String
    private let logger = HavenLogger(category: "localfs-collector")
    private let fileManager = FileManager.default
    private let upload: UploadFunction
    
    public init(gatewayConfig: GatewayConfig, authToken: String, uploader: UploadFunction? = nil) {
        self.baseGatewayConfig = gatewayConfig
        self.authToken = authToken
        if let uploader {
            self.upload = uploader
        } else {
            self.upload = { config, token, fileURL, data, metadata, filename, idempotencyKey, mimeType in
                let client = GatewaySubmissionClient(config: config, authToken: token)
                return try await client.submitFile(
                    fileURL: fileURL,
                    data: data,
                    metadata: metadata,
                    filename: filename,
                    idempotencyKey: idempotencyKey,
                    mimeType: mimeType
                )
            }
        }
    }
    
    public func run(options: LocalFSCollectorOptions) async throws -> LocalFSCollectorResult {
        var isDirectory: ObjCBool = false
        let watchPath = options.watchDirectory.path
        guard fileManager.fileExists(atPath: watchPath, isDirectory: &isDirectory) else {
            throw LocalFSCollectorError.watchDirectoryNotFound(watchPath)
        }
        guard isDirectory.boolValue else {
            throw LocalFSCollectorError.watchDirectoryNotDirectory(watchPath)
        }
        
        if let moveTo = options.moveToDirectory {
            try ensureDirectoryExists(moveTo)
        }
        
        var state = try loadState(at: options.stateFile)
        var stateDirty = false
        
        let enumerator = fileManager.enumerator(
            at: options.watchDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { [logger] url, error in
                logger.warning("Enumerator error", metadata: [
                    "path": url.path,
                    "error": error.localizedDescription
                ])
                return true
            }
        )
        
        var scanned = 0
        var matched = 0
        var submitted = 0
        var skipped = 0
        var warnings: [String] = []
        var errors: [String] = []
        let startTime = Date()
        var processedNewFiles = 0
        
        var gatewayConfig = baseGatewayConfig
        let timeoutSeconds = max(1, Int(options.requestTimeout.rounded()))
        gatewayConfig.timeoutMs = timeoutSeconds * 1000
        
        while let itemURL = enumerator?.nextObject() as? URL {
            scanned += 1
            guard let resourceValues = try? itemURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
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
            
            if resourceValues.isSymbolicLink == true && !options.followSymlinks {
                skipped += 1
                continue
            }
            
            let relativePath = makeRelativePath(for: itemURL, root: options.watchDirectory)
            if !shouldInclude(path: relativePath, include: options.include) {
                skipped += 1
                continue
            }
            if shouldExclude(path: relativePath, exclude: options.exclude) {
                skipped += 1
                continue
            }
            matched += 1
            
            let fileSize = resourceValues.fileSize ?? (try? fileManager.attributesOfItem(atPath: itemURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if fileSize > options.maxFileBytes {
                warnings.append("Skipped \(relativePath) (size \(fileSize) exceeds limit \(options.maxFileBytes) bytes)")
                skipped += 1
                continue
            }
            
            let fileData: Data
            do {
                fileData = try Data(contentsOf: itemURL, options: [.mappedIfSafe])
            } catch {
                errors.append("Failed reading \(relativePath): \(error.localizedDescription)")
                skipped += 1
                continue
            }
            
            let sha256 = shaHex(for: fileData)
            if var entry = state.byHash[sha256] {
                entry.lastSeen = Date()
                entry.path = relativePath
                entry.size = fileSize
                entry.tags = options.tags
                state.byHash[sha256] = entry
                stateDirty = true
                skipped += 1
                continue
            }
            
            let modificationTime = resourceValues.contentModificationDate?.timeIntervalSince1970
            let creationTime = resourceValues.creationDate?.timeIntervalSince1970
            let metadata = LocalFSUploadMeta(
                source: "localfs",
                path: itemURL.path,
                filename: itemURL.lastPathComponent,
                mtime: modificationTime,
                ctime: creationTime,
                tags: options.tags
            )
            
            if options.dryRun {
                warnings.append("Dry-run: would upload \(relativePath)")
            } else {
                do {
                    _ = try await upload(
                        gatewayConfig,
                        authToken,
                        itemURL,
                        fileData,
                        metadata,
                        metadata.filename ?? itemURL.lastPathComponent,
                        "localfs:\(sha256)",
                        mimeType(for: itemURL)
                    )
                    submitted += 1
                } catch {
                    errors.append("Upload failed for \(relativePath): \(error.localizedDescription)")
                    skipped += 1
                    continue
                }
            }
            
            let now = Date()
            state.byHash[sha256] = LocalFSStateEntry(
                path: relativePath,
                firstSeen: now,
                lastSeen: now,
                size: fileSize,
                tags: options.tags
            )
            stateDirty = true
            processedNewFiles += 1
            
            if !options.dryRun {
                if options.deleteAfter {
                    do {
                        try fileManager.removeItem(at: itemURL)
                    } catch {
                        warnings.append("Failed to delete \(relativePath): \(error.localizedDescription)")
                    }
                } else if let moveDirectory = options.moveToDirectory {
                    let destination = moveDirectory.appendingPathComponent(relativePath)
                    do {
                        try ensureParentDirectory(for: destination)
                        if fileManager.fileExists(atPath: destination.path) {
                            try fileManager.removeItem(at: destination)
                        }
                        try fileManager.moveItem(at: itemURL, to: destination)
                    } catch {
                        warnings.append("Failed to move \(relativePath) to \(destination.path): \(error.localizedDescription)")
                    }
                }
            }
            
            if let limit = options.limit, processedNewFiles >= limit {
                break
            }
        }
        
        if stateDirty {
            do {
                try saveState(state, to: options.stateFile)
            } catch {
                logger.error("State persistence failed", metadata: [
                    "error": error.localizedDescription,
                    "path": options.stateFile.path
                ])
                throw LocalFSCollectorError.statePersistenceFailed(
                    message: error.localizedDescription,
                    path: options.stateFile.path
                )
            }
        }
        
        let endTime = Date()
        return LocalFSCollectorResult(
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
    
    public func readState(at url: URL) -> LocalFSState? {
        do {
            return try loadState(at: url)
        } catch {
            logger.debug("Unable to read state file", metadata: [
                "path": url.path,
                "error": error.localizedDescription
            ])
            return nil
        }
    }
    
    // MARK: - Helpers
    
    private func loadState(at url: URL) throws -> LocalFSState {
        if !fileManager.fileExists(atPath: url.path) {
            return LocalFSState()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalFSState.self, from: data)
    }
    
    private func saveState(_ state: LocalFSState, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try ensureDirectoryExists(parent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }
    
    private func ensureDirectoryExists(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw LocalFSCollectorError.moveDirectoryCreationFailed(directory.path, "path exists and is not a directory")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LocalFSCollectorError.moveDirectoryCreationFailed(directory.path, error.localizedDescription)
        }
    }
    
    private func ensureParentDirectory(for destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try ensureDirectoryExists(parent)
    }
    
    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
    
    private func shaHex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    private func shouldInclude(path: String, include: [String]) -> Bool {
        guard !include.isEmpty else { return true }
        return include.contains { patternMatches($0, path: path) || patternMatches($0, path: (path as NSString).lastPathComponent) }
    }
    
    private func shouldExclude(path: String, exclude: [String]) -> Bool {
        guard !exclude.isEmpty else { return false }
        return exclude.contains { patternMatches($0, path: path) || patternMatches($0, path: (path as NSString).lastPathComponent) }
    }
    
    private func patternMatches(_ pattern: String, path: String) -> Bool {
        let fnFlags: Int32 = FNM_CASEFOLD
        return pattern.withCString { patternPtr in
            path.withCString { pathPtr in
                fnmatch(patternPtr, pathPtr, fnFlags) == 0
            }
        }
    }
    
    private func makeRelativePath(for file: URL, root: URL) -> String {
        let filePath = file.path
        let rootPath = root.path
        if filePath.hasPrefix(rootPath) {
            let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
            var relative = String(filePath[start...])
            if relative.hasPrefix("/") {
                relative.removeFirst()
            }
            return relative.isEmpty ? file.lastPathComponent : relative
        }
        return file.lastPathComponent
    }
}

public struct LocalFSUploadMeta: Codable, Sendable {
    public var source: String
    public var path: String
    public var filename: String?
    public var mtime: Double?
    public var ctime: Double?
    public var tags: [String]
    
    public init(
        source: String,
        path: String,
        filename: String? = nil,
        mtime: Double? = nil,
        ctime: Double? = nil,
        tags: [String] = []
    ) {
        self.source = source
        self.path = path
        self.filename = filename
        self.mtime = mtime
        self.ctime = ctime
        self.tags = tags
    }
    
    enum CodingKeys: String, CodingKey {
        case source
        case path
        case filename
        case mtime
        case ctime
        case tags
    }
}
