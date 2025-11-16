//
//  IMessageInstanceConfig.swift
//  Haven
//
//  iMessage collector configuration
//  Persisted in ~/.haven/imessage.plist
//

import Foundation

/// iMessage collector configuration (single instance, system-level)
public struct IMessageInstanceConfig: Codable, Equatable, @unchecked Sendable {
    public var ocrEnabled: Bool
    public var chatDbPath: String  // Empty string uses system default
    public var attachmentsPath: String  // Empty string uses system default
    public var ingestNonImageAttachments: Bool
    public var fswatchEnabled: Bool
    public var fswatchDelaySeconds: Int
    
    enum CodingKeys: String, CodingKey {
        case ocrEnabled = "ocr_enabled"
        case chatDbPath = "chat_db_path"
        case attachmentsPath = "attachments_path"
        case ingestNonImageAttachments = "ingest_non_image_attachments"
        case fswatchEnabled = "fswatch_enabled"
        case fswatchDelaySeconds = "fswatch_delay_seconds"
    }
    
    public init(
        ocrEnabled: Bool = true,
        chatDbPath: String = "",
        attachmentsPath: String = "",
        ingestNonImageAttachments: Bool = false,
        fswatchEnabled: Bool = false,
        fswatchDelaySeconds: Int = 60
    ) {
        self.ocrEnabled = ocrEnabled
        self.chatDbPath = chatDbPath
        self.attachmentsPath = attachmentsPath
        self.ingestNonImageAttachments = ingestNonImageAttachments
        self.fswatchEnabled = fswatchEnabled
        self.fswatchDelaySeconds = fswatchDelaySeconds
    }
}

