import Foundation
import SwiftSoup
import HavenCore
import OCR

/// Protocol for OCR services to enable testing
public protocol OCRServiceProtocol {
    func processImage(path: String?, data: Data?, recognitionLevel: String?, includeLayout: Bool?) async throws -> OCRResult
}

extension OCRService: OCRServiceProtocol {}

/// Service for extracting image captions from email content
public struct EmailImageExtractor {
    private let logger = HavenLogger(category: "email-image-extractor")
    
    public init() {}
    
    /// Extract image captions from email content using HTML metadata and OCR fallback
    /// - Parameters:
    ///   - email: The email message to process
    ///   - attachments: Email attachments that might contain images
    ///   - ocrService: Optional OCR service for fallback caption extraction
    /// - Returns: Array of extracted image captions
    public func extractImageCaptions(
        from email: EmailMessage,
        attachments: [EmailAttachment],
        ocrService: OCRServiceProtocol? = nil
    ) async -> [String] {
        var captions: [String] = []
        
        // Extract captions from HTML content
        if let htmlContent = email.bodyHTML {
            let htmlCaptions = extractCaptionsFromHTML(htmlContent)
            captions.append(contentsOf: htmlCaptions)
        }
        
        // For images without captions, try OCR if service is available
        if let ocrService = ocrService {
            let ocrCaptions = await extractCaptionsWithOCR(
                from: email,
                attachments: attachments,
                ocrService: ocrService
            )
            captions.append(contentsOf: ocrCaptions)
        }
        
        // Remove duplicates and empty captions
        return Array(Set(captions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
    }
    
    /// Extract image captions from HTML content
    private func extractCaptionsFromHTML(_ html: String) -> [String] {
        var captions: [String] = []
        
        do {
            let doc = try SwiftSoup.parse(html)
            
            // Extract from img tags
            let imgElements = try doc.select("img")
            for img in imgElements {
                // Try alt attribute first
                if let alt = try? img.attr("alt"), !alt.isEmpty {
                    captions.append(alt)
                }
                
                // Try title attribute
                if let title = try? img.attr("title"), !title.isEmpty {
                    captions.append(title)
                }
            }
            
            // Extract from figure elements with figcaption
            let figures = try doc.select("figure")
            for figure in figures {
                let figcaption = try figure.select("figcaption")
                if !figcaption.isEmpty() {
                    let caption = try figcaption.text()
                    if !caption.isEmpty {
                        captions.append(caption)
                    }
                }
            }
            
            // Extract from images with adjacent text
            let imagesWithText = try doc.select("img + p, img + div, p + img, div + img")
            for element in imagesWithText {
                let text = try element.text()
                if !text.isEmpty && text.count > 10 { // Only consider substantial text
                    captions.append(text)
                }
            }
            
        } catch {
            logger.warning("Failed to parse HTML for image captions", metadata: [
                "error": error.localizedDescription
            ])
        }
        
        return captions
    }
    
    /// Extract captions using OCR for images without HTML captions
    private func extractCaptionsWithOCR(
        from email: EmailMessage,
        attachments: [EmailAttachment],
        ocrService: OCRServiceProtocol
    ) async -> [String] {
        var captions: [String] = []
        
        // Process attachments that are likely images
        for attachment in attachments {
            guard isImageAttachment(attachment) else { continue }
            
            // For now, we'll skip OCR on attachments since we don't have access to the actual file data
            // This would require integration with the attachment handling system
            logger.debug("Skipping OCR for attachment", metadata: [
                "filename": attachment.filename ?? "unknown",
                "mimeType": attachment.mimeType ?? "unknown"
            ])
        }
        
        // Process embedded images from HTML (data URIs)
        if let htmlContent = email.bodyHTML {
            let embeddedCaptions = await extractCaptionsFromEmbeddedImages(
                htmlContent: htmlContent,
                ocrService: ocrService
            )
            captions.append(contentsOf: embeddedCaptions)
        }
        
        return captions
    }
    
    /// Extract captions from embedded images in HTML
    private func extractCaptionsFromEmbeddedImages(
        htmlContent: String,
        ocrService: OCRServiceProtocol
    ) async -> [String] {
        var captions: [String] = []
        
        do {
            let doc = try SwiftSoup.parse(htmlContent)
            let imgElements = try doc.select("img")
            
            for img in imgElements {
                // Check for data URI images
                if let src = try? img.attr("src"), src.hasPrefix("data:image/") {
                    // Extract base64 data
                    if let base64Data = extractBase64FromDataURI(src) {
                        do {
                            let ocrResult = try await ocrService.processImage(path: nil, data: base64Data, recognitionLevel: nil, includeLayout: nil)
                            if !ocrResult.ocrText.isEmpty {
                                captions.append(ocrResult.ocrText)
                            }
                        } catch {
                            logger.debug("OCR failed for embedded image", metadata: [
                                "error": error.localizedDescription
                            ])
                        }
                    }
                }
            }
        } catch {
            logger.warning("Failed to parse HTML for embedded images", metadata: [
                "error": error.localizedDescription
            ])
        }
        
        return captions
    }
    
    /// Extract base64 data from data URI
    private func extractBase64FromDataURI(_ dataURI: String) -> Data? {
        // Format: data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...
        let components = dataURI.components(separatedBy: ",")
        guard components.count == 2 else { return nil }
        
        let header = components[0]
        guard header.hasPrefix("data:image/") && header.contains("base64") else { return nil }
        
        let base64String = components[1]
        return Data(base64Encoded: base64String)
    }
    
    /// Check if an attachment is likely an image
    private func isImageAttachment(_ attachment: EmailAttachment) -> Bool {
        guard let mimeType = attachment.mimeType else { return false }
        
        let imageMimeTypes = [
            "image/jpeg",
            "image/jpg", 
            "image/png",
            "image/gif",
            "image/bmp",
            "image/tiff",
            "image/webp",
            "image/svg+xml"
        ]
        
        return imageMimeTypes.contains(mimeType.lowercased())
    }
    
    /// Extract image references from HTML content
    private func extractImageReferences(from html: String) -> [String] {
        var references: [String] = []
        
        do {
            let doc = try SwiftSoup.parse(html)
            let imgElements = try doc.select("img")
            
            for img in imgElements {
                if let src = try? img.attr("src"), !src.isEmpty {
                    references.append(src)
                }
            }
        } catch {
            logger.warning("Failed to extract image references", metadata: [
                "error": error.localizedDescription
            ])
        }
        
        return references
    }
}
