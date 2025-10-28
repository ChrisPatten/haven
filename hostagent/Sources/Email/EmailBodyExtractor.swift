import Foundation
import SwiftSoup
import HavenCore

/// Service for extracting clean email body text from raw MIME/HTML content
public struct EmailBodyExtractor {
    private let logger = HavenLogger(category: "email-body-extractor")
    
    public init() {}
    
    /// Extract clean body text from an email message, removing HTML, quoted content, and signatures
    /// - Parameter email: The email message to process
    /// - Returns: Cleaned plain text body
    public func extractCleanBody(from email: EmailMessage) -> String {
        // Start with the best available body content
        let rawBody = selectBestBody(from: email)
        
        // Convert HTML to plain text if needed
        let isHTML = rawBody.contains("<") && rawBody.contains(">") && 
                    (rawBody.contains("<html") || rawBody.contains("<body") || 
                     rawBody.contains("<p>") || rawBody.contains("<div") ||
                     rawBody.contains("<br") || rawBody.contains("<h1") ||
                     rawBody.contains("<ul") || rawBody.contains("<li"))
        let plainText = isHTML ? convertToPlainText(rawBody) : rawBody
        
        // Strip quoted content (both text patterns and HTML blockquotes)
        let withoutQuotes = stripQuotedContent(plainText)
        
        // Remove signatures
        let withoutSignatures = stripSignature(withoutQuotes)
        
        // Final cleanup
        return normalizeText(withoutSignatures)
    }
    
    /// Select the best available body content from the email
    private func selectBestBody(from email: EmailMessage) -> String {
        // Prefer plain text if available and not empty
        if let plainText = email.bodyPlainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainText
        }
        
