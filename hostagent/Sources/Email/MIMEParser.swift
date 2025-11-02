import Foundation

/// MIME message parser for handling multipart and encoded email content
public struct MIMEParser {
    
    /// Parse a MIME message and extract text content
    /// - Parameter content: The raw MIME content
    /// - Returns: Parsed MIME parts with decoded content
    public static func parseMIMEMessage(_ content: String) -> MIMEMessage {
        let lines = content.components(separatedBy: .newlines)
        var message = MIMEMessage()
        
        // Find the boundary between headers and body
        var headerEndIndex = 0
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headerEndIndex = index
                break
            }
        }
        
        // Parse headers
        let headerLines = headerEndIndex > 0 ? Array(lines[0..<headerEndIndex]) : []
        let headers = parseHeaders(headerLines)
        message.headers = headers
        
        // Parse body
        let bodyLines = headerEndIndex < lines.count ? Array(lines[headerEndIndex..<lines.count]) : []
        let bodyContent = bodyLines.joined(separator: "\n")
        
        // Check if this is a multipart message
        if let contentType = headers["content-type"], contentType.lowercased().contains("multipart") {
            message.parts = parseMultipartBody(bodyContent, contentType: contentType)
        } else {
            // Single part message
            let encoding = headers["content-transfer-encoding"]
            let contentType = headers["content-type"] ?? "text/plain"
            let charset = MIMEDecoder.extractCharset(from: contentType)
            let decodedContent = MIMEDecoder.decodeContent(bodyContent, encoding: encoding, charset: charset).trimmingCharacters(in: .whitespacesAndNewlines)
            let baseContentType = extractBaseContentType(from: contentType)
            message.parts = [MIMEPart(content: decodedContent, contentType: baseContentType)]
        }
        
        return message
    }
    
    /// Parse email headers from header lines
    private static func parseHeaders(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        var currentHeader: String?
        var currentValue = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.isEmpty {
                continue
            }
            
            // Check if this is a continuation line (starts with whitespace)
            if line.first?.isWhitespace == true {
                if currentHeader != nil {
                    currentValue += " " + trimmed
                }
            } else if line.contains(":") {
                // Save previous header
                if let header = currentHeader {
                    headers[header.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // New header
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    currentHeader = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    currentValue = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        // Save last header
        if let header = currentHeader {
            headers[header.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return headers
    }
    
    /// Parse multipart body content
    private static func parseMultipartBody(_ body: String, contentType: String) -> [MIMEPart] {
        // Extract boundary from Content-Type header
        guard let boundary = extractBoundary(from: contentType) else {
            return []
        }
        
        let boundaryMarker = "--\(boundary)"
        let parts = body.components(separatedBy: boundaryMarker)
        var mimeParts: [MIMEPart] = []
        
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" {
                continue
            }
            
            // Split part into headers and content
            let partLines = trimmed.components(separatedBy: .newlines)
            var partHeaderEndIndex = 0
            
            for (index, line) in partLines.enumerated() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    partHeaderEndIndex = index
                    break
                }
            }
            
            let partHeaders = partHeaderEndIndex > 0 ? parseHeaders(Array(partLines[0..<partHeaderEndIndex])) : [:]
            let partContent = partHeaderEndIndex < partLines.count ? Array(partLines[partHeaderEndIndex..<partLines.count]).joined(separator: "\n") : ""
            
            // Decode content based on transfer encoding and charset
            let encoding = partHeaders["content-transfer-encoding"]
            let contentType = partHeaders["content-type"] ?? "text/plain"
            let charset = MIMEDecoder.extractCharset(from: contentType)
            let decodedContent = MIMEDecoder.decodeContent(partContent, encoding: encoding, charset: charset).trimmingCharacters(in: .whitespacesAndNewlines)
            
            let mimePart = MIMEPart(
                content: decodedContent,
                contentType: contentType,
                headers: partHeaders
            )
            
            mimeParts.append(mimePart)
        }
        
        return mimeParts
    }
    
    /// Extract boundary parameter from Content-Type header
    private static func extractBoundary(from contentType: String) -> String? {
        let pattern = #"boundary\s*=\s*"([^"]+)"|boundary\s*=\s*([^;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        
        let nsString = contentType as NSString
        let matches = regex.matches(in: contentType, range: NSRange(location: 0, length: nsString.length))
        
        if let match = matches.first {
            // Check both capture groups
            for i in 1...2 {
                if match.numberOfRanges > i {
                    let range = match.range(at: i)
                    if range.location != NSNotFound {
                        let boundary = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !boundary.isEmpty {
                            return boundary
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Extract base content type without parameters
    private static func extractBaseContentType(from contentType: String) -> String {
        // Split by semicolon and take only the first part
        let components = contentType.components(separatedBy: ";")
        return components[0].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Represents a parsed MIME message
public struct MIMEMessage {
    public var headers: [String: String] = [:]
    public var parts: [MIMEPart] = []
    
    public init() {}
    
    /// Get the best text content from the message
    public var bestTextContent: String? {
        // Prefer plain text over HTML
        for part in parts {
            if part.contentType.lowercased().contains("text/plain") {
                return part.content
            }
        }
        
        for part in parts {
            if part.contentType.lowercased().contains("text/html") {
                return part.content
            }
        }
        
        // Fall back to first text part
        for part in parts {
            if part.contentType.lowercased().contains("text/") {
                return part.content
            }
        }
        
        return nil
    }
    
    /// Get HTML content if available
    public var htmlContent: String? {
        for part in parts {
            if part.contentType.lowercased().contains("text/html") {
                return part.content
            }
        }
        return nil
    }
    
    /// Get plain text content if available
    public var plainTextContent: String? {
        for part in parts {
            if part.contentType.lowercased().contains("text/plain") {
                return part.content
            }
        }
        return nil
    }
}

/// Represents a MIME part
public struct MIMEPart {
    public var content: String
    public var contentType: String
    public var headers: [String: String]
    
    public init(content: String, contentType: String, headers: [String: String] = [:]) {
        self.content = content
        self.contentType = contentType
        self.headers = headers
    }
}
