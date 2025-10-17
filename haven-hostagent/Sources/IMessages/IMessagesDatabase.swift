import Core
import Foundation
import GRDB
import Logging

struct IMessagesAttachment {
    let id: String
    let uti: String
    let originalPath: String
    let resolvedURL: URL?
    let sha256: String?
    let isImage: Bool
    var ocrStatus: String?
    var error: String?
}

struct IMessagesRow {
    let rowID: Int64
    let guid: String
    let chatGUID: String
    let participants: [String]
    let service: String
    let normalizedBody: String?
    let date: Date
    let isFromMe: Bool
    let handleID: String
    let handlePhone: String?
    let handleEmail: String?
    let attachments: [IMessagesAttachment]
}

final class IMessagesDatabase {
    private let dbQueue: DatabaseQueue
    private let logger = Logger(label: "HostAgent.IMessages.DB")

    init(snapshot: IMessagesSnapshot) throws {
        dbQueue = try DatabaseQueue(path: snapshot.databaseURL.path)
    }

    func fetchHeadRowID() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM message") ?? 0
        }
    }

    func fetchFloorRowID() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MIN(rowid), 0) FROM message") ?? 0
        }
    }

    func fetchMessages(after cursor: Int64, limit: Int, maxRow: Int?) throws -> [IMessagesRow] {
        try dbQueue.read { db in
            var sql = """
            SELECT
                message.rowid AS message_rowid,
                message.guid AS message_guid,
                message.text AS text,
                message.attributedBody AS attributed_body,
                message.service AS service,
                message.date AS message_date,
                message.is_from_me AS is_from_me,
                handle.id AS handle_id,
                handle.country AS handle_country,
                handle.phone_number AS handle_phone,
                handle.email AS handle_email,
                chat.guid AS chat_guid,
                chat.display_name AS chat_display_name,
                chat.chat_identifier AS chat_identifier
            FROM message
            LEFT JOIN handle ON message.handle_id = handle.rowid
            LEFT JOIN chat_message_join ON message.rowid = chat_message_join.message_id
            LEFT JOIN chat ON chat_message_join.chat_id = chat.rowid
            WHERE message.rowid > ?
            """
            var arguments: [DatabaseValueConvertible?] = [cursor]
            if let maxRow {
                sql += " AND message.rowid <= ?"
                arguments.append(maxRow)
            }
            sql += " ORDER BY message.rowid ASC LIMIT ?"
            arguments.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return try rows.map { try self.buildRow(from: $0, db: db) }
        }
    }

    private func buildRow(from row: Row, db: Database) throws -> IMessagesRow {
        let rowID: Int64 = row["message_rowid"]
        let guid: String = row["message_guid"] ?? "\(rowID)"
        let chatGUID: String = row["chat_guid"] ?? row["chat_identifier"] ?? "unknown"
        let service: String = row["service"] ?? "iMessage"
        let text: String? = row["text"]
        let attributedBodyData: Data? = row["attributed_body"]
        let normalizedBody = text ?? (attributedBodyData.flatMap(Self.decodeAttributedBody))

        let dateValue: Int64 = row["message_date"] ?? 0
        let timestamp = Self.dateFromAppleEpoch(dateValue)

        let isFromMe: Bool = (row["is_from_me"] ?? 0) == 1
        let handleID: String = row["handle_id"] ?? (isFromMe ? "me" : "unknown")
        let handlePhone: String? = row["handle_phone"]
        let handleEmail: String? = row["handle_email"]

        let participants = try fetchParticipants(for: chatGUID, db: db)
        let attachments = try fetchAttachments(for: rowID, db: db)

        return IMessagesRow(
            rowID: rowID,
            guid: guid,
            chatGUID: chatGUID,
            participants: participants,
            service: service,
            normalizedBody: normalizedBody,
            date: timestamp,
            isFromMe: isFromMe,
            handleID: handleID,
            handlePhone: handlePhone,
            handleEmail: handleEmail,
            attachments: attachments
        )
    }

    private func fetchParticipants(for chatGUID: String, db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT DISTINCT handle.id
            FROM chat
            JOIN chat_handle_join ON chat.rowid = chat_handle_join.chat_id
            JOIN handle ON chat_handle_join.handle_id = handle.rowid
            WHERE chat.guid = ?
            """,
            arguments: [chatGUID]
        )
    }

    private func fetchAttachments(for messageRowID: Int64, db: Database) throws -> [IMessagesAttachment] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                attachment.rowid AS attachment_rowid,
                attachment.guid AS attachment_guid,
                attachment.filename AS filename,
                attachment.uti AS uti,
                attachment.mime_type AS mime_type
            FROM message_attachment_join
            JOIN attachment ON message_attachment_join.attachment_id = attachment.rowid
            WHERE message_attachment_join.message_id = ?
            ORDER BY attachment.rowid ASC
            """,
            arguments: [messageRowID]
        )

        return rows.compactMap { row in
            guard let uti: String = row["uti"] else { return nil }
            let guid: String = row["attachment_guid"] ?? "\(row["attachment_rowid"] ?? 0)"
            let filename: String = row["filename"] ?? ""
            let resolvedURL = Self.resolveAttachmentPath(filename: filename)
            var sha256: String?
            if let url = resolvedURL, let data = try? Data(contentsOf: url) {
                sha256 = Hashing.sha256Hex(data: data)
            }
            return IMessagesAttachment(
                id: guid,
                uti: uti,
                originalPath: filename,
                resolvedURL: resolvedURL,
                sha256: sha256,
                isImage: uti.starts(with: "public.image"),
                ocrStatus: nil,
                error: nil
            )
        }
    }

    private static func resolveAttachmentPath(filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        let attachmentsRoot = ProcessInfo.processInfo.environment["IMESSAGE_ATTACHMENTS_ROOT"] ?? NSString(string: "~/Library/Messages/Attachments").expandingTildeInPath
        let expanded: String
        if filename.hasPrefix("~/") {
            expanded = NSString(string: filename).expandingTildeInPath
        } else if filename.hasPrefix("/") {
            expanded = filename
        } else {
            expanded = (attachmentsRoot as NSString).appendingPathComponent(filename)
        }
        let url = URL(fileURLWithPath: expanded)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func decodeAttributedBody(_ data: Data) -> String? {
        do {
            let attributed = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
            return attributed?.string
        } catch {
            return nil
        }
    }

    private static func dateFromAppleEpoch(_ value: Int64) -> Date {
        // Dates stored as seconds since 2001-01-01; convert to Unix epoch
        let seconds = Double(value) / 1_000_000_000.0
        let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
        return referenceDate.addingTimeInterval(seconds)
    }
}
