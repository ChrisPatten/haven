import Foundation
import CoreGraphics
import ImageIO
import HavenCore

/// Utility for converting images to JPEG format
/// Handles HEIC/HEIF and other formats, converting them to JPEG for external serving
public actor ImageConverter {
    private let logger = HavenLogger(category: "image-converter")
    
    public init() {}
    
    /// Convert image data to JPEG format and save to output path
    /// - Parameters:
    ///   - imageData: Original image data (can be HEIC, HEIF, PNG, etc.)
    ///   - outputPath: Path where JPEG should be saved
    /// - Returns: Path to the converted JPEG file
    /// - Throws: Error if conversion fails
    public func convertToJPEG(imageData: Data, outputPath: String) async throws -> String {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw ImageConverterError.invalidImageData
        }
        
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ImageConverterError.failedToCreateImage
        }
        
        // Get image properties for logging
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth as String] as? Int ?? image.width
        let originalHeight = properties?[kCGImagePropertyPixelHeight as String] as? Int ?? image.height
        
        logger.debug("Converting image to JPEG", metadata: [
            "original_size": "\(originalWidth)x\(originalHeight)",
            "output_path": outputPath
        ])
        
        // Create output URL
        let outputURL = URL(fileURLWithPath: outputPath)
        
        // Ensure output directory exists
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        // Create JPEG destination
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw ImageConverterError.failedToCreateDestination
        }
        
        // Set JPEG compression quality (0.0 to 1.0, higher = better quality)
        let compressionQuality: CGFloat = 0.85
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        
        // Add image to destination
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        
        // Finalize and write
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConverterError.failedToFinalize
        }
        
        // Verify file was created
        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw ImageConverterError.fileNotCreated
        }
        
        // Get file size for logging
        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath),
           let fileSize = attributes[.size] as? Int64 {
            logger.debug("Image converted successfully", metadata: [
                "output_path": outputPath,
                "file_size_bytes": "\(fileSize)",
                "compression_quality": String(format: "%.2f", compressionQuality)
            ])
        }
        
        return outputPath
    }
    
    /// Check if image needs conversion (is HEIC/HEIF)
    /// - Parameter imageData: Image data to check
    /// - Returns: True if image is HEIC or HEIF format
    public func needsConversion(imageData: Data) -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let imageType = CGImageSourceGetType(imageSource) else {
            return false
        }
        
        let typeString = imageType as String
        return typeString.lowercased().contains("heic") || typeString.lowercased().contains("heif")
    }
}

/// Errors that can occur during image conversion
public enum ImageConverterError: LocalizedError {
    case invalidImageData
    case failedToCreateImage
    case failedToCreateDestination
    case failedToFinalize
    case fileNotCreated
    
    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Invalid image data provided"
        case .failedToCreateImage:
            return "Failed to create image from data"
        case .failedToCreateDestination:
            return "Failed to create image destination"
        case .failedToFinalize:
            return "Failed to finalize image conversion"
        case .fileNotCreated:
            return "Converted file was not created"
        }
    }
}

