import XCTest
import SQLite3
@testable import HostHTTP

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class EmailIndexedCollectorTests: XCTestCase {
    private var tempRoot: URL!
    private var stateURL: URL!
    private var builder: MailFixtureBuilder!
    
    override func setUpWithError() throws {
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        stateURL = tempRoot.appendingPathComponent("state.json")
        builder = try MailFixtureBuilder(root: tempRoot)
    }
    
    override func tearDownWithError() throws {
        if let root = tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        builder = nil
    }
    
    func testRunProcessesNewMessagesAndUpdatesState() async throws {
        let mailbox = try builder.createMailbox(name: "INBOX", displayName: "Inbox")
        let remoteID = "1001"
        try builder.addMessage(mailbox: mailbox, subject: "Hello Indexed Mode", remoteID: remoteID, flags: 0)
        
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, envelopeIndexOverride: nil, stateFileURL: stateURL)
        let result = try await collector.run(limit: 50)
        
        XCTAssertEqual(result.messages.count, 1)
        let message = try XCTUnwrap(result.messages.first)
        XCTAssertEqual(message.rowID, 1)
        XCTAssertEqual(message.remoteID, remoteID)
        XCTAssertEqual(result.lastRowID, 1)
        XCTAssertEqual(result.warnings.count, 0)
        XCTAssertEqual(message.mailboxDisplayName, "Inbox")
        XCTAssertEqual(message.emlxPath?.lastPathComponent, "\(remoteID).emlx")
        XCTAssertNotNil(message.fileInode)
        XCTAssertNotNil(message.fileMtime)
        
        let stateData = try Data(contentsOf: stateURL)
        let stateJSON = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        XCTAssertEqual(stateJSON?["lastRowID"] as? Int, 1)
        if
            let files = stateJSON?["files"] as? [String: Any],
            let entry = files["1"] as? [String: Any],
            let storedPath = entry["path"] as? String
        {
            XCTAssertEqual(storedPath, message.emlxPath?.path)
        } else {
            XCTFail("State missing entry for row 1")
        }
    }
    
    func testIncrementalSyncUsesLastRowID() async throws {
        let mailbox = try builder.createMailbox(name: "INBOX", displayName: "Inbox")
        try builder.addMessage(mailbox: mailbox, subject: "First", remoteID: "2001", flags: 0)
        
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, stateFileURL: stateURL)
        _ = try await collector.run(limit: 10)
        
        try builder.addMessage(mailbox: mailbox, subject: "Second", remoteID: "2002", flags: 0)
        let result = try await collector.run(limit: 10)
        
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages.first?.rowID, 2)
        XCTAssertEqual(result.lastRowID, 2)
    }
    
    func testFiltersJunkMailboxUnlessVIP() async throws {
        let junkMailbox = try builder.createMailbox(name: "Junk", displayName: "Junk")
        try builder.addMessage(mailbox: junkMailbox, subject: "Spam", remoteID: "3001", flags: 0)
        
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, stateFileURL: stateURL)
        let result = try await collector.run(limit: 10)
        XCTAssertEqual(result.messages.count, 0)
        XCTAssertEqual(result.lastRowID, 1)
        
        try builder.addMessage(mailbox: junkMailbox, subject: "VIP", remoteID: "3002", flags: 0x20000)
        let secondResult = try await collector.run(limit: 10)
        XCTAssertEqual(secondResult.messages.count, 1)
        XCTAssertTrue(secondResult.messages.first?.isVIP ?? false)
        XCTAssertEqual(secondResult.lastRowID, 2)
    }
}

// MARK: - Test Fixture Builder

struct MailboxDescriptor {
    let id: Int64
    let path: URL
}

final class MailFixtureBuilder {
    let mailRoot: URL
    private let versionDir: URL
    private let mailboxesDir: URL
    private let mailDataDir: URL
    private let dbURL: URL
    private let fileManager = FileManager.default
    
