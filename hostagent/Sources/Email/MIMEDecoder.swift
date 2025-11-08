import Foundation

/// MIME content decoder for handling various transfer encodings with proper charset support
public struct MIMEDecoder {
    
    /// Decode content based on transfer encoding and charset
    /// - Parameters:
    ///   - content: The encoded content string
    ///   - encoding: The transfer encoding type (e.g., "base64", "quoted-printable", "7bit", "8bit")
    ///   - charset: The character encoding (e.g., "utf-8", "iso-8859-1", "windows-1252"). Defaults to "utf-8"
    /// - Returns: Decoded content string
    public static func decodeContent(_ content: String, encoding: String?, charset: String? = nil) -> String {
        guard let encoding = encoding?.lowercased() else {
            return content
        }
        
        let charsetToUse = charset?.lowercased() ?? "utf-8"
        
        switch encoding {
        case "base64":
            return decodeBase64(content, charset: charsetToUse)
        case "quoted-printable":
            return decodeQuotedPrintable(content, charset: charsetToUse)
        case "7bit", "8bit", "binary":
            // These are already in their final form
            return content
        default:
            // Unknown encoding, return as-is
            return content
        }
    }
    
    /// Decode base64 encoded content with proper charset handling
    public static func decodeBase64(_ content: String, charset: String = "utf-8") -> String {
        // Remove whitespace and newlines
        let cleaned = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        
        guard let data = Data(base64Encoded: cleaned) else {
            return content
        }
        
        // Try to decode with the specified charset
        if let result = decodeDataWithCharset(data, charset: charset) {
            return result
        }
        
        // Fallback to UTF-8
        if let result = String(data: data, encoding: .utf8) {
            return result
        }
        
        // Last resort: return original content
        return content
    }
    
    /// Decode quoted-printable encoded content with proper charset handling
    public static func decodeQuotedPrintable(_ content: String, charset: String = "utf-8") -> String {
        var decodedBytes: [UInt8] = []
        var i = content.startIndex
        
        while i < content.endIndex {
            if content[i] == "=" {
                // Check if this is a soft line break (= followed by CRLF or LF)
                if content.distance(from: i, to: content.endIndex) >= 2 {
                    let nextIndex = content.index(after: i)
                    let nextChar = content[nextIndex]
                    
                    // Handle different line ending scenarios
                    if nextChar.unicodeScalars.first?.value == 13 { // \r
                        // Check for CRLF
                        if content.distance(from: nextIndex, to: content.endIndex) >= 2 {
                            let afterNext = content.index(after: nextIndex)
                            if content[afterNext].unicodeScalars.first?.value == 10 { // \n
                                // CRLF soft line break - skip the entire sequence
                                i = content.index(after: afterNext)
                                continue
                            }
                        }
                        // CR without LF - skip the CR
                        i = content.index(after: nextIndex)
                        continue
                    } else if nextChar.unicodeScalars.first?.value == 10 { // \n
                        // LF soft line break - skip the LF
                        i = content.index(after: nextIndex)
                        continue
                    }
                }
                
                // Decode hex sequence (=XX)
                if content.distance(from: i, to: content.endIndex) >= 3 {
                    let hexStart = content.index(after: i)
                    let hexEnd = content.index(hexStart, offsetBy: 2)
                    
                    // Make sure hexEnd is within bounds
                    if hexEnd <= content.endIndex {
                        let hexString = String(content[hexStart..<hexEnd])
                        
                        if let byte = UInt8(hexString, radix: 16) {
                            decodedBytes.append(byte)
                            i = hexEnd
                            continue
                        }
                    }
                }
                
                // If we get here, it's an invalid hex sequence, treat as literal
                if let asciiValue = content[i].asciiValue {
                    decodedBytes.append(asciiValue)
                }
                i = content.index(after: i)
                continue
            }
            
            // Regular character - append as ASCII/UTF-8 byte
            if let asciiValue = content[i].asciiValue {
                decodedBytes.append(asciiValue)
            } else {
                // Non-ASCII character in the quoted-printable string itself
                // Encode it as UTF-8 bytes
                for byte in content[i].utf8 {
                    decodedBytes.append(byte)
                }
            }
            i = content.index(after: i)
        }
        
        // Convert decoded bytes to string using the specified charset
        let data = Data(decodedBytes)
        if let result = decodeDataWithCharset(data, charset: charset) {
            return result
        }
        
        // Fallback to UTF-8
        if let result = String(data: data, encoding: .utf8) {
            return result
        }
        
        // Last resort: return original content
        return content
    }
    
