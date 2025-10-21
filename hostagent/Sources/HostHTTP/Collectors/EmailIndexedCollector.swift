import Foundation
import SQLite3
import HavenCore

/// Errors thrown by the indexed email collector.
public enum EmailCollectorError: Error, LocalizedError {
    case envelopeIndexNotFound
    case sqliteOpenFailed(String)
    case sqlitePrepareFailed(String)
    case sqliteStepFailed(String)
    case invalidMailboxURL(String)
    
    public var errorDescription: String? {
        switch self {
        case .envelopeIndexNotFound:
            return "Envelope Index database not found"
        case .sqliteOpenFailed(let reason):
            return "Failed to open Envelope Index: \(reason)"
        case .sqlitePrepareFailed(let reason):
            return "Failed to prepare Envelope Index query: \(reason)"
        case .sqliteStepFailed(let reason):
            return "Envelope Index query failed: \(reason)"
        case .invalidMailboxURL(let url):
            return "Invalid mailbox URL: \(url)"
        }
    }
}

/// Result of an indexed run, including resolved messages and warnings.
public struct EmailIndexedRunResult: Sendable {
    public let messages: [EmailIndexedMessage]
    public let warnings: [String]
    public let lastRowID: Int64
    
    public init(messages: [EmailIndexedMessage], warnings: [String], lastRowID: Int64) {
        self.messages = messages
        self.warnings = warnings
        self.lastRowID = lastRowID
    }
}

/// Indexed message metadata resolved from Envelope Index.
public struct EmailIndexedMessage: Sendable {
    public let rowID: Int64
    public let subject: String?
    public let sender: String?
    public let toList: [String]
    public let ccList: [String]
    public let bccList: [String]
    public let dateSent: Date?
    public let mailboxName: String?
    public let mailboxDisplayName: String?
    public let mailboxPath: String?
    public let flags: Int64
    public let isVIP: Bool
    public let remoteID: String?
    public let guid: String?
    public let emlxPath: URL?
    public let fileInode: UInt64?
    public let fileMtime: Date?
    
    public init(
        rowID: Int64,
        subject: String?,
        sender: String?,
        toList: [String],
        ccList: [String],
        bccList: [String],
        dateSent: Date?,
        mailboxName: String?,
        mailboxDisplayName: String?,
        mailboxPath: String?,
        flags: Int64,
        isVIP: Bool,
        remoteID: String?,
        guid: String?,
        emlxPath: URL?,
        fileInode: UInt64?,
        fileMtime: Date?
    ) {
        self.rowID = rowID
        self.subject = subject
        self.sender = sender
        self.toList = toList
        self.ccList = ccList
        self.bccList = bccList
        self.dateSent = dateSent
        self.mailboxName = mailboxName
        self.mailboxDisplayName = mailboxDisplayName
        self.mailboxPath = mailboxPath
        self.flags = flags
        self.isVIP = isVIP
        self.remoteID = remoteID
        self.guid = guid
        self.emlxPath = emlxPath
        self.fileInode = fileInode
        self.fileMtime = fileMtime
    }
}

/// Persistent state for incremental sync.
private struct EmailCollectorState: Codable {
    struct FileInfo: Codable {
        var rowID: Int64
        var path: String
        var inode: UInt64?
        var mtime: TimeInterval?
    }
    
    var lastRowID: Int64
    var files: [String: FileInfo]
    
    init(lastRowID: Int64 = 0, files: [String: FileInfo] = [:]) {
        self.lastRowID = lastRowID
        self.files = files
    }
}

/// Messages read from the Envelope Index before filtering.
private struct EnvelopeRecord {
    let rowID: Int64
    let subject: String?
    let sender: String?
    let toList: String?
    let ccList: String?
    let bccList: String?
    let dateSent: Double?
    let remoteID: String?
    let guid: String?
    let flags: Int64
    let mailboxURL: URL?
    let mailboxName: String?
    let mailboxDisplayName: String?
}

