import Foundation
import SwiftSoup
import CryptoKit
import CoreGraphics
import ImageIO

/// Shared service for extracting images from various content types
/// Generalized from EmailImageExtractor to be used by all collectors
public struct ImageExtractor {
    private let logger = HavenLogger(category: "image-extractor")
    
    public init() {}
    
    /// Extract images from HTML content
    /// - Parameters:
    ///   - htmlContent: HTML content to extract images from
    ///   - basePath: Optional base path for resolving relative image URLs
    ///   - minSquarePixels: Minimum square pixels (width * height) to include. Default is 0 (no filtering).
    /// - Returns: Array of ImageAttachment metadata (files not retained, only metadata)
    public func extractImages(from htmlContent: String, basePath: String? = nil, minSquarePixels: Int = 0) async -> [ImageAttachment] {
        var images: [ImageAttachment] = []
        
        do {
            let doc = try SwiftSoup.parse(htmlContent)
            let imgElements = try doc.select("img")
            
            for img in imgElements {
                if let srcRaw = try? img.attr("src"), !srcRaw.isEmpty {
                    // Decode HTML entities and URL encoding in the src attribute
                    let src = srcRaw.removingPercentEncoding ?? srcRaw
                    
                    // Handle data URIs (embedded images)
                    if src.hasPrefix("data:image/") {
                        if let imageAttachment = await extractFromDataURI(src) {
                            // Filter by size if specified
                            if minSquarePixels == 0 || meetsSizeRequirement(imageAttachment, minSquarePixels: minSquarePixels) {
                                images.append(imageAttachment)
                            } else {
                                logger.debug("Skipping image below size threshold", metadata: [
                                    "hash": imageAttachment.hash,
                                    "dimensions": imageAttachment.dimensions.map { "\($0.width)x\($0.height)" } ?? "unknown"
                                ])
                            }
                        }
                    } else if src.hasPrefix("http://") || src.hasPrefix("https://") {
                        // Handle HTTP/HTTPS URLs (remote images)
                        if let imageAttachment = await extractFromURL(src) {
                            // Filter by size if specified
                            if minSquarePixels == 0 || meetsSizeRequirement(imageAttachment, minSquarePixels: minSquarePixels) {
                                images.append(imageAttachment)
                            } else {
                                logger.debug("Skipping image below size threshold", metadata: [
                                    "hash": imageAttachment.hash,
                                    "url": src,
                                    "dimensions": imageAttachment.dimensions.map { "\($0.width)x\($0.height)" } ?? "unknown"
                                ])
                            }
                        }
                    } else {
                        // Handle file paths (for local files)
                        // Note: In practice, this would need to resolve the path and load the image
                        // For now, we'll skip local file paths that aren't absolute
                        logger.debug("Skipping local file path image", metadata: ["src": src])
                    }
                }
            }
        } catch {
            logger.warning("Failed to parse HTML for image extraction", metadata: [
                "error": error.localizedDescription
            ])
        }
        
        return images
    }
    
    /// Extract images from file content
    /// - Parameters:
    ///   - fileContent: File data
    ///   - mimeType: MIME type of the file
    ///   - filePath: Optional file path
    ///   - minSquarePixels: Minimum square pixels (width * height) to include. Default is 0 (no filtering).
    /// - Returns: Array of ImageAttachment metadata
    public func extractImages(from fileContent: Data, mimeType: String, filePath: String? = nil, minSquarePixels: Int = 0) async -> [ImageAttachment] {
        var images: [ImageAttachment] = []
        
        // Check if the file itself is an image
        if isImageMimeType(mimeType) {
            if let imageAttachment = await createImageAttachment(from: fileContent, mimeType: mimeType, filePath: filePath) {
                // Filter by size if specified
                if minSquarePixels == 0 || meetsSizeRequirement(imageAttachment, minSquarePixels: minSquarePixels) {
                    images.append(imageAttachment)
                } else {
                    logger.debug("Skipping image below size threshold", metadata: [
                        "hash": imageAttachment.hash,
                        "filename": imageAttachment.filename ?? "unknown",
                        "dimensions": imageAttachment.dimensions.map { "\($0.width)x\($0.height)" } ?? "unknown"
                    ])
                }
            }
        } else if mimeType == "text/html" {
            // Extract images from HTML content
            if let htmlString = String(data: fileContent, encoding: .utf8) {
                let htmlImages = await extractImages(from: htmlString, basePath: filePath, minSquarePixels: minSquarePixels)
                images.append(contentsOf: htmlImages)
            }
        }
        
        return images
    }
    
