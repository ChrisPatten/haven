import XCTest
@testable import Core
@testable import IMessages
import GRDB
import Logging
import Darwin

final class IMessagesModuleTests: XCTestCase {
    func testBackfillAdvancesCursorAndEmitsEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("imsg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let attachmentsRoot = tempDir.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsRoot, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("chat.db")

        try createFixtureDatabase(at: dbURL, attachmentsRoot: attachmentsRoot)

        let stateURL = tempDir.appendingPathComponent("imessage_state.json")
        let gateway = MockGateway()
        let ocr = DisabledOCR()
        var config = HostAgentConfiguration.IMessagesConfig(batchSize: 10, ocrEnabled: false, timeoutSeconds: 5, backfillMaxRows: nil)
        config.ocrEnabled = false

        let module = IMessagesModule(
            configuration: config,
            ocr: ocr,
            gateway: gateway,
            stateURL: stateURL,
            ocrLanguages: ["en"]
        )

        let previousDBPath = getenv("IMESSAGE_DB_PATH").flatMap { String(cString: $0) }
        setenv("IMESSAGE_DB_PATH", dbURL.path, 1)
        let previousAttachments = getenv("IMESSAGE_ATTACHMENTS_ROOT").flatMap { String(cString: $0) }
        setenv("IMESSAGE_ATTACHMENTS_ROOT", attachmentsRoot.path, 1)
        defer {
            if let previousDBPath {
                setenv("IMESSAGE_DB_PATH", previousDBPath, 1)
            } else {
                unsetenv("IMESSAGE_DB_PATH")
            }
            if let previousAttachments {
                setenv("IMESSAGE_ATTACHMENTS_ROOT", previousAttachments, 1)
            } else {
                unsetenv("IMESSAGE_ATTACHMENTS_ROOT")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let context = ModuleContext(
            configuration: HostAgentConfiguration(),
            moduleConfigPath: nil,
            stateDirectory: tempDir,
            tmpDirectory: tempDir,
            gatewayClient: gateway
        )
        try await module.boot(context: context)

        let response = try await module.run(request: IMessagesRunRequest(mode: .backfill, batchSize: 5, maxRows: nil))
        XCTAssertEqual(response.processed, 2)
        XCTAssertEqual(gateway.ingestBatchCount, 1)
        let events = try gateway.decodeEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].sourceType == "imessage")
        XCTAssertTrue(events[0].metadata.thread.chatGUID.contains("chat"))

        let state = await module.state()
        XCTAssertEqual(state.cursorRowID, 2)
        XCTAssertEqual(state.headRowID, 2)
    }

    private func createFixtureDatabase(at url: URL, attachmentsRoot: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE message(
                    rowid INTEGER PRIMARY KEY,
                    guid TEXT,
                    text TEXT,
                    attributedBody BLOB,
                    service TEXT,
                    date INTEGER,
                    is_from_me INTEGER,
                    handle_id INTEGER
                );
                CREATE TABLE handle(
                    rowid INTEGER PRIMARY KEY,
                    id TEXT,
                    country TEXT,
                    phone_number TEXT,
                    email TEXT
                );
                CREATE TABLE chat(
                    rowid INTEGER PRIMARY KEY,
                    guid TEXT,
                    chat_identifier TEXT,
                    display_name TEXT,
                    service_name TEXT
                );
                CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
                CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
                CREATE TABLE attachment(
                    rowid INTEGER PRIMARY KEY,
                    guid TEXT,
                    filename TEXT,
                    uti TEXT,
                    mime_type TEXT
                );
                CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
            """)

            try db.execute(sql: "INSERT INTO handle(rowid, id, phone_number) VALUES (1, '+15551234567', '+15551234567')")
            try db.execute(sql: "INSERT INTO chat(rowid, guid, chat_identifier, display_name, service_name) VALUES (1, 'chat1', '+15551234567', 'Test Chat', 'iMessage')")
            try db.execute(sql: "INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1)")

            let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
            try db.execute(sql: "INSERT INTO message(rowid, guid, text, service, date, is_from_me, handle_id) VALUES (1, 'msg1', 'Hello world', 'iMessage', ?, 1, 1)", arguments: [now])
            try db.execute(sql: "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

            let attachmentDir = attachmentsRoot.appendingPathComponent("AB", isDirectory: true)
            try FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
            let attachmentFile = attachmentDir.appendingPathComponent("sample.txt")
            try "Attachment".data(using: .utf8)!.write(to: attachmentFile)

            try db.execute(sql: "INSERT INTO message(rowid, guid, text, service, date, is_from_me, handle_id) VALUES (2, 'msg2', 'Has attachment', 'iMessage', ?, 0, 1)", arguments: [now + 10])
            try db.execute(sql: "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
            try db.execute(sql: "INSERT INTO attachment(rowid, guid, filename, uti, mime_type) VALUES (1, 'att1', ?, 'public.data', 'text/plain')", arguments: ["AB/sample.txt"])
            try db.execute(sql: "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (2, 1)")
        }
    }
}

private final class DisabledOCR: OCRService {
    let kind: ModuleKind = .ocr
    let logger = Logger(label: "OCR.Disabled")

    func boot(context: ModuleContext) async throws {}
    func shutdown() async {}
    func summary() async -> ModuleSummary { ModuleSummary(kind: kind, enabled: false, status: "stub") }
    func performOCR(payload: OCRRequest.Payload, preferredLanguages: [String], timeout: TimeInterval) async throws -> OCRResponseBody {
        throw NSError(domain: "test", code: 0)
    }
    func health() async -> [String : String] { [:] }
    func updateConfiguration(_ config: HostAgentConfiguration.OCRConfig) async {}
}

private final class MockGateway: GatewayTransport {
    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private var ingestPayloads: [Data] = []

    func ingest<Event: Encodable>(events: [Event]) async throws {
        let data = try encoder.encode(events)
        lock.lock()
        ingestPayloads.append(data)
        lock.unlock()
    }

    func requestPresignedPut(path: String, sha256: String, size: Int64) async throws -> URL {
        URL(string: "https://example.com/upload")!
    }

    func notifyFileIngested(_ event: FileIngestEvent) async throws {}

    func upload(fileData: Data, to url: URL) async throws {}

    var ingestBatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ingestPayloads.count
    }

    func decodeEvents() throws -> [GatewayEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = ingestPayloads.first else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GatewayEvent].self, from: data)
    }
}

private struct GatewayEvent: Decodable {
    struct Thread: Decodable {
        let chatGUID: String
        let participants: [String]
        let service: String

        enum CodingKeys: String, CodingKey {
            case chatGUID = "chat_guid"
            case participants
            case service
        }
    }

    struct Message: Decodable {
        let rowid: Int64
        let attachments: [Attachment]

        enum CodingKeys: String, CodingKey {
            case rowid
            case attachments
        }
    }

    struct Attachment: Decodable {
        let id: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case id
            case status
        }
    }

    let sourceType: String
    let sourceID: String
    let content: String
    let metadata: Metadata

    struct Metadata: Decodable {
        let thread: Thread
        let message: Message

        enum CodingKeys: String, CodingKey {
            case thread
            case message
        }
    }

    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case sourceID = "source_id"
        case content
        case metadata
    }
}