/// Collector responsible for reading Envelope Index and resolving .emlx paths.
public actor EmailIndexedCollector {
    private let logger = HavenLogger(category: "email-indexed-collector")
    private let fileManager: FileManager
    private let mailRoot: URL
    private let stateFileURL: URL
    private let envelopeIndexOverride: URL?
    private let stateRetentionLimit = 500
    
    // VIP flag derived from observed Mail.app bitmask (0x20000).
    private let vipFlagMask: Int64 = 0x20000
    
    public init(mailRoot: URL? = nil, envelopeIndexOverride: URL? = nil, stateFileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.mailRoot = mailRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
        self.envelopeIndexOverride = envelopeIndexOverride
        if let providedStateURL = stateFileURL {
            self.stateFileURL = providedStateURL
        } else {
            self.stateFileURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".haven", isDirectory: true)
                .appendingPathComponent("email_collector_state.json", isDirectory: false)
        }
    }
    
    /// Execute an indexed run and persist state updates.
    public func run(limit: Int) throws -> EmailIndexedRunResult {
        let state = try loadState()
        let dbURL = try locateEnvelopeIndex()
        let records = try readEnvelopeIndex(from: dbURL, after: state.lastRowID, limit: limit)
        
        guard !records.isEmpty else {
            logger.debug("No new messages in Envelope Index", metadata: ["last_rowid": "\(state.lastRowID)"])
            return EmailIndexedRunResult(messages: [], warnings: [], lastRowID: state.lastRowID)
        }
        
        let filtered = filterMailboxes(records)
        let resolution = resolveEmlxPaths(for: filtered)
        
        var nextState = state
        if let maxRowID = records.map(\.rowID).max() {
            nextState.lastRowID = max(nextState.lastRowID, maxRowID)
        }
        updateState(&nextState, with: resolution.messages)
        try saveState(nextState)
        
        return EmailIndexedRunResult(
            messages: resolution.messages,
            warnings: resolution.warnings,
            lastRowID: nextState.lastRowID
        )
    }
    
    // MARK: - Lookup
    
    private func locateEnvelopeIndex() throws -> URL {
        if let override = envelopeIndexOverride {
            guard fileManager.fileExists(atPath: override.path) else {
                throw EmailCollectorError.envelopeIndexNotFound
            }
            return override
        }
        
        guard fileManager.fileExists(atPath: mailRoot.path) else {
            throw EmailCollectorError.envelopeIndexNotFound
        }
        
        var newestURL: URL?
        var newestDate: Date?
        
        guard let contents = try? fileManager.contentsOfDirectory(at: mailRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            throw EmailCollectorError.envelopeIndexNotFound
        }
        
        for versionDir in contents where versionDir.lastPathComponent.hasPrefix("V") {
            let enumeratorRoot = versionDir.appendingPathComponent("MailData", isDirectory: true)
            let candidate = enumeratorRoot.appendingPathComponent("Envelope Index", isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                let attrs = try? candidate.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = attrs?.contentModificationDate ?? Date.distantPast
                if newestURL == nil || (newestDate ?? Date.distantPast) < modified {
                    newestURL = candidate
                    newestDate = modified
                }
            }
        }
        
        guard let result = newestURL else {
            throw EmailCollectorError.envelopeIndexNotFound
        }
        
        return result
    }
    
    // MARK: - Reading
    
    private func readEnvelopeIndex(from dbURL: URL, after lastRowID: Int64, limit: Int) throws -> [EnvelopeRecord] {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw EmailCollectorError.sqliteOpenFailed(message)
        }
        defer { sqlite3_close(db) }
        
        let query = """
            SELECT
                messages.ROWID,
                messages.subject,
                messages.sender,
                messages.to_list,
                messages.cc_list,
                messages.bcc_list,
                messages.date_sent,
                messages.remote_id,
                messages.guid,
                messages.flags,
                mailboxes.url,
                mailboxes.name,
                mailboxes.displayName
            FROM messages
            LEFT JOIN mailboxes ON mailboxes.ROWID = messages.mailbox
            WHERE messages.ROWID > ?
            ORDER BY messages.ROWID ASC
            LIMIT ?
            """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw EmailCollectorError.sqlitePrepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_int64(statement, 1, lastRowID)
        sqlite3_bind_int(statement, 2, Int32(limit))
        
        var records: [EnvelopeRecord] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                let record = EnvelopeRecord(
                    rowID: sqlite3_column_int64(statement, 0),
                    subject: columnText(statement, index: 1),
                    sender: columnText(statement, index: 2),
                    toList: columnText(statement, index: 3),
                    ccList: columnText(statement, index: 4),
                    bccList: columnText(statement, index: 5),
                    dateSent: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                    remoteID: columnText(statement, index: 7),
                    guid: columnText(statement, index: 8),
                    flags: sqlite3_column_int64(statement, 9),
                    mailboxURL: decodeMailboxURL(columnText(statement, index: 10)),
                    mailboxName: columnText(statement, index: 11),
                    mailboxDisplayName: columnText(statement, index: 12)
                )
                records.append(record)
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                let message = String(cString: sqlite3_errmsg(db))
                throw EmailCollectorError.sqliteStepFailed(message)
            }
        }
        
        return records
    }
    
    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }
    
    private func decodeMailboxURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        if value.starts(with: "file://") || value.starts(with: "FILE://") {
            return URL(string: value)
        }
        return URL(fileURLWithPath: value)
    }
    
    // MARK: - Filtering
    
    private func filterMailboxes(_ records: [EnvelopeRecord]) -> [EnvelopeRecord] {
        let ignoreKeywords = ["junk", "trash", "spam", "bin", "deleted", "promotion", "promotions"]
        return records.filter { record in
            guard let mailboxName = (record.mailboxDisplayName ?? record.mailboxName)?.lowercased() else {
                return true
            }
            
            let shouldIgnore = ignoreKeywords.contains { keyword in
                mailboxName.contains(keyword)
            }
            
            if shouldIgnore {
                return isVIP(flags: record.flags)
            }
            return true
        }
    }
    
    private func isVIP(flags: Int64) -> Bool {
        return (flags & vipFlagMask) != 0
    }
    
    // MARK: - Path Resolution
    
    private func resolveEmlxPaths(for records: [EnvelopeRecord]) -> (messages: [EmailIndexedMessage], warnings: [String]) {
        var messages: [EmailIndexedMessage] = []
        var warnings: [String] = []
        
        for record in records {
            let pathResult = resolveEmlxPath(for: record)
            if pathResult.path == nil {
                warnings.append("Missing .emlx file for ROWID \(record.rowID)")
            }
            
            let metadata = EmailIndexedMessage(
                rowID: record.rowID,
                subject: record.subject,
                sender: record.sender,
                toList: splitAddressList(record.toList),
                ccList: splitAddressList(record.ccList),
                bccList: splitAddressList(record.bccList),
                dateSent: record.dateSent.map { Date(timeIntervalSinceReferenceDate: $0) },
                mailboxName: record.mailboxName,
                mailboxDisplayName: record.mailboxDisplayName,
                mailboxPath: record.mailboxURL?.path,
                flags: record.flags,
                isVIP: isVIP(flags: record.flags),
                remoteID: record.remoteID,
                guid: record.guid,
                emlxPath: pathResult.path,
                fileInode: pathResult.fileInfo?.inode,
                fileMtime: pathResult.fileInfo?.mtime
            )
            messages.append(metadata)
        }
        
        return (messages, warnings)
    }
    
    private func resolveEmlxPath(for record: EnvelopeRecord) -> (path: URL?, fileInfo: (inode: UInt64?, mtime: Date?)?) {
        guard let mailboxURL = record.mailboxURL else {
            return (nil, nil)
        }
        
        let remoteID = record.remoteID ?? "\(record.rowID)"
        let candidates = candidateEmlxPaths(mailboxURL: mailboxURL, remoteID: remoteID, rowID: record.rowID)
        
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            let fileInfo = fileAttributes(for: url)
            return (url, fileInfo)
        }
        
        // Limited depth search fallback.
        if let enumerator = fileManager.enumerator(at: mailboxURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var scanned = 0
            while let candidate = enumerator.nextObject() as? URL {
                if candidate.pathExtension.lowercased() == "emlx" {
                    if candidate.lastPathComponent.hasPrefix(remoteID) || candidate.lastPathComponent.hasPrefix("\(record.rowID)") {
                        let info = fileAttributes(for: candidate)
                        return (candidate, info)
                    }
                }
                scanned += 1
                if scanned >= 200 {
                    break
                }
            }
        }
        
        return (nil, nil)
    }
    
    private func candidateEmlxPaths(mailboxURL: URL, remoteID: String, rowID: Int64) -> [URL] {
        var candidates: [URL] = []
        let dataDir = mailboxURL.appendingPathComponent("Data", isDirectory: true)
        let direct = dataDir.appendingPathComponent("\(remoteID).emlx", isDirectory: false)
        candidates.append(direct)
        let rowFallback = dataDir.appendingPathComponent("\(rowID).emlx", isDirectory: false)
        candidates.append(rowFallback)
        
        for bucket in 0..<32 {
            let bucketDir = dataDir.appendingPathComponent("\(bucket)", isDirectory: true)
            candidates.append(bucketDir.appendingPathComponent("\(remoteID).emlx", isDirectory: false))
            candidates.append(bucketDir.appendingPathComponent("\(rowID).emlx", isDirectory: false))
        }
        
        return candidates
    }
    
    private func fileAttributes(for url: URL) -> (inode: UInt64?, mtime: Date?) {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            let mtime = attributes[.modificationDate] as? Date
            return (inode, mtime)
        } catch {
            logger.debug("Failed to read file attributes", metadata: ["path": url.path, "error": error.localizedDescription])
            return (nil, nil)
        }
    }
    
    private func splitAddressList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    // MARK: - State Management
    
    private func loadState() throws -> EmailCollectorState {
        guard fileManager.fileExists(atPath: stateFileURL.path) else {
            return EmailCollectorState()
        }
        
        let data = try Data(contentsOf: stateFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(EmailCollectorState.self, from: data)
    }
    
    private func saveState(_ state: EmailCollectorState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let directory = stateFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: stateFileURL, options: [.atomic])
    }
    
    private func updateState(_ state: inout EmailCollectorState, with messages: [EmailIndexedMessage]) {
        for message in messages {
            guard let path = message.emlxPath?.path else { continue }
            let key = String(message.rowID)
            state.files[key] = EmailCollectorState.FileInfo(
                rowID: message.rowID,
                path: path,
                inode: message.fileInode,
                mtime: message.fileMtime?.timeIntervalSince1970
            )
        }
        
        if state.files.count > stateRetentionLimit {
            let sortedKeys = state.files
                .values
                .sorted { $0.rowID < $1.rowID }
                .map { String($0.rowID) }
            let excess = state.files.count - stateRetentionLimit
            for key in sortedKeys.prefix(excess) {
                state.files.removeValue(forKey: key)
            }
        }
    }
}
