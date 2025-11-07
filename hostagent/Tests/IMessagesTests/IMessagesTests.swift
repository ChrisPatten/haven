import XCTest
import Foundation
@testable import CollectorHandlers

final class IMessagesTests: XCTestCase {
    
    func testDebugAttributedBodyDecoding() throws {
        // Test with real fixture data to verify streamtyped decoding works
        let data = try loadFixtureDataFromFileSystem(name: "simple_message")
        let result = IMessageHandler.testDecodeAttributedBodyStatic(data)
        
        // Should extract the expected text from the fixture
        XCTAssertNotNil(result, "Should extract some text")
        XCTAssertEqual(result, "Always a patriot", "Should extract the correct text from fixture")
    }
    
    func testAttributedBodyDecodingWithSimpleData() throws {
        // Test with simple plist data created in code
        let testCases = [
            ("Hello, world!", "Simple text message"),
            ("What's your flight??", "Message with question marks"),
            ("Lord Beckett is definitely the account", "Group message")
        ]
        
        for (text, description) in testCases {
            let plistData = createTestPlistData(text: text)
            let result = IMessageHandler.testDecodeAttributedBodyStatic(plistData)
            
            XCTAssertNotNil(result, "Failed to decode attributed body for \(description)")
            XCTAssertEqual(result, text, "Decoded text doesn't match expected for \(description)")
        }
    }
    
    func testEmptyAttributedBody() throws {
        // Test with empty data
        let result = IMessageHandler.testDecodeAttributedBodyStatic(Data())
        
        XCTAssertNil(result, "Empty data should return nil")
    }
    
    func testInvalidAttributedBody() throws {
        // Test with invalid data
        let invalidData = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let result = IMessageHandler.testDecodeAttributedBodyStatic(invalidData)
        
        // Should handle gracefully and return nil
        XCTAssertNil(result, "Invalid data should return nil")
    }
    
    func testAttributedBodyDecodingPerformance() throws {
        // Test performance with simple data
        let data = createTestPlistData(text: "Performance test message")
        
        measure {
            for _ in 0..<100 {
                _ = IMessageHandler.testDecodeAttributedBodyStatic(data)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestPlistData(text: String) -> Data {
        let plist: [String: Any] = [
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": ["UID": 1]],
            "$objects": [
                "$null",
                ["NS.string": ["UID": 2]],
                text
            ]
        ]
        
        do {
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        } catch {
            XCTFail("Failed to create test plist data: \(error)")
            return Data()
        }
    }
    
    private func loadFixtureDataFromFileSystem(name: String) throws -> Data {
        let fixturePath = "/Users/chrispatten/workspace/haven/hostagent/Tests/IMessagesTests/Fixtures/\(name).bin"
        let url = URL(fileURLWithPath: fixturePath)
        
        guard FileManager.default.fileExists(atPath: fixturePath) else {
            throw TestError.fixtureNotFound(name)
        }
        
        return try Data(contentsOf: url)
    }
}

// MARK: - Test Errors

enum TestError: Error {
    case fixtureNotFound(String)
    
    var localizedDescription: String {
        switch self {
        case .fixtureNotFound(let name):
            return "Fixture not found: \(name)"
        }
    }
}