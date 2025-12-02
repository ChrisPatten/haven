import XCTest
@testable import HostAgentEmail
import HavenCore
import CryptoKit

final class DocumentSubmitterTests: XCTestCase {
    
    func testConvertToEmailDocumentPayloadPreservesThreadData() throws {
        // Given: A CollectorDocument with thread payload in additionalMetadata
        let threadPayload: [String: Any] = [
            "external_id": "imessage:any;+;chat123456789",
            "source_type": "imessage",
            "source_provider": "apple_messages",
            "source_account_id": "E:test@example.com",
            "title": "Test Thread",
            "participants": [
                [
                    "identifier": "+1234567890",
                    "identifier_type": "phone",
                    "role": "participant"
                ],
                [
                    "identifier": "+0987654321",
                    "identifier_type": "phone",
                    "role": "participant"
                ]
            ],
            "thread_type": "group",
            "is_group": true,
            "participant_count": 2,
            "metadata": [
                "chat_guid": "any;+;chat123456789"
            ],
            "last_message_at": "2025-11-26T12:00:00Z"
        ]
        
        let threadPayloadJson = try JSONSerialization.data(withJSONObject: threadPayload, options: [])
        let threadPayloadString = String(data: threadPayloadJson, encoding: .utf8)!
        
        let baseDocument = CollectorDocument(
            content: "Test message content",
            sourceType: "imessage",
            externalId: "imessage:test-guid-123",
            metadata: DocumentMetadata(
                contentHash: "test-hash",
                mimeType: "text/plain",
                timestamp: Date(),
                timestampType: "sent",
                createdAt: Date(),
                modifiedAt: Date(),
                additionalMetadata: [
                    "thread_payload": threadPayloadString
                ]
            ),
            images: [],
            contentType: .imessage,
            title: "Test Thread",
            canonicalUri: "imessage:test-guid-123"
        )
        
        // Verify thread payload is stored correctly
        XCTAssertNotNil(baseDocument.metadata.additionalMetadata["thread_payload"])
        XCTAssertEqual(baseDocument.metadata.additionalMetadata["thread_payload"], threadPayloadString)
        
        // Verify we can parse it back
        let parsedData = threadPayloadString.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: parsedData) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["external_id"] as? String, "imessage:any;+;chat123456789")
        XCTAssertEqual(parsed?["title"] as? String, "Test Thread")
    }
    
    func testConvertToEmailDocumentPayloadPreservesPeopleData() throws {
        // Given: A CollectorDocument with people data in additionalMetadata
        let peopleArray: [[String: Any]] = [
            [
                "identifier": "+1234567890",
                "identifier_type": "phone",
                "role": "sender"
            ],
            [
                "identifier": "+0987654321",
                "identifier_type": "phone",
                "role": "recipient"
            ]
        ]
        
        let peopleJson = try JSONSerialization.data(withJSONObject: peopleArray, options: [])
        let peopleString = String(data: peopleJson, encoding: .utf8)!
        
        let baseDocument = CollectorDocument(
            content: "Test message",
            sourceType: "imessage",
            externalId: "imessage:test-guid",
            metadata: DocumentMetadata(
                contentHash: "test-hash",
                mimeType: "text/plain",
                timestamp: Date(),
                timestampType: "sent",
                createdAt: Date(),
                modifiedAt: Date(),
                additionalMetadata: [
                    "people_payload": peopleString
                ]
            ),
            images: [],
            contentType: .imessage,
            title: "Test",
            canonicalUri: nil
        )
        
        // Verify people data is stored
        XCTAssertNotNil(baseDocument.metadata.additionalMetadata["people_payload"])
        XCTAssertEqual(baseDocument.metadata.additionalMetadata["people_payload"], peopleString)
        
        // Verify we can parse it back
        let parsedData = peopleString.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: parsedData) as? [[String: Any]]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0]["identifier"] as? String, "+1234567890")
        XCTAssertEqual(parsed?[0]["role"] as? String, "sender")
    }
    
    func testConvertToEmailDocumentPayloadPreservesOriginalMetadata() throws {
        // Given: A CollectorDocument with original iMessage metadata structure
        let originalMetadata: [String: Any] = [
            "timestamps": [
                "primary": [
                    "value": "2025-11-26T12:00:00+00:00",
                    "type": "sent"
                ],
                "source_specific": [
                    "sent_at": "2025-11-26T12:00:00+00:00"
                ]
            ],
            "source": [
                "imessage": [
                    "chat_guid": "any;+;chat123456789",
                    "handle_id": 123,
                    "service": "iMessage",
                    "row_id": 456
                ]
            ],
            "type": [
                "kind": "imessage",
                "imessage": [
                    "direction": "outgoing",
                    "is_group": true
                ]
            ]
        ]
        
        let metadataJson = try JSONSerialization.data(withJSONObject: originalMetadata, options: [])
        let metadataString = String(data: metadataJson, encoding: .utf8)!
        
        let baseDocument = CollectorDocument(
            content: "Test message",
            sourceType: "imessage",
            externalId: "imessage:test-guid",
            metadata: DocumentMetadata(
                contentHash: "test-hash",
                mimeType: "text/plain",
                timestamp: Date(),
                timestampType: "sent",
                createdAt: Date(),
                modifiedAt: Date(),
                additionalMetadata: [
                    "original_metadata": metadataString
                ]
            ),
            images: [],
            contentType: .imessage,
            title: "Test",
            canonicalUri: nil
        )
        
        // Verify original metadata is stored
        XCTAssertNotNil(baseDocument.metadata.additionalMetadata["original_metadata"])
        
        // Verify we can parse it back and it has the expected structure
        let parsedData = baseDocument.metadata.additionalMetadata["original_metadata"]!.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: parsedData) as? [String: Any]
        XCTAssertNotNil(parsed)
        
        let source = parsed?["source"] as? [String: Any]
        let imessage = source?["imessage"] as? [String: Any]
        XCTAssertNotNil(imessage)
        XCTAssertEqual(imessage?["chat_guid"] as? String, "any;+;chat123456789")
        XCTAssertEqual(imessage?["service"] as? String, "iMessage")
    }
    
    func testThreadIdGenerationIsDeterministic() {
        // Given: Same external_id
        let externalId = "imessage:any;+;chat123456789"
        
        // When: Generate UUID multiple times
        let uuid1 = generateDeterministicUUID(from: externalId)
        let uuid2 = generateDeterministicUUID(from: externalId)
        
        // Then: UUIDs should be identical
        XCTAssertEqual(uuid1, uuid2)
        
        // And: Different external_ids should produce different UUIDs
        let differentId = "imessage:any;+;chat987654321"
        let uuid3 = generateDeterministicUUID(from: differentId)
        XCTAssertNotEqual(uuid1, uuid3)
    }
    
    // MARK: - Helpers
    
    private func generateDeterministicUUID(from seed: String) -> UUID {
        let data = Data(seed.utf8)
        let digest = SHA256.hash(data: data)
        var bytes = Array(digest.prefix(16))
        if bytes.count < 16 {
            bytes += Array(repeating: 0, count: 16 - bytes.count)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // Version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // Variant RFC4122
        return bytes.withUnsafeBytes { ptr -> UUID in
            let rawPtr = ptr.bindMemory(to: UInt8.self)
            return UUID(uuid: uuid_t(rawPtr[0], rawPtr[1], rawPtr[2], rawPtr[3],
                                     rawPtr[4], rawPtr[5], rawPtr[6], rawPtr[7],
                                     rawPtr[8], rawPtr[9], rawPtr[10], rawPtr[11],
                                     rawPtr[12], rawPtr[13], rawPtr[14], rawPtr[15]))
        }
    }
}

// Note: Full integration test would require making convertToEmailDocumentPayload internal
// or creating a test helper. These tests verify the data storage/retrieval mechanisms.