    /// Helper function to decode Data with a specified charset
    private static func decodeDataWithCharset(_ data: Data, charset: String) -> String? {
        let charsetLower = charset.lowercased()
        
        // Map common charset names to String.Encoding
        switch charsetLower {
        case "utf-8", "utf8", "utf_8":
            return String(data: data, encoding: .utf8)
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            return String(data: data, encoding: .isoLatin1)
        case "iso-8859-2", "iso8859-2", "latin2", "latin-2":
            // Not directly supported by String.Encoding, fall through
            return nil
        case "windows-1252", "cp1252":
            // Use ASCII as approximation (limited support)
            return String(data: data, encoding: .ascii)
        case "us-ascii", "ascii":
            return String(data: data, encoding: .ascii)
        case "utf-16", "utf16":
            return String(data: data, encoding: .utf16)
        case "utf-16be", "utf16be":
            return String(data: data, encoding: .utf16BigEndian)
        case "utf-16le", "utf16le":
            return String(data: data, encoding: .utf16LittleEndian)
        default:
            // Try UTF-8 as default for unknown charsets
            return String(data: data, encoding: .utf8)
        }
    }
    
    /// Extract transfer encoding from Content-Type header
    /// - Parameter contentType: The Content-Type header value
    /// - Returns: The transfer encoding value, or nil if not found
    public static func extractTransferEncoding(from contentType: String) -> String? {
        return extractParameter(from: contentType, parameter: "encoding")
    }
    
    /// Extract charset from Content-Type header
    /// - Parameter contentType: The Content-Type header value
    /// - Returns: The charset value, or nil if not found
    public static func extractCharset(from contentType: String) -> String? {
        return extractParameter(from: contentType, parameter: "charset")
    }
    
    /// Extract a parameter value from Content-Type header
    /// - Parameters:
    ///   - contentType: The Content-Type header value
    ///   - parameter: The parameter name to extract
    /// - Returns: The parameter value, or nil if not found
    private static func extractParameter(from contentType: String, parameter: String) -> String? {
        let components = contentType.components(separatedBy: ";")
        
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(parameter.lowercased() + "=") {
                let value = String(trimmed.dropFirst(parameter.count + 1))
                // Remove quotes if present
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    return String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        
        return nil
    }
    
    /// Decode RFC 2047 encoded-word format used in email headers (Subject, From, etc.)
    /// Format: =?charset?encoding?encoded-text?=
    /// - Parameter header: The header value that may contain RFC 2047 encoded words
    /// - Returns: Decoded header string
    public static func decodeHeader(_ header: String) -> String {
        // Pattern to match RFC 2047 encoded words: =?charset?encoding?text?=
        let pattern = #"=\?([^?]+)\?([QqBb])\?([^?]+)\?="#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return header
        }
        
        let nsString = header as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var result = header
        
        // Process matches in reverse order to avoid index shifting
        let matches = regex.matches(in: header, options: [], range: range).reversed()
        
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            
            let charsetRange = match.range(at: 1)
            let encodingRange = match.range(at: 2)
            let textRange = match.range(at: 3)
            
            guard charsetRange.location != NSNotFound,
                  encodingRange.location != NSNotFound,
                  textRange.location != NSNotFound else { continue }
            
            let charset = nsString.substring(with: charsetRange).lowercased()
            let encoding = nsString.substring(with: encodingRange).uppercased()
            let encodedText = nsString.substring(with: textRange)
            
            var decodedText: String?
            
            if encoding == "Q" {
                // Quoted-printable encoding
                // In RFC 2047 Q encoding, underscores represent spaces
                let withSpaces = encodedText.replacingOccurrences(of: "_", with: " ")
                decodedText = decodeQuotedPrintable(withSpaces, charset: charset)
            } else if encoding == "B" {
                // Base64 encoding
                decodedText = decodeBase64(encodedText, charset: charset)
            }
            
            if let decoded = decodedText {
                // Replace the encoded word with decoded text
                result = (result as NSString).replacingCharacters(in: match.range, with: decoded)
            }
        }
        
        // Clean up any remaining whitespace issues
        return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
