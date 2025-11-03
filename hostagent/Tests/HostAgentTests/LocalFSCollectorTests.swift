import XCTest
@testable import HostAgentEmail
import HavenCore

final class LocalFSCollectorTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    func testCollectorUploadsNewFileAndUpdatesState() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        
        let watchDir = root.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        let stateFile = root.appendingPathComponent("state.json")
        let sampleFile = watchDir.appendingPathComponent("sample.txt")
        try "hello localfs".data(using: .utf8)?.write(to: sampleFile)
        
        var uploadedMetadata: LocalFSUploadMeta?
        var uploadedData: Data?
        let uploader: LocalFSCollector.UploadFunction = { config, token, fileURL, data, metadata, filename, idempotencyKey, mimeType in
            uploadedMetadata = metadata
            uploadedData = data
            return GatewayFileSubmissionResponse(
                submissionId: "sub-1",
                docId: "doc-1",
                externalId: "ext-1",
                status: "accepted",
                threadId: nil,
                fileIds: [],
                duplicate: false,
                totalChunks: 1,
                fileSha256: "sha",
                objectKey: "obj",
                extractionStatus: "ready"
            )
        }
        
        let collector = LocalFSCollector(
            gatewayConfig: GatewayConfig(),
            authToken: "secret",
            uploader: uploader
        )
        
        let options = LocalFSCollectorOptions(
            watchDirectory: watchDir,
            include: ["*.txt"],
            exclude: [],
            tags: ["docs"],
            moveToDirectory: nil,
            deleteAfter: false,
            dryRun: false,
            oneShot: true,
            stateFile: stateFile,
            maxFileBytes: 1024 * 1024,
            requestTimeout: 5,
            followSymlinks: false,
            limit: nil
        )
        
        let result = try await collector.run(options: options)
        XCTAssertEqual(result.submitted, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.warnings.count, 0)
        XCTAssertEqual(result.errors.count, 0)
        
        XCTAssertNotNil(uploadedMetadata)
        XCTAssertEqual(uploadedMetadata?.path, sampleFile.path)
        XCTAssertEqual(uploadedMetadata?.tags, ["docs"])
        XCTAssertEqual(uploadedData, try Data(contentsOf: sampleFile))
        
        let stateData = try Data(contentsOf: stateFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(LocalFSState.self, from: stateData)
        XCTAssertEqual(state.byHash.count, 1)
        XCTAssertEqual(state.byHash.values.first?.path, "sample.txt")
        XCTAssertEqual(state.byHash.values.first?.tags, ["docs"])
    }
    
    func testCollectorSkipsDuplicates() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        
        let watchDir = root.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        let stateFile = root.appendingPathComponent("state.json")
        let sampleFile = watchDir.appendingPathComponent("sample.txt")
        try "duplicate".data(using: .utf8)?.write(to: sampleFile)
        
        var uploadCount = 0
        let uploader: LocalFSCollector.UploadFunction = { _, _, _, _, _, _, _, _ in
            uploadCount += 1
            return GatewayFileSubmissionResponse(
                submissionId: "sub",
                docId: "doc",
                externalId: "ext",
                status: "accepted",
                threadId: nil,
                fileIds: [],
                duplicate: false,
                totalChunks: 1,
                fileSha256: "sha",
                objectKey: "obj",
                extractionStatus: "ready"
            )
        }
        
        let collector = LocalFSCollector(
            gatewayConfig: GatewayConfig(),
            authToken: "secret",
            uploader: uploader
        )
        
        let options = LocalFSCollectorOptions(
            watchDirectory: watchDir,
            include: ["*.txt"],
            exclude: [],
            tags: [],
            moveToDirectory: nil,
            deleteAfter: false,
            dryRun: false,
            oneShot: true,
            stateFile: stateFile,
            maxFileBytes: 1024 * 1024,
            requestTimeout: 5,
            followSymlinks: false,
            limit: nil
        )
        
        let first = try await collector.run(options: options)
        XCTAssertEqual(first.submitted, 1)
        XCTAssertEqual(uploadCount, 1)
        
        let second = try await collector.run(options: options)
        XCTAssertEqual(second.submitted, 0)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertEqual(uploadCount, 1, "Uploader should not be called for duplicate")
    }
    
    func testDryRunSkipsUploadButPersistsState() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        
        let watchDir = root.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        let stateFile = root.appendingPathComponent("state.json")
        let sampleFile = watchDir.appendingPathComponent("sample.txt")
        try "dry-run".data(using: .utf8)?.write(to: sampleFile)
        
        var uploadCalled = false
        let uploader: LocalFSCollector.UploadFunction = { _, _, _, _, _, _, _, _ in
            uploadCalled = true
            return GatewayFileSubmissionResponse(
                submissionId: "sub",
                docId: "doc",
                externalId: "ext",
                status: "accepted",
                threadId: nil,
                fileIds: [],
                duplicate: false,
                totalChunks: 1,
                fileSha256: "sha",
                objectKey: "obj",
                extractionStatus: "ready"
            )
        }
        
        let collector = LocalFSCollector(
            gatewayConfig: GatewayConfig(),
            authToken: "secret",
            uploader: uploader
        )
        
        let options = LocalFSCollectorOptions(
            watchDirectory: watchDir,
            include: ["*.txt"],
            exclude: [],
            tags: [],
            moveToDirectory: nil,
            deleteAfter: false,
            dryRun: true,
            oneShot: true,
            stateFile: stateFile,
            maxFileBytes: 1024 * 1024,
            requestTimeout: 5,
            followSymlinks: false,
            limit: nil
        )
        
        let result = try await collector.run(options: options)
        XCTAssertEqual(result.submitted, 0)
        XCTAssertFalse(uploadCalled, "Uploader should not be invoked during dry-run")
        
        let stateData = try Data(contentsOf: stateFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(LocalFSState.self, from: stateData)
        XCTAssertEqual(state.byHash.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleFile.path), "File should remain on disk after dry-run")
    }
    
    func testCollectorMovesProcessedFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        
        let watchDir = root.appendingPathComponent("watch", isDirectory: true)
        let processedDir = root.appendingPathComponent("processed", isDirectory: true)
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processedDir, withIntermediateDirectories: true)
        let stateFile = root.appendingPathComponent("state.json")
        let sampleFile = watchDir.appendingPathComponent("subdir", isDirectory: true)
            .appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: sampleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Note".data(using: .utf8)?.write(to: sampleFile)
        
        let uploader: LocalFSCollector.UploadFunction = { _, _, _, _, _, _, _, _ in
            return GatewayFileSubmissionResponse(
                submissionId: "sub",
                docId: "doc",
                externalId: "ext",
                status: "accepted",
                threadId: nil,
                fileIds: [],
                duplicate: false,
                totalChunks: 1,
                fileSha256: "sha",
                objectKey: "obj",
                extractionStatus: "ready"
            )
        }
        
        let collector = LocalFSCollector(
            gatewayConfig: GatewayConfig(),
            authToken: "secret",
            uploader: uploader
        )
        
        let options = LocalFSCollectorOptions(
            watchDirectory: watchDir,
            include: ["*.md"],
            exclude: [],
            tags: [],
            moveToDirectory: processedDir,
            deleteAfter: false,
            dryRun: false,
            oneShot: true,
            stateFile: stateFile,
            maxFileBytes: 1024 * 1024,
            requestTimeout: 5,
            followSymlinks: false,
            limit: nil
        )
        
        let result = try await collector.run(options: options)
        XCTAssertEqual(result.submitted, 1)
        let movedFile = processedDir.appendingPathComponent("subdir").appendingPathComponent("note.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sampleFile.path))
    }
}
