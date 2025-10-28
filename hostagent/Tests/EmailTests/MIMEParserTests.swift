import XCTest
@testable import Email
@testable import HavenCore

final class MIMEParserTests: XCTestCase {
    
    func testParseSimpleMessage() {
        let content = """
Subject: Test Email
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Hello=20World
"""
        
        let message = MIMEParser.parseMIMEMessage(content)
        
        XCTAssertEqual(message.headers["subject"], "Test Email")
        XCTAssertEqual(message.headers["content-type"], "text/plain; charset=utf-8")
        XCTAssertEqual(message.headers["content-transfer-encoding"], "quoted-printable")
        
        XCTAssertEqual(message.parts.count, 1)
        XCTAssertEqual(message.parts[0].contentType, "text/plain")
        XCTAssertEqual(message.parts[0].content, "Hello World")
        
        XCTAssertEqual(message.plainTextContent, "Hello World")
        XCTAssertNil(message.htmlContent)
    }
    
    func testParseMultipartMessage() {
        let content = """
Subject: Multipart Test
Content-Type: multipart/alternative; boundary="boundary123"

--boundary123
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Hello=20World

--boundary123
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: quoted-printable

<html><body>Hello=20World</body></html>

--boundary123--
"""
        
        let message = MIMEParser.parseMIMEMessage(content)
        
        XCTAssertEqual(message.headers["subject"], "Multipart Test")
        XCTAssertEqual(message.parts.count, 2)
        
        // First part should be plain text
        XCTAssertEqual(message.parts[0].contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(message.parts[0].content, "Hello World")
        
        // Second part should be HTML
        XCTAssertEqual(message.parts[1].contentType, "text/html; charset=utf-8")
        XCTAssertEqual(message.parts[1].content, "<html><body>Hello World</body></html>")
        
        // Best text content should prefer plain text
        XCTAssertEqual(message.plainTextContent, "Hello World")
        XCTAssertEqual(message.htmlContent, "<html><body>Hello World</body></html>")
    }
    
    func testParseMultipartWithBase64() {
        let content = """
Subject: Base64 Test
Content-Type: multipart/mixed; boundary="boundary123"

--boundary123
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: base64

SGVsbG8gV29ybGQ=

--boundary123--
"""
        
        let message = MIMEParser.parseMIMEMessage(content)
        
        XCTAssertEqual(message.parts.count, 1)
        XCTAssertEqual(message.parts[0].contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(message.parts[0].content, "Hello World")
        XCTAssertEqual(message.plainTextContent, "Hello World")
    }
    
    func testParseMessageWithQuotedBoundary() {
        let content = """
Subject: Quoted Boundary Test
Content-Type: multipart/alternative; boundary="boundary-123"

--boundary-123
Content-Type: text/plain

Hello World

--boundary-123--
"""
        
        let message = MIMEParser.parseMIMEMessage(content)
        
        XCTAssertEqual(message.parts.count, 1)
        XCTAssertEqual(message.parts[0].contentType, "text/plain")
        XCTAssertEqual(message.parts[0].content, "Hello World")
    }
    
    func testParseMessageWithUnquotedBoundary() {
        let content = """
Subject: Unquoted Boundary Test
Content-Type: multipart/alternative; boundary=boundary123

--boundary123
Content-Type: text/plain

Hello World

--boundary123--
"""
        
        let message = MIMEParser.parseMIMEMessage(content)
        
        XCTAssertEqual(message.parts.count, 1)
        XCTAssertEqual(message.parts[0].contentType, "text/plain")
        XCTAssertEqual(message.parts[0].content, "Hello World")
    }
    
    func testParseMessageFallbackToOriginalBody() {
        let content = """
Subject: Simple Test
Content-Type: text/plain

Hello World
"""
        
        let message = MIMEParser.parseMIMEMessage(content)
        
        // Should fall back to treating as single part
        XCTAssertEqual(message.parts.count, 1)
        XCTAssertEqual(message.parts[0].contentType, "text/plain")
        XCTAssertEqual(message.parts[0].content, "Hello World")
    }
}
