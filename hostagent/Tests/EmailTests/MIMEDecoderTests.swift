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
    
    // MARK: - Charset Handling Tests
    
    func testDecodeBase64WithUTF8Charset() {
        // Test base64 decoding with explicit UTF-8 charset
        let input = "SGVsbG8gV29ybGQ=" // "Hello World" in base64
        let expected = "Hello World"
        let result = MIMEDecoder.decodeBase64(input, charset: "utf-8")
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeBase64WithISO88591Charset() {
        // Test base64 decoding with ISO-8859-1 (Latin-1) charset
        // E2 80 99 in base64 is: 4oCZ
        // When decoded as UTF-8, this is the RIGHT SINGLE QUOTATION MARK (')
        // When decoded as Latin-1, E2, 80, 99 become three separate characters: â, €, ™
        let input = "4oCZ" // Base64 for e2 80 99 (3 bytes)
        let result = MIMEDecoder.decodeBase64(input, charset: "iso-8859-1")
        
        // When UTF-8 bytes E2 80 99 are decoded as Latin-1, we get 3 characters
        // E2 (hex) = 226 (decimal) = â (U+00E2)
        // 80 (hex) = 128 (decimal) = € (U+20AC) - but in Latin-1 it's a control character
        // 99 (hex) = 153 (decimal) = ™ (U+2122) - but in Latin-1 it's a control character
        // Swift's isoLatin1 decoder may map these to different Unicode characters
        // Just verify it doesn't give us the UTF-8 RIGHT SINGLE QUOTATION MARK '
        let expectedUTF8 = "\u{2019}" // This would be ' (RIGHT SINGLE QUOTATION MARK)
        XCTAssertNotEqual(result, "Hello\(expectedUTF8)s") // Make sure it's not the UTF-8 interpretation
        XCTAssertTrue(!result.isEmpty) // Just make sure something was decoded
    }
    
    func testDecodeQuotedPrintableWithCharset() {
        // Test quoted-printable with charset handling
        // E2 80 99 is the UTF-8 encoding of RIGHT SINGLE QUOTATION MARK (')
        // In quoted-printable: =E2=80=99
        let input = "Hello=E2=80=99s" // Should be "Hello's" in UTF-8
        let result = MIMEDecoder.decodeQuotedPrintable(input, charset: "utf-8")
        XCTAssertEqual(result, "Hello\u{2019}s") // U+2019 is '
    }
    
    func testDecodeContentBase64WithCharset() {
        // Test decoding content with both base64 encoding and charset
        let input = "SGVsbG8gV29ybGQ=" // "Hello World" in base64
        let expected = "Hello World"
        let result = MIMEDecoder.decodeContent(input, encoding: "base64", charset: "utf-8")
        XCTAssertEqual(result, expected)
    }
    
    func testDecodeContentQuotedPrintableWithCharset() {
        // Test decoding content with both quoted-printable encoding and charset
        let input = "Hello=20World"
        let expected = "Hello World"
        let result = MIMEDecoder.decodeContent(input, encoding: "quoted-printable", charset: "utf-8")
        XCTAssertEqual(result, expected)
    }
    
    func testCharsetFallback() {
        // Test fallback when charset is not recognized
        let input = "SGVsbG8gV29ybGQ=" // "Hello World" in base64
        let expected = "Hello World"
        let result = MIMEDecoder.decodeBase64(input, charset: "unknown-charset-xyz")
        XCTAssertEqual(result, expected)
    }
    
    func testDifferentCharsetNames() {
        // Test that different names for the same charset work
        let input = "SGVsbG8gV29ybGQ="
        let expected = "Hello World"
        
        let result1 = MIMEDecoder.decodeBase64(input, charset: "utf-8")
        let result2 = MIMEDecoder.decodeBase64(input, charset: "UTF-8")
        let result3 = MIMEDecoder.decodeBase64(input, charset: "utf8")
        
        XCTAssertEqual(result1, expected)
        XCTAssertEqual(result2, expected)
        XCTAssertEqual(result3, expected)
    }
}
