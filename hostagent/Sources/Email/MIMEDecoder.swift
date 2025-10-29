import Foundation

/// MIME content decoder for handling various transfer encodings
public struct MIMEDecoder {
    
    /// Decode content based on transfer encoding
    /// - Parameters:
    ///   - content: The encoded content string
    ///   - encoding: The transfer encoding type (e.g., "base64", "quoted-printable", "7bit", "8bit")
    /// - Returns: Decoded content string
    public static func decodeContent(_ content: String, encoding: String?) -> String {
        guard let encoding = encoding?.lowercased() else {
            return content
        }
        
        switch encoding {
        case "base64":
            return decodeBase64(content)
        case "quoted-printable":
            return decodeQuotedPrintable(content)
        case "7bit", "8bit", "binary":
            // These are already in their final form
            return content
        default:
            // Unknown encoding, return as-is
            return content
        }
    }
    
    /// Decode base64 encoded content
    public static func decodeBase64(_ content: String) -> String {
        // Remove whitespace and newlines
        let cleaned = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        
        guard let data = Data(base64Encoded: cleaned) else {
            return content
        }
        
        return String(data: data, encoding: .utf8) ?? content
    }
    
    /// Decode quoted-printable encoded content
    public static func decodeQuotedPrintable(_ content: String) -> String {
        var result = ""
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
                            let scalar = UnicodeScalar(byte)
                            result += String(Character(scalar))
                            i = hexEnd
                            continue
                        }
                    }
                }
                
                // If we get here, it's an invalid hex sequence, treat as literal
                result += String(content[i])
                i = content.index(after: i)
                continue
            }
            
            result += String(content[i])
            i = content.index(after: i)
        }
        
        return result
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
}
