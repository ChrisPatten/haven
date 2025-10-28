import XCTest
@testable import Email
@testable import HavenCore

final class MIMEDecoderTests: XCTestCase {
    
    func testDecodeQuotedPrintable() {
        // Test basic quoted-printable decoding
        let input = "Hello=20World=3D"
        let expected = "Hello World="
        let result = MIMEDecoder.decodeQuotedPrintable(input)
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeQuotedPrintableSoftLineBreak() {
        // Test soft line break (= at end of line)
        let input = "Line 1=\nLine 2"
        let expected = "Line 1Line 2"
        let result = MIMEDecoder.decodeQuotedPrintable(input)
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeQuotedPrintableWithCarriageReturn() {
        // Test soft line break with carriage return
        let crlf = "\r\n"
        let input = "Line 1=" + crlf + "Line 2"
        let expected = "Line 1Line 2"
        let result = MIMEDecoder.decodeQuotedPrintable(input)
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeQuotedPrintableInvalidHex() {
        // Test invalid hex sequence (should be treated as literal)
        let input = "Hello=ZZWorld"
        let expected = "Hello=ZZWorld"
        let result = MIMEDecoder.decodeQuotedPrintable(input)
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeBase64() {
        // Test base64 decoding
        let input = "SGVsbG8gV29ybGQ=" // "Hello World" in base64
        let expected = "Hello World"
        let result = MIMEDecoder.decodeBase64(input)
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeBase64WithWhitespace() {
        // Test base64 decoding with whitespace
        let input = "SGVsbG8gV29ybGQ=\n"
        let expected = "Hello World"
        let result = MIMEDecoder.decodeBase64(input)
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeContentQuotedPrintable() {
        // Test content decoding with quoted-printable encoding
        let input = "Hello=20World"
        let expected = "Hello World"
        let result = MIMEDecoder.decodeContent(input, encoding: "quoted-printable")
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeContentBase64() {
        // Test content decoding with base64 encoding
        let input = "SGVsbG8gV29ybGQ="
        let expected = "Hello World"
        let result = MIMEDecoder.decodeContent(input, encoding: "base64")
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeContent7bit() {
        // Test content decoding with 7bit encoding (no change)
        let input = "Hello World"
        let result = MIMEDecoder.decodeContent(input, encoding: "7bit")
        XCTAssertEqual(result, input)
    }
    
    func testDecodeContentUnknownEncoding() {
        // Test content decoding with unknown encoding (no change)
        let input = "Hello World"
        let result = MIMEDecoder.decodeContent(input, encoding: "unknown")
        XCTAssertEqual(result, input)
    }
    
    func testExtractTransferEncoding() {
        // Test extracting transfer encoding from Content-Type header
        let contentType = "text/plain; charset=utf-8; encoding=quoted-printable"
        let result = MIMEDecoder.extractTransferEncoding(from: contentType)
        XCTAssertEqual(result, "quoted-printable")
    }
    
    func testExtractTransferEncodingQuoted() {
        // Test extracting quoted transfer encoding
        let contentType = "text/plain; charset=utf-8; encoding=\"quoted-printable\""
        let result = MIMEDecoder.extractTransferEncoding(from: contentType)
        XCTAssertEqual(result, "quoted-printable")
    }
    
    func testExtractCharset() {
        // Test extracting charset from Content-Type header
        let contentType = "text/plain; charset=utf-8; encoding=quoted-printable"
        let result = MIMEDecoder.extractCharset(from: contentType)
        XCTAssertEqual(result, "utf-8")
    }
    
    func testExtractCharsetQuoted() {
        // Test extracting quoted charset
        let contentType = "text/plain; charset=\"utf-8\"; encoding=quoted-printable"
        let result = MIMEDecoder.extractCharset(from: contentType)
        XCTAssertEqual(result, "utf-8")
    }
}
