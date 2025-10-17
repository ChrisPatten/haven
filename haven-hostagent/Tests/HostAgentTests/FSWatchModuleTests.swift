import XCTest
@testable import Core
@testable import FSWatch
import Logging

final class FSWatchModuleTests: XCTestCase {
    func testFileCreationTriggersGatewayNotification() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("fswatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expectation = expectation(description: "gateway notified")
        let gateway = FSWatchMockGateway(expectation: expectation)
        let module = FSWatchModule(configuration: HostAgentConfiguration.FSWatchConfig(), gateway: gateway)

        let context = ModuleContext(
            configuration: HostAgentConfiguration(),
            moduleConfigPath: nil,
            stateDirectory: tempDir,
            tmpDirectory: tempDir,
            gatewayClient: gateway
        )
        try await module.boot(context: context)

        _ = try await module.registerWatch(FileWatchRegistrationRequest(path: tempDir.path, glob: "*.txt", target: "gateway", handoff: "presigned"))

        let fileURL = tempDir.appendingPathComponent("example.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(gateway.uploadedFiles.count, 1)
        XCTAssertEqual(gateway.notifications.count, 1)

        await module.shutdown()
    }
}

final class FSWatchMockGateway: GatewayTransport, @unchecked Sendable {
    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "fswatch.mock")
    private let expectation: XCTestExpectation
    private(set) var uploadedFiles: [URL] = []
    private(set) var notifications: [FileIngestEvent] = []

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func ingest<Event: Encodable>(events: [Event]) async throws {}

    func requestPresignedPut(path: String, sha256: String, size: Int64) async throws -> URL {
        URL(string: "https://example.com/upload")!
    }

    func notifyFileIngested(_ event: FileIngestEvent) async throws {
        queue.sync {
            notifications.append(event)
        }
        expectation.fulfill()
    }

    func upload(fileData: Data, to url: URL) async throws {
        queue.sync {
            uploadedFiles.append(url)
        }
    }
}
