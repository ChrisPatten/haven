import Foundation

struct IMessagesEvent: Codable, Sendable {
    struct EventChunk: Codable, Sendable {
        let chunkID: String
        let type: String
        let text: String
        let meta: [String: String]?

        enum CodingKeys: String, CodingKey {
            case chunkID = "chunk_id"
            case type
            case text
            case meta
        }
    }

    struct MessageMetadata: Codable, Sendable {
        struct Thread: Codable, Sendable {
            let chatGUID: String
            let participants: [String]
            let service: String

            enum CodingKeys: String, CodingKey {
                case chatGUID = "chat_guid"
                case participants
                case service
            }
        }

        struct Handle: Codable, Sendable {
            let id: String
            let phone: String?
            let email: String?
        }

        struct Attachment: Codable, Sendable {
            let id: String
            let uti: String
            let path: String
            let sha256: String?
            let status: String
            var ocrStatus: String?
            var error: String?

            enum CodingKeys: String, CodingKey {
                case id
                case uti
                case path
                case sha256
                case status
                case ocrStatus = "ocr_status"
                case error
            }
        }

        struct Message: Codable, Sendable {
            let rowid: Int64
            let date: String
            let isFromMe: Bool
            let handle: Handle
            let attachments: [Attachment]

            enum CodingKeys: String, CodingKey {
                case rowid
                case date
                case isFromMe = "is_from_me"
                case handle
                case attachments
            }
        }

        let thread: Thread
        let message: Message
    }

    let sourceType: String
    let sourceID: String
    let content: String
    let chunks: [EventChunk]
    let metadata: MessageMetadata

    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case sourceID = "source_id"
        case content
        case chunks
        case metadata
    }
}
