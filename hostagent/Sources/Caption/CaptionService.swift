import Foundation
import HavenCore
import CoreGraphics
import ImageIO

/// Service for generating image captions
/// Supports Ollama vision models for image captioning
public actor CaptionService {
    private let logger = HavenLogger(category: "caption-service")
    private let method: String
    private let timeoutMs: Int
    private let model: String
    private let ollamaUrl: String
    private let session: URLSession
    
    public init(method: String = "ollama", timeoutMs: Int = 60000, model: String? = nil) {
        self.method = method
        self.timeoutMs = timeoutMs
        // Default to llava:7b if not specified
        self.model = model ?? "llava:7b"
        
        // Default Ollama URL (can be overridden via environment variable in future)
        self.ollamaUrl = ProcessInfo.processInfo.environment["OLLAMA_API_URL"] ?? "http://localhost:11434/api/generate"
        
        // Create URLSession with timeout configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(timeoutMs) / 1000.0
        config.timeoutIntervalForResource = TimeInterval(timeoutMs * 3) / 1000.0  // Allow 3x timeout for resource
        self.session = URLSession(configuration: config)
    }
    
    /// Generate caption for an image
    /// - Parameters:
    ///   - imageData: Image data
    ///   - ocrText: Optional OCR text already extracted from the image. If provided, prompt focuses on scene description only.
    /// - Returns: Caption string, or nil if captioning fails or is disabled
    public func generateCaption(imageData: Data, ocrText: String? = nil) async throws -> String? {
        guard method == "ollama" else {
            logger.debug("Caption method not supported", metadata: ["method": method])
            return nil
        }
        
        // Limit image size to prevent memory issues (10MB max)
        guard imageData.count <= 10 * 1024 * 1024 else {
            logger.debug("Image too large for captioning", metadata: ["size": "\(imageData.count)"])
            return nil
        }
        
        // Downscale and convert image to PNG format (Ollama requires PNG)
        // Downscale to max 1024px on longest side to reduce payload size and improve performance
        let pngData: Data
        if let downscaled = await downscaleAndConvertToPNG(imageData: imageData) {
            pngData = downscaled
        } else {
            // If downscaling/conversion fails, try simple PNG conversion
            if let converted = await convertToPNG(imageData: imageData) {
                pngData = converted
            } else {
                // If conversion fails, try original data (may fail with some formats)
                pngData = imageData
            }
        }
        
        // Encode image as base64
        let imageBase64 = pngData.base64EncodedString()
        
        // Build prompt based on whether OCR already found text
        let basePrompt = "describe the image scene and contents. short response"
        let prompt: String
        if let ocrText = ocrText, !ocrText.isEmpty {
            // OCR already found text, focus on scene description only
            prompt = basePrompt
        } else {
            // No OCR text, ask vision model to extract any visible text
            prompt = "\(basePrompt). If there is any visible text, include what it says."
        }
        
        // Call Ollama API
        return try await callOllamaAPI(imageBase64: imageBase64, prompt: prompt)
    }
    
    /// Downscale image to max dimension and convert to PNG format
    /// - Parameter imageData: Original image data
    /// - Parameter maxDimension: Maximum width or height (default 1024px)
    /// - Returns: Downscaled PNG data, or nil if conversion fails
    private func downscaleAndConvertToPNG(imageData: Data, maxDimension: Int = 1024) async -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        
        let originalWidth = image.width
        let originalHeight = image.height
        let maxSize = max(originalWidth, originalHeight)
        
        // Calculate new dimensions if downscaling is needed
        let newWidth: Int
        let newHeight: Int
        
        if maxSize > maxDimension {
            let scale = CGFloat(maxDimension) / CGFloat(maxSize)
            newWidth = Int(CGFloat(originalWidth) * scale)
            newHeight = Int(CGFloat(originalHeight) * scale)
            
            logger.debug("Downscaling image for captioning", metadata: [
                "original_size": "\(originalWidth)x\(originalHeight)",
                "new_size": "\(newWidth)x\(newHeight)",
                "scale": String(format: "%.2f", scale)
            ])
        } else {
            newWidth = originalWidth
            newHeight = originalHeight
        }
        
        // Convert to RGB if needed and downscale
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        
        // Use high-quality interpolation for downscaling
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let rgbImage = context.makeImage() else {
            return nil
        }
        
        // Encode as PNG
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        
        CGImageDestinationAddImage(destination, rgbImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        let finalData = mutableData as Data
        logger.debug("Image downscaled and converted to PNG", metadata: [
            "original_bytes": "\(imageData.count)",
            "final_bytes": "\(finalData.count)",
            "compression_ratio": String(format: "%.2f", Double(finalData.count) / Double(imageData.count))
        ])
        
        return finalData
    }
    
    /// Convert image data to PNG format (without downscaling)
    private func convertToPNG(imageData: Data) async -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        
        // Convert to RGB if needed
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rgbImage = context.makeImage() else {
            return nil
        }
        
        // Encode as PNG
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        
        CGImageDestinationAddImage(destination, rgbImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return mutableData as Data
    }
    
    /// Call Ollama API to generate caption
    private func callOllamaAPI(imageBase64: String, prompt: String) async throws -> String? {
        guard let url = URL(string: ollamaUrl) else {
            logger.debug("Invalid Ollama URL", metadata: ["url": ollamaUrl])
            throw CaptionServiceError.serviceUnavailable
        }
        
        // Build request payload
        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "images": [imageBase64],
            "stream": false
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        
        // Encode JSON payload
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CaptionServiceError.generationFailed("Failed to encode request payload")
        }
        request.httpBody = jsonData
        
        logger.info("Calling Ollama API for caption", metadata: [
            "url": ollamaUrl,
            "model": model,
            "image_size_bytes": "\(imageBase64.count)",
            "image_size_base64": "\(imageBase64.count) chars"
        ])
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CaptionServiceError.serviceUnavailable
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.debug("Ollama API returned error", metadata: [
                    "status": "\(httpResponse.statusCode)",
                    "body": body.prefix(200).description
                ])
                throw CaptionServiceError.generationFailed("HTTP \(httpResponse.statusCode): \(body.prefix(100))")
            }
            
            // Parse response JSON
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CaptionServiceError.generationFailed("Invalid JSON response")
            }
            
            // Extract caption from response
            // Ollama can return captions in different formats:
            // 1. {"response": "caption text", ...} - direct response
            // 2. {"message": {"content": "caption text", ...}, ...} - nested message format
            var caption: String? = nil
            
            // Try direct response field first
            if let responseText = json["response"] as? String, !responseText.isEmpty {
                caption = responseText
            }
            // Try nested message.content format
            else if let message = json["message"] as? [String: Any],
                    let content = message["content"] as? String, !content.isEmpty {
                caption = content
            }
            
            if let captionText = caption {
                // Truncate to reasonable length (200 chars)
                let truncated = captionText.count > 200 ? String(captionText.prefix(200)) + "…" : captionText
                logger.info("Caption generated successfully", metadata: [
                    "caption_length": "\(captionText.count)",
                    "truncated": captionText.count > 200,
                    "caption_preview": truncated.prefix(50).description
                ])
                return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // Log response structure for debugging
            logger.warning("Ollama response missing caption", metadata: [
                "response_keys": "\(json.keys.joined(separator: ", "))",
                "response_preview": "\(String(describing: json).prefix(200))",
                "full_response": "\(json)"
            ])
            return nil
            
        } catch let error as CaptionServiceError {
            logger.warning("Caption service error", metadata: [
                "error": error.localizedDescription
            ])
            throw error
        } catch let error as URLError where error.code == .timedOut {
            logger.warning("Caption generation timed out", metadata: [
                "timeout_ms": String(timeoutMs)
            ])
            throw CaptionServiceError.timeout
        } catch {
            logger.error("Ollama API call failed", metadata: [
                "error": error.localizedDescription,
                "error_type": String(describing: type(of: error))
            ])
            throw CaptionServiceError.generationFailed(error.localizedDescription)
        }
    }
    
    /// Generate caption for an image at a file path
    /// - Parameters:
    ///   - imagePath: Path to image file
    ///   - ocrText: Optional OCR text already extracted from the image
    /// - Returns: Caption string, or nil if captioning fails or is disabled
    public func generateCaption(imagePath: String, ocrText: String? = nil) async throws -> String? {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw CaptionServiceError.imageNotFound(path: imagePath)
        }
        
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
            throw CaptionServiceError.invalidImageFormat
        }
        
        return try await generateCaption(imageData: imageData, ocrText: ocrText)
    }
}

/// Errors that can occur during caption generation
public enum CaptionServiceError: LocalizedError {
    case imageNotFound(path: String)
    case invalidImageFormat
    case timeout
    case serviceUnavailable
    case generationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .imageNotFound(let path):
            return "Image not found at path: \(path)"
        case .invalidImageFormat:
            return "Invalid or unsupported image format"
        case .timeout:
            return "Caption generation timed out"
        case .serviceUnavailable:
            return "Caption service is unavailable"
        case .generationFailed(let message):
            return "Caption generation failed: \(message)"
        }
    }
}