    /// Extract image from HTTP/HTTPS URL
    private func extractFromURL(_ urlString: String) async -> ImageAttachment? {
        guard let url = URL(string: urlString) else {
            logger.debug("Invalid image URL", metadata: ["url": urlString])
            return nil
        }
        
        do {
            // Create URLSession with timeout configuration
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = 10.0  // 10 second timeout
            sessionConfig.timeoutIntervalForResource = 30.0  // 30 second total timeout
            let session = URLSession(configuration: sessionConfig)
            
            // Download image data with timeout
            let (data, response) = try await session.data(from: url)
            
            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    logger.debug("Failed to download image", metadata: [
                        "url": urlString,
                        "statusCode": String(httpResponse.statusCode)
                    ])
                    return nil
                }
                
                // Determine MIME type from response or URL
                let mimeType = httpResponse.mimeType ?? extractMimeTypeFromURL(urlString) ?? "image/jpeg"
                
                // Verify it's actually an image
                guard isImageMimeType(mimeType) else {
                    logger.debug("URL does not point to an image", metadata: [
                        "url": urlString,
                        "mimeType": mimeType
                    ])
                    return nil
                }
                
                // Limit download size to prevent memory issues (10MB max)
                guard data.count <= 10 * 1024 * 1024 else {
                    logger.debug("Image too large to process", metadata: [
                        "url": urlString,
                        "size": String(data.count)
                    ])
                    return nil
                }
                
                // Create image attachment from downloaded data
                return await createImageAttachment(from: data, mimeType: mimeType, filePath: nil)
            }
            
            return nil
        } catch {
            logger.debug("Failed to download image from URL", metadata: [
                "url": urlString,
                "error": error.localizedDescription
            ])
            return nil
        }
    }
    
    /// Extract MIME type from URL extension
    private func extractMimeTypeFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let pathExtension = url.pathExtension.lowercased().isEmpty ? nil : url.pathExtension.lowercased() else {
            return nil
        }
        
        let mimeTypeMap: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "webp": "image/webp",
            "bmp": "image/bmp",
            "tiff": "image/tiff",
            "tif": "image/tiff",
            "svg": "image/svg+xml"
        ]
        
        return mimeTypeMap[pathExtension]
    }
    
    /// Extract image from data URI
    private func extractFromDataURI(_ dataURI: String) async -> ImageAttachment? {
        // Format: data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...
        let components = dataURI.components(separatedBy: ",")
        guard components.count == 2 else { return nil }
        
        let header = components[0]
        guard header.hasPrefix("data:image/") && header.contains("base64") else { return nil }
        
        // Extract MIME type
        let mimeType = extractMimeTypeFromDataURI(header) ?? "image/png"
        
        let base64String = components[1]
        guard let imageData = Data(base64Encoded: base64String) else { return nil }
        
        // Compute hash
        let hash = sha256Hex(of: imageData)
        
        // Get dimensions (optional, can be expensive)
        let dimensions = await getImageDimensions(from: imageData)
        
        return ImageAttachment(
            hash: hash,
            mimeType: mimeType,
            dimensions: dimensions,
            extractedAt: Date(),
            filename: nil,
            size: Int64(imageData.count),
            temporaryData: imageData  // Store temporarily for enrichment
        )
    }
    
    /// Create ImageAttachment from file data
    private func createImageAttachment(from data: Data, mimeType: String, filePath: String?) async -> ImageAttachment? {
        // Compute hash
        let hash = sha256Hex(of: data)
        
        // Get dimensions
        let dimensions = await getImageDimensions(from: data)
        
        return ImageAttachment(
            hash: hash,
            mimeType: mimeType,
            dimensions: dimensions,
            extractedAt: Date(),
            filename: filePath?.components(separatedBy: "/").last,
            size: Int64(data.count),
            temporaryPath: filePath,
            temporaryData: data  // Store temporarily for enrichment
        )
    }
    
    /// Extract MIME type from data URI header
    private func extractMimeTypeFromDataURI(_ header: String) -> String? {
        // Format: data:image/png;base64
        let parts = header.components(separatedBy: ";")
        guard parts.count >= 1 else { return nil }
        
        let mimePart = parts[0]
        guard mimePart.hasPrefix("data:") else { return nil }
        
        let mimeType = String(mimePart.dropFirst(5))  // Remove "data:"
        return mimeType.isEmpty ? nil : mimeType
    }
    
    /// Get image dimensions from data
    private func getImageDimensions(from data: Data) async -> ImageDimensions? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        
        return ImageDimensions(width: width, height: height)
    }
    
    /// Check if MIME type is an image
    private func isImageMimeType(_ mimeType: String) -> Bool {
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
    
    /// Compute SHA-256 hash of data
    private func sha256Hex(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Check if an image meets the minimum size requirement
    /// - Parameters:
    ///   - image: The image attachment to check
    ///   - minSquarePixels: Minimum square pixels (width * height) required
    /// - Returns: True if image meets size requirement or dimensions are unknown (to be safe)
    private func meetsSizeRequirement(_ image: ImageAttachment, minSquarePixels: Int) -> Bool {
        guard let dimensions = image.dimensions else {
            // If dimensions are unknown, include it to be safe (will be checked during enrichment)
            return true
        }
        let squarePixels = dimensions.width * dimensions.height
        return squarePixels > minSquarePixels
    }
}