    init(root: URL) throws {
        mailRoot = root
        versionDir = root.appendingPathComponent("VTest", isDirectory: true)
        mailboxesDir = versionDir.appendingPathComponent("Mailboxes", isDirectory: true)
        mailDataDir = versionDir.appendingPathComponent("MailData", isDirectory: true)
        dbURL = mailDataDir.appendingPathComponent("Envelope Index", isDirectory: false)

        try fileManager.createDirectory(at: mailDataDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mailboxesDir, withIntermediateDirectories: true)
        try createDatabase()
    }
    
    func createMailbox(name: String, displayName: String) throws -> MailboxDescriptor {
        let mailboxDir = mailboxesDir.appendingPathComponent("\(name).mbox", isDirectory: true)
        let dataDir = mailboxDir.appendingPathComponent("Data/0", isDirectory: true)
        try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        
        let mailboxID = try withDatabase { db -> Int64 in
            let sql = "INSERT INTO mailboxes (name, displayName, url) VALUES (?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "MailFixtureBuilder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare mailbox insert"])
            }
            defer { sqlite3_finalize(statement) }
            
            sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, displayName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, mailboxDir.absoluteString, -1, SQLITE_TRANSIENT)
            
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "MailFixtureBuilder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to insert mailbox"])
            }
            return sqlite3_last_insert_rowid(db)
        }
        
        return MailboxDescriptor(id: mailboxID, path: mailboxDir)
    }
    
    func addMessage(mailbox: MailboxDescriptor, subject: String, remoteID: String, flags: Int64) throws {
        let dateSent = Date().timeIntervalSinceReferenceDate
        try withDatabase { db in
            let sql = """
                INSERT INTO messages (subject, sender, to_list, cc_list, bcc_list, date_sent, remote_id, guid, flags, mailbox)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "MailFixtureBuilder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare message insert"])
            }
            defer { sqlite3_finalize(statement) }
            
            sqlite3_bind_text(statement, 1, subject, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, "Sender <sender@example.com>", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, "to@example.com", -1, SQLITE_TRANSIENT)
            sqlite3_bind_null(statement, 4)
            sqlite3_bind_null(statement, 5)
            sqlite3_bind_double(statement, 6, dateSent)
            sqlite3_bind_text(statement, 7, remoteID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 8, UUID().uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 9, flags)
            sqlite3_bind_int64(statement, 10, mailbox.id)
            
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "MailFixtureBuilder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to insert message"])
            }
        }
        
        let emlxURL = mailbox.path.appendingPathComponent("Data/0/\(remoteID).emlx")
        let payload = """
        5
        Test
        """
        try payload.write(to: emlxURL, atomically: true, encoding: .utf8)
    }
    
    private func createDatabase() throws {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(dbURL.path, &db, openFlags, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "MailFixtureBuilder", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create test Envelope Index"])
        }
        defer { sqlite3_close(db) }
        
        let createMailboxes = """
            CREATE TABLE IF NOT EXISTS mailboxes (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT,
                displayName TEXT,
                url TEXT
            );
            """
        let createMessages = """
            CREATE TABLE IF NOT EXISTS messages (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                subject TEXT,
                sender TEXT,
                to_list TEXT,
                cc_list TEXT,
                bcc_list TEXT,
                date_sent REAL,
                remote_id TEXT,
                guid TEXT,
                flags INTEGER,
                mailbox INTEGER REFERENCES mailboxes(ROWID)
            );
            """
        
        if sqlite3_exec(db, createMailboxes, nil, nil, nil) != SQLITE_OK ||
            sqlite3_exec(db, createMessages, nil, nil, nil) != SQLITE_OK {
            throw NSError(domain: "MailFixtureBuilder", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create tables"])
        }
    }
    
    private func withDatabase<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "MailFixtureBuilder", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to open database"])
        }
        defer { sqlite3_close(db) }
        return try block(db)
    }
}
