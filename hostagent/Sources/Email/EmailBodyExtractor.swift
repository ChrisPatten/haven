import Foundation
import Demark
import HTMLEntities
import HavenCore

/// Service for extracting clean email body text from raw MIME/HTML content
public struct EmailBodyExtractor {
    private let logger = HavenLogger(category: "email-body-extractor")
    
    public init() {}
    
    /// Extract clean body text from an email message, converting HTML to markdown and removing quoted content and signatures
    /// - Parameter email: The email message to process
    /// - Returns: Cleaned markdown body text
    public func extractCleanBody(from email: EmailMessage) async -> String {
        // Start with the best available body content
        let rawBody = selectBestBody(from: email)
        
        // Convert HTML to markdown if needed
        let isHTML = rawBody.contains("<") && rawBody.contains(">") && 
                    (rawBody.contains("<html") || rawBody.contains("<body") || 
                     rawBody.contains("<p>") || rawBody.contains("<div") ||
                     rawBody.contains("<br") || rawBody.contains("<h1") ||
                     rawBody.contains("<ul") || rawBody.contains("<li"))
        let markdownText = isHTML ? await convertToMarkdown(rawBody) : rawBody
        
        // Strip quoted content (both text patterns and HTML blockquotes)
        let withoutQuotes = stripQuotedContent(markdownText)
        
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
    
    /// Convert HTML to markdown using Demark html-to-md engine with post-processing
    @MainActor
    private func convertToMarkdown(_ content: String) async -> String {
        // If content doesn't look like HTML, return as-is
        if !content.contains("<") || !content.contains(">") {
            return content
        }
        
        do {
            let demark = Demark()
            var result = try await demark.convertToMarkdown(content)
            
            // Post-process the markdown to handle edge cases Demark doesn't address
            result = postProcessMarkdown(result)
            
            return result
        } catch {
            logger.warning("Demark conversion failed, falling back to regex stripping", metadata: [
                "error": error.localizedDescription
            ])
            return stripHTMLWithRegex(content)
        }
    }
    
    /// Post-process markdown output to handle edge cases and ensure consistent formatting
    private func postProcessMarkdown(_ markdown: String) -> String {
        var result = markdown
        
        // Decode HTML entities using HTMLEntities package
        result = result.htmlUnescape()
        
        // Convert markdown images to plain text captions for consistency with our use case
        result = convertMarkdownImagesToCaptions(result)
        
        // Ensure blockquotes are properly stripped (they should be removed, not converted)
        result = stripMarkdownBlockquotes(result)
        
        // Keep markdown formatting - don't convert to plain text
        // This preserves semantic structure for downstream processing
        
        return result
    }
    
    /// Convert markdown images to plain text captions
    private func convertMarkdownImagesToCaptions(_ markdown: String) -> String {
        // Pattern: ![alt text](url "title") or ![alt text](url)
        let imagePattern = #"!\[([^\]]*)\]\([^)]*(?:\s+"([^"]*)")?\)"#
        
        guard let regex = try? NSRegularExpression(pattern: imagePattern) else {
            return markdown
        }
        
        let range = NSRange(location: 0, length: markdown.utf16.count)
        let matches = regex.matches(in: markdown, options: [], range: range)
        
        var result = markdown
        // Process matches in reverse order to avoid index shifting
        for match in matches.reversed() {
            let altText = match.range(at: 1)
            let titleText = match.range(at: 2)
            
            var caption = ""
            if altText.location != NSNotFound {
                caption = String(markdown[Range(altText, in: markdown)!])
            }
            if titleText.location != NSNotFound {
                let title = String(markdown[Range(titleText, in: markdown)!])
                if !caption.isEmpty {
                    caption = "\(caption): \(title)"
                } else {
                    caption = title
                }
            }
            
            let replacement = caption.isEmpty ? "" : "\(caption)"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        
        return result
    }
    
    /// Strip markdown blockquotes (they should be removed, not converted to markdown)
    private func stripMarkdownBlockquotes(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [String] = []
        
        for line in lines {
            // Skip lines that start with > (markdown blockquotes)
            if line.hasPrefix(">") {
                continue
            }
            result.append(line)
        }
        
        return result.joined(separator: "\n")
    }
    
    
    /// Fallback HTML stripping using regex (less accurate but safer)
    private func stripHTMLWithRegex(_ html: String) -> String {
        // First strip HTML tags - only remove known HTML tags to avoid removing content that looks like tags
        let pattern = "</?(?:html|body|head|title|meta|link|script|style|div|span|p|br|h[1-6]|ul|ol|li|a|img|table|tr|td|th|form|input|button|strong|em|b|i|u|pre|code|blockquote|hr)(?:\\s[^>]*)?>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html.htmlUnescape()
        }
        let range = NSRange(location: 0, length: html.utf16.count)
        let stripped = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: " ")
        
        // Then decode HTML entities using HTMLEntities package
        return stripped.htmlUnescape()
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
        // Look for patterns like "> text" at the beginning of lines or after whitespace
        // This is more specific to avoid matching decoded HTML entities like "<brackets>"
        let patterns = [
            "^> ",      // Line starts with "> "
            "^>> ",     // Line starts with ">> "
            "^>>> ",    // Line starts with ">>> "
            " > ",      // Space followed by "> " (but not in middle of words)
            " >> ",     // Space followed by ">> "
            " >>> "     // Space followed by ">>> "
        ]
        
        for pattern in patterns {
            if line.range(of: pattern, options: .regularExpression) != nil {
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