        // Fall back to HTML if available
        if let html = email.bodyHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return html
        }
        
        // Last resort: raw content
        return email.rawContent ?? ""
    }
    
    /// Convert HTML to plain text using SwiftSoup, preserving formatting
    private func convertToPlainText(_ content: String) -> String {
        // If content doesn't look like HTML, return as-is
        if !content.contains("<") || !content.contains(">") {
            return content
        }
        
        do {
            let doc = try SwiftSoup.parse(content)
            
            // Remove script, style, and blockquote elements
            try doc.select("script, style, blockquote").remove()
            
            // Process images and figures for captions
            try doc.select("img, figure").forEach { element in
                let tagName = element.tagName()
                
                if tagName == "img" {
                    // Extract alt text and title for standalone images
                    let altText = try element.attr("alt")
                    let titleText = try element.attr("title")
                    
                    if !altText.isEmpty || !titleText.isEmpty {
                        let caption: String
                        if !altText.isEmpty && !titleText.isEmpty {
                            caption = "\(altText): \(titleText)"
                        } else {
                            caption = !titleText.isEmpty ? titleText : altText
                        }
                        try element.replaceWith(Element(Tag("p"), "").text("\(caption)"))
                    } else {
                        try element.replaceWith(TextNode("", nil))
                    }
                } else if tagName == "figure" {
                    // Process figure elements (img + figcaption)
                    let img = try element.select("img").first()
                    let figcaption = try element.select("figcaption").first()
                    
                    var captionText = ""
                    
                    // Get alt text or title from img
                    if let img = img {
                        let altText = try img.attr("alt")
                        let titleText = try img.attr("title")
                        if !altText.isEmpty {
                            captionText = altText
                        } else if !titleText.isEmpty {
                            captionText = titleText
                        }
                    }
                    
                    // Get figcaption text
                    if let figcaption = figcaption {
                        let figcaptionText = try figcaption.text()
                        if !figcaptionText.isEmpty {
                            if !captionText.isEmpty {
                                captionText = "\(captionText): \(figcaptionText)"
                            } else {
                                captionText = figcaptionText
                            }
                        }
                    }
                    
                    // Replace the entire figure with the caption
                    if !captionText.isEmpty {
                        try element.replaceWith(Element(Tag("p"), "").text("\(captionText)"))
                    } else {
                        try element.replaceWith(TextNode("", nil))
                    }
                }
            }
            
            // Convert br tags to newlines
            try doc.select("br").forEach { element in
                // Get the next sibling to check for whitespace
                if let nextSibling = element.nextSibling() as? TextNode {
                    let nextText = nextSibling.text()
                    if nextText.hasPrefix(" ") {
                        // Remove the leading space from the next sibling
                        nextSibling.text(String(nextText.dropFirst()))
                    }
                }
                try element.replaceWith(TextNode("\\n", nil))
            }
            
            // Add newlines after block elements
            try doc.select("p, div, h1, h2, h3, h4, h5, h6").forEach { element in
                try element.appendText("\n")
            }
            
            // Convert links to include URL
            try doc.select("a[href]").forEach { element in
                if let href = try? element.attr("href"), !href.isEmpty {
                    let text = try element.text()
                    if !text.isEmpty && text != href {
                        try element.text("\(text) (\(href))")
                    }
                }
            }
            
            // Convert list items to bullet points
            try doc.select("li").forEach { element in
                let text = try element.text()
                if !text.isEmpty {
                    try element.text("• \(text)")
                }
            }
            
            // Get text while preserving newlines by manually extracting
            let body = try doc.select("body").first() ?? doc
            let text = try extractTextWithNewlines(from: body)
            return text
        } catch {
            logger.warning("Failed to parse HTML content, falling back to regex stripping", metadata: [
                "error": error.localizedDescription
            ])
            return stripHTMLWithRegex(content)
        }
    }
    
    /// Extract text from an element while preserving newlines
    private func extractTextWithNewlines(from element: Element) throws -> String {
        var result = ""
        
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                let text = textNode.text()
                // Convert br markers back to newlines
                let processedText = text.replacingOccurrences(of: "\\n", with: "\n")
                // Preserve newlines but skip other whitespace-only nodes
                if !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || processedText.contains("\n") {
                    result += processedText
                    // If the text ends with a newline, it's likely an image caption, add another newline
                    if processedText.hasSuffix("\n") && !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result += "\n"
                    }
                }
            } else if let element = node as? Element {
                let tagName = element.tagName()
                let elementText = try extractTextWithNewlines(from: element)
                
                // Add newlines after block elements, but trim whitespace first
                if ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tagName) {
                    // For paragraphs, only trim leading/trailing whitespace, preserve internal newlines
                    let trimmedText = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedText.isEmpty {
                        // Check if this paragraph is followed by a list
                        let nextSibling = element.nextSibling()
                        var isFollowedByList = false
                        
                        // Check if next sibling is whitespace followed by a ul element
                        if let nextTextNode = nextSibling as? TextNode, 
                           nextTextNode.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let nextNextSibling = nextTextNode.nextSibling()
                            if let nextNextElement = nextNextSibling as? Element, nextNextElement.tagName() == "ul" {
                                isFollowedByList = true
                            }
                        }
                        
                        // Also check if this looks like a list header (ends with colon)
                        let isListHeader = trimmedText.hasSuffix(":")
                        
                        if isFollowedByList || isListHeader {
                            result += trimmedText + "\n"
                        } else {
                            result += trimmedText + "\n\n"
                        }
                    }
                } else if tagName == "li" {
                    let trimmedText = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedText.isEmpty {
                        result += trimmedText + "\n"
                    }
                } else if tagName == "ul" {
                    // For ul elements, add a newline after the content
                    result += elementText + "\n"
                } else {
                    result += elementText
                }
            }
        }
        
        return result
    }
    
    /// Fallback HTML stripping using regex (less accurate but safer)
    private func stripHTMLWithRegex(_ html: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(location: 0, length: html.utf16.count)
        let stripped = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: " ")
        
        // Decode common HTML entities
        return decodeHTMLEntities(stripped)
    }
    
    /// Strip quoted content from email body
    private func stripQuotedContent(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var inQuotedSection = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty lines
            if trimmed.isEmpty {
                if !inQuotedSection {
                    result.append(line)
                }
                continue
            }
            
            // Check for quoted content patterns
            if isQuotedLine(trimmed) {
                inQuotedSection = true
                continue
            }
            
            // Check for common reply headers that indicate start of quoted section
            if isReplyHeader(trimmed) {
                inQuotedSection = true
                continue
            }
            
            // Check if line contains quoted content anywhere in the line
            if containsQuotedContent(line) {
                // Remove quoted content from the line, but keep non-quoted parts
                let cleanedLine = removeQuotedContentFromLine(line)
                if !cleanedLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(cleanedLine)
                }
                inQuotedSection = true
                continue
            }
            
            // If we're not in a quoted section, keep the line
            if !inQuotedSection {
                result.append(line)
            }
        }
        
        return result.joined(separator: "\n")
    }
    
    /// Check if a line appears to be quoted content
    private func isQuotedLine(_ line: String) -> Bool {
        // Lines starting with >
        if line.hasPrefix(">") {
            return true
        }
        
        // Lines with multiple > characters
        if line.hasPrefix(">>") || line.hasPrefix(">>>") {
            return true
        }
        
        return false
    }
    
    /// Check if a line contains quoted content anywhere in the line
    private func containsQuotedContent(_ line: String) -> Bool {
        // Look for patterns like "> text" anywhere in the line
        let patterns = [
            " > ",
            " >",
            "> ",
            ">> ",
            ">>> "
        ]
        
        for pattern in patterns {
            if line.contains(pattern) {
                return true
            }
        }
        
        return false
    }
    
    /// Remove quoted content from a line while preserving non-quoted content
    private func removeQuotedContentFromLine(_ line: String) -> String {
        var result = line
        
        // Remove quoted content patterns
        let patterns = [
            " > ",
            " >",
            "> ",
            ">> ",
            ">>> "
        ]
        
        for pattern in patterns {
            // Find all occurrences of the pattern and remove the quoted part
            while let range = result.range(of: pattern) {
                let startIndex = range.upperBound
                let remainingText = String(result[startIndex...])
                
                // Find the end of the quoted content (next space or end of line)
                if let nextSpaceRange = remainingText.range(of: " ") {
                    let quotedEndIndex = nextSpaceRange.lowerBound
                    let afterQuoted = String(remainingText[quotedEndIndex...])
                    
                    // Remove the quoted content and the pattern
                    result = String(result[..<range.lowerBound]) + afterQuoted
                } else {
                    // No more spaces, remove everything from the pattern onwards
                    result = String(result[..<range.lowerBound])
                }
            }
        }
        
        return result
    }
    
    /// Check if a line is a reply header indicating start of quoted section
    private func isReplyHeader(_ line: String) -> Bool {
        let replyHeaders = [
            "On ",
            "From:",
            "Sent:",
            "To:",
            "Subject:",
            "Date:",
            "Message-ID:",
            "-----Original Message-----",
            "Begin forwarded message:",
            "Forwarded message"
        ]
        
        for header in replyHeaders {
            if line.hasPrefix(header) {
                return true
            }
        }
        
        return false
    }
    
    /// Strip signature from email body
    private func stripSignature(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var inSignature = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for signature delimiters - this marks the start of signature content
            if isSignatureDelimiter(trimmed) {
                inSignature = true
                continue
            }
            
            // If we're in signature section, check for common signature patterns
            // but also allow some content through if it looks like sign-off info
            if inSignature {
                // Allow sign-off content (job titles, company names) even after delimiter
                if isSignOffContent(trimmed) {
                    result.append(line)
                    continue
                }
                
                // Check for common signature patterns
                if isSignaturePattern(trimmed) {
                    continue
                }
                
                // If it's not clearly signature content, keep it (could be sign-off)
                result.append(line)
            } else {
                // Before signature delimiter, keep everything
                result.append(line)
            }
        }
        
        return result.joined(separator: "\n")
    }
    
    /// Check if a line is a signature delimiter
    private func isSignatureDelimiter(_ line: String) -> Bool {
        let delimiters = [
            "-- ",
            "--",
            "---",
            "________________________________",
            "________________"
        ]
        
        for delimiter in delimiters {
            if line == delimiter || line.hasPrefix(delimiter) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if a line matches common signature patterns
    private func isSignaturePattern(_ line: String) -> Bool {
        let patterns = [
            "Sent from my ",
            "Sent from ",
            "Get Outlook for ",
            "Sent via ",
            "This email was sent from ",
            "Please consider the environment",
            "Confidentiality Notice:",
            "This message and any attachments",
            "The information contained in this email"
        ]
        
        for pattern in patterns {
            if line.hasPrefix(pattern) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if a line contains sign-off content that should be preserved
    private func isSignOffContent(_ line: String) -> Bool {
        // Skip empty lines
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        
        // Common job titles and professional titles
        let jobTitles = [
            "Senior", "Junior", "Lead", "Principal", "Staff", "Director", "Manager",
            "Developer", "Engineer", "Designer", "Analyst", "Consultant", "Specialist",
            "Coordinator", "Administrator", "Assistant", "Associate", "Executive",
            "President", "CEO", "CTO", "CFO", "VP", "Vice President"
        ]
        
        // Check if line contains job title keywords
        for title in jobTitles {
            if line.contains(title) {
                return true
            }
        }
        
        // Check for company indicators
        let companyIndicators = [
            "Corporation", "Corp", "Company", "Inc", "LLC", "Ltd", "Limited",
            "Group", "Associates", "Partners", "Solutions", "Systems", "Technologies"
        ]
        
        for indicator in companyIndicators {
            if line.contains(indicator) {
                return true
            }
        }
        
        // Check for common sign-off patterns that aren't signature content
        let signOffPatterns = [
            "Best regards",
            "Kind regards", 
            "Sincerely",
            "Thanks",
            "Thank you",
            "Cheers",
            "Regards"
        ]
        
        for pattern in signOffPatterns {
            if line.hasPrefix(pattern) {
                return true
            }
        }
        
        return false
    }
    
    /// Decode HTML entities
    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&nbsp;": " ",
            "&lt;": "<",
            "&gt;": ">",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&copy;": "©",
            "&reg;": "®",
            "&trade;": "™"
        ]
        
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        
        return result
    }
    
    /// Normalize text formatting
    private func normalizeText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        
        // Trim only leading whitespace, preserve trailing newlines
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        // Add a final newline if the text doesn't end with one
        if !trimmed.isEmpty && !trimmed.hasSuffix("\n") {
            return trimmed + "\n"
        }
        return trimmed
    }
}
