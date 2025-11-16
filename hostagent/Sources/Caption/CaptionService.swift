import Foundation
import HavenCore
import CoreGraphics
import ImageIO
import CoreML

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Service for generating image captions
/// Supports Ollama vision models and Apple Foundation Multimodal model for image captioning
public actor CaptionService {
    private let logger = HavenLogger(category: "caption-service")
    private let method: String
    private let timeoutMs: Int
    private let model: String
    private let ollamaUrl: String
    private let openaiApiKey: String?
    private let openaiModel: String
    private let session: URLSession
    private let foundationModel: MLModel?

    // OpenAI retry configuration
    private let openaiMaxRetries: Int
    private let openaiBaseDelayMs: Int
    private let openaiMaxDelayMs: Int
    private let openaiJitter: Double
    
    public init(method: String = "ollama", timeoutMs: Int = 60000, model: String? = nil, openaiApiKey: String? = nil, openaiModel: String? = nil) {
        self.method = method
        self.timeoutMs = timeoutMs
        // Default to llava:7b if not specified for Ollama
        self.model = model ?? "llava:7b"
        
        // Default Ollama URL (can be overridden via environment variable in future)
        self.ollamaUrl = ProcessInfo.processInfo.environment["OLLAMA_API_URL"] ?? "http://localhost:11434/api/generate"
        
        // OpenAI configuration
        // Prioritize provided API key, then fall back to environment variable
        if let providedKey = openaiApiKey, !providedKey.isEmpty {
            self.openaiApiKey = providedKey
        } else {
            self.openaiApiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        }
        self.openaiModel = openaiModel ?? ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-4o"

        // OpenAI retry configuration with environment variable support
        self.openaiMaxRetries = Int(ProcessInfo.processInfo.environment["OPENAI_MAX_RETRIES"] ?? "") ?? 5
        self.openaiBaseDelayMs = Int(ProcessInfo.processInfo.environment["OPENAI_RETRY_BASE_DELAY_MS"] ?? "") ?? 500
        self.openaiMaxDelayMs = Int(ProcessInfo.processInfo.environment["OPENAI_RETRY_MAX_DELAY_MS"] ?? "") ?? 20000
        self.openaiJitter = Double(ProcessInfo.processInfo.environment["OPENAI_RETRY_JITTER"] ?? "") ?? 0.2

        // Create URLSession with timeout configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(timeoutMs) / 1000.0
        config.timeoutIntervalForResource = TimeInterval(timeoutMs * 3) / 1000.0  // Allow 3x timeout for resource
        self.session = URLSession(configuration: config)
        
        // Load Foundation Multimodal model if method is "apple" or "foundation"
        // TODO: Implement Foundation Multimodal API when available
        // The API shown in the example (MLModel.load(.foundationMultimodal), MLPredictionRequest, etc.)
        // is not yet available in the current CoreML framework. This needs to be implemented
        // when Apple releases the Foundation Multimodal model APIs.
        if method == "apple" || method == "foundation" {
            // Placeholder - Foundation Multimodal API not yet available
            // When available, this should load the model:
            // self.foundationModel = try MLModel.load(.foundationMultimodal)
            self.foundationModel = nil
        } else {
            self.foundationModel = nil
        }
    }
    
    /// Generate caption for an image
    /// - Parameters:
    ///   - imageData: Image data
    ///   - ocrText: Optional OCR text already extracted from the image. If provided, prompt focuses on scene description only.
    /// - Returns: Caption string, or nil if captioning fails or is disabled
    public func generateCaption(imageData: Data, ocrText: String? = nil, filename: String? = nil) async throws -> String? {
        // Handle Apple Foundation Multimodal model
        if method == "apple" || method == "foundation" {
            return try await generateCaptionWithFoundation(imageData: imageData, ocrText: ocrText)
        }
        
        // Handle OpenAI - returns caption only (token usage handled separately in comparison script)
        if method == "openai" {
            if let result = try await generateCaptionWithOpenAI(imageData: imageData, ocrText: ocrText, filename: filename) {
                return result.caption
            }
            return nil
        }
        
        // Handle Ollama
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
        // Downscale to max 2048px on longest side to reduce payload size and improve performance
        // Skip conversion if already PNG - just downscale if needed
        let pngData: Data
        if isPNG(imageData: imageData) {
            // Already PNG - just downscale if needed
            if let downscaled = await downscalePNG(imageData: imageData) {
                pngData = downscaled
            } else {
                // If downscaling fails, use original
                pngData = imageData
            }
        } else {
            // Not PNG - downscale and convert
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
    
    /// Detect image format from image data
    /// - Parameter imageData: Image data
    /// - Returns: Image format string (e.g., "public.png", "public.jpeg", "com.compuserve.gif") or nil
    private func detectImageFormat(imageData: Data) -> String? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let imageType = CGImageSourceGetType(imageSource) else {
            return nil
        }
        return imageType as String
    }
    
    /// Check if image is already PNG format
    /// - Parameter imageData: Image data
    /// - Returns: True if image is PNG
    private func isPNG(imageData: Data) -> Bool {
        guard let format = detectImageFormat(imageData: imageData) else {
            return false
        }
        return format.lowercased().contains("png")
    }
    
    /// Check if image is already GIF format
    /// - Parameter imageData: Image data
    /// - Returns: True if image is GIF
    private func isGIF(imageData: Data) -> Bool {
        guard let format = detectImageFormat(imageData: imageData) else {
            return false
        }
        return format.lowercased().contains("gif")
    }
    
    /// Downscale image to max dimension (without format conversion if already PNG)
    /// - Parameter imageData: Original image data
    /// - Parameter maxDimension: Maximum width or height (default 2048px)
    /// - Returns: Downscaled image data in original format (PNG), or nil if conversion fails
    private func downscalePNG(imageData: Data, maxDimension: Int = 2048) async -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        
        let originalWidth = image.width
        let originalHeight = image.height
        let maxSize = max(originalWidth, originalHeight)
        
        // If image is already within size limit, return original
        if maxSize <= maxDimension {
            return imageData
        }
        
        // Calculate new dimensions
        let scale = CGFloat(maxDimension) / CGFloat(maxSize)
        let newWidth = Int(CGFloat(originalWidth) * scale)
        let newHeight = Int(CGFloat(originalHeight) * scale)
        
        logger.debug("Downscaling PNG image", metadata: [
            "original_size": "\(originalWidth)x\(originalHeight)",
            "new_size": "\(newWidth)x\(newHeight)",
            "scale": String(format: "%.2f", scale)
        ])
        
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
        
        return mutableData as Data
    }
    
    /// Downscale image to max dimension and convert to PNG format
    /// - Parameter imageData: Original image data
    /// - Parameter maxDimension: Maximum width or height (default 2048px)
    /// - Returns: Downscaled PNG data, or nil if conversion fails
    private func downscaleAndConvertToPNG(imageData: Data, maxDimension: Int = 2048) async -> Data? {
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
    
    /// Downscale GIF image to max dimension (extracts first frame and downscales)
    /// - Parameter imageData: Original GIF image data
    /// - Parameter maxDimension: Maximum width or height (default 2048px)
    /// - Returns: Downscaled image data (as PNG, since creating animated GIFs is complex), or nil if no processing needed
    private func downscaleGIF(imageData: Data, maxDimension: Int = 2048) async -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        
        let originalWidth = image.width
        let originalHeight = image.height
        let maxSize = max(originalWidth, originalHeight)
        
        // If image is already within size limit, return nil to indicate no processing needed
        // (caller will use original GIF data)
        if maxSize <= maxDimension {
            return nil
        }
        
        // Calculate new dimensions
        let scale = CGFloat(maxDimension) / CGFloat(maxSize)
        let newWidth = Int(CGFloat(originalWidth) * scale)
        let newHeight = Int(CGFloat(originalHeight) * scale)
        
        logger.debug("Downscaling GIF image (extracting first frame)", metadata: [
            "original_size": "\(originalWidth)x\(originalHeight)",
            "new_size": "\(newWidth)x\(newHeight)",
            "scale": String(format: "%.2f", scale)
        ])
        
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
        
        // For GIFs, we extract the first frame and save as PNG (creating animated GIFs is complex)
        // This preserves the image content while downscaling
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
    
    /// Downscale image to max dimension and convert to JPEG format
    /// - Parameter imageData: Original image data
    /// - Parameter maxDimension: Maximum width or height (default 2048px)
    /// - Returns: Downscaled JPEG data, or nil if conversion fails
    private func downscaleAndConvertToJPEG(imageData: Data, maxDimension: Int = 2048) async -> Data? {
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
            
            logger.debug("Downscaling image for OpenAI captioning", metadata: [
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
        
        // Encode as JPEG
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        
        // Set JPEG compression quality (0.0 to 1.0, higher = better quality)
        let compressionQuality: CGFloat = 0.85
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        
        CGImageDestinationAddImage(destination, rgbImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        let finalData = mutableData as Data
        logger.debug("Image downscaled and converted to JPEG", metadata: [
            "original_bytes": "\(imageData.count)",
            "final_bytes": "\(finalData.count)",
            "compression_ratio": String(format: "%.2f", Double(finalData.count) / Double(imageData.count))
        ])
        
        return finalData
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
    
    /// Generate caption using Apple Foundation Multimodal model
    /// - Parameters:
    ///   - imageData: Image data
    ///   - ocrText: Optional OCR text already extracted from the image
    /// - Returns: Caption string, or nil if captioning fails
    private func generateCaptionWithFoundation(imageData: Data, ocrText: String?) async throws -> String? {
        // Foundation Multimodal API is not yet available in CoreML
        // The API structure shown in the example (MLModel.load(.foundationMultimodal), etc.)
        // is not yet available in the current CoreML framework.
        guard let foundationModel = foundationModel else {
            logger.warning("Foundation Multimodal model not available", metadata: ["method": method])
            throw CaptionServiceError.generationFailed("Foundation Multimodal API is not yet available - awaiting Apple's release of the CoreML API. Use 'ollama' or 'openai' method instead.")
        }
        
        // Limit image size to prevent memory issues (10MB max)
        guard imageData.count <= 10 * 1024 * 1024 else {
            logger.debug("Image too large for captioning", metadata: ["size": "\(imageData.count)"])
            return nil
        }
        
        // Get image dimensions for logging
        let imageSize: CGSize
        if let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
           let width = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight as String] as? CGFloat {
            imageSize = CGSize(width: width, height: height)
        } else {
            imageSize = CGSize(width: 0, height: 0)
        }
        
        logger.debug("Generating caption with Foundation Multimodal model", metadata: [
            "image_size_bytes": "\(imageData.count)",
            "image_size_px": "\(Int(imageSize.width))x\(Int(imageSize.height))",
            "has_ocr_text": ocrText != nil && !ocrText!.isEmpty
        ])
        
        // TODO: Implement Foundation Multimodal API when available
        // The API structure shown in the example is:
        // When the API becomes available, this code should:
        // 1. Convert imageData to UIImage (macOS 11.0+ supports UIImage via UIKit)
        // 2. Create MLPredictionRequest with image input:
        //    let request = MLPredictionRequest(
        //        inputs: [.image(image)],
        //        options: [.maxTokens(128)]
        //    )
        // 3. Call predict on the model:
        //    let result = try foundationModel.predict(request)
        // 4. Extract caption:
        //    let caption = result.text
        
        // For now, return an error indicating the API is not yet implemented
        logger.warning("Foundation Multimodal API is not yet available in CoreML")
        throw CaptionServiceError.generationFailed("Foundation Multimodal API is not yet available - awaiting Apple's release of the CoreML API. Use 'ollama' or 'openai' method instead.")
    }
    
    /// Generate caption using OpenAI Responses API
    /// - Parameters:
    ///   - imageData: Image data
    ///   - ocrText: Optional OCR text already extracted from the image
    ///   - filename: Optional filename (for logging purposes only)
    /// - Returns: Tuple with caption string and token usage, or nil if captioning fails
    private func generateCaptionWithOpenAI(imageData: Data, ocrText: String?, filename: String? = nil) async throws -> (caption: String, tokens: (input: Int, output: Int))? {
        guard let apiKey = openaiApiKey, !apiKey.isEmpty else {
            logger.warning("OpenAI API key not configured")
            throw CaptionServiceError.serviceUnavailable
        }
        
        // Limit image size to prevent memory issues (20MB max for OpenAI)
        guard imageData.count <= 20 * 1024 * 1024 else {
            logger.debug("Image too large for OpenAI captioning", metadata: ["size": "\(imageData.count)"])
            return nil
        }
        
        // Downscale image to 2048px on the long edge
        // Skip conversion if already PNG or GIF - just downscale if needed
        let processedImageData: Data
        let mimeType: String
        
        if isPNG(imageData: imageData) {
            // Already PNG - just downscale if needed
            mimeType = "image/png"
            if let downscaled = await downscalePNG(imageData: imageData) {
                processedImageData = downscaled
            } else {
                processedImageData = imageData
            }
        } else if isGIF(imageData: imageData) {
            // Already GIF - if small enough, keep as GIF; if needs downscaling, convert to PNG
            if let downscaled = await downscaleGIF(imageData: imageData) {
                // GIF was downscaled, which converts it to PNG
                mimeType = "image/png"
                processedImageData = downscaled
            } else {
                // GIF is small enough, keep as GIF
                mimeType = "image/gif"
                processedImageData = imageData
            }
        } else {
            // Not PNG or GIF - downscale and convert to JPEG
            mimeType = "image/jpeg"
            if let downscaled = await downscaleAndConvertToJPEG(imageData: imageData) {
                processedImageData = downscaled
            } else {
                // If downscaling/conversion fails, use original data
                processedImageData = imageData
            }
        }
        
        // Encode image as base64 data URL
        let imageBase64 = processedImageData.base64EncodedString()
        let dataUrl = "data:\(mimeType);base64,\(imageBase64)"
        
        // Build prompt based on whether OCR already found text
        var prompt = "Describe the image scene and contents. Provide a short, concise caption."
        if let ocrText = ocrText, !ocrText.isEmpty {
            // OCR already found text, focus on scene description only
            prompt = "Describe the image scene and contents. The text content has already been extracted, so focus on visual elements. Provide a short, concise caption."
        }
        
        logger.debug("Generating caption with OpenAI", metadata: [
            "model": openaiModel,
            "image_size_bytes": "\(imageData.count)",
            "processed_size_bytes": "\(processedImageData.count)",
            "has_ocr_text": ocrText != nil && !ocrText!.isEmpty
        ])
        
        // Build request payload for OpenAI Responses API
        var inputs: [[String: Any]] = []
        
        // Add image input - use base64 data URL
        inputs.append([
            "role": "user",
            "content": [
                [
                    "type": "input_image",
                    "image_url": dataUrl
                ],
                [
                    "type": "input_text",
                    "text": prompt
                ]
            ]
        ])
        
        let payload: [String: Any] = [
            "model": openaiModel,
            "input": inputs
        ]
        
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw CaptionServiceError.serviceUnavailable
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CaptionServiceError.generationFailed("Failed to encode request payload")
        }
        request.httpBody = jsonData
        
        logger.info("Calling OpenAI API for caption", metadata: [
            "model": openaiModel,
            "image_size_bytes": "\(imageData.count)",
            "processed_size_bytes": "\(processedImageData.count)"
        ])
        
        // Retry loop for OpenAI API calls
        var lastError: Error?
        let jitterFactor = self.openaiJitter

        for attempt in 0...(self.openaiMaxRetries) {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CaptionServiceError.serviceUnavailable
                }

                // Check for retryable errors
                if httpResponse.statusCode == 429 || httpResponse.statusCode >= 500 {
                    // Parse Retry-After header if present
                    var delayMs = 0.0
                    if let retryAfter = httpResponse.allHeaderFields["Retry-After"] as? String {
                        if let seconds = Double(retryAfter) {
                            delayMs = min(seconds * 1000.0, Double(self.openaiMaxDelayMs))
                        }
                    } else {
                        // Exponential backoff with jitter
                        delayMs = min(
                            Double(self.openaiBaseDelayMs) * pow(2.0, Double(attempt)),
                            Double(self.openaiMaxDelayMs)
                        )
                        // Apply jitter: ±20%
                        let jitterRange = delayMs * jitterFactor
                        delayMs *= (1.0 + Double.random(in: -jitterFactor...jitterFactor))
                    }

                    if attempt < self.openaiMaxRetries {
                        logger.warning("OpenAI API retry", metadata: [
                            "attempt": "\(attempt + 1)",
                            "max_retries": "\(self.openaiMaxRetries)",
                            "status_code": "\(httpResponse.statusCode)",
                            "delay_ms": String(format: "%.2f", delayMs),
                            "retry_after_header": httpResponse.allHeaderFields["Retry-After"] as? String ?? "none"
                        ])

                        try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000)) // Convert ms to nanoseconds
                        continue
                    } else {
                        // Final attempt failed
                        logger.error("OpenAI API failed after all retries", metadata: [
                            "attempts": "\(self.openaiMaxRetries + 1)",
                            "final_status_code": "\(httpResponse.statusCode)"
                        ])
                        let body = String(data: data, encoding: .utf8) ?? ""
                        throw CaptionServiceError.generationFailed("HTTP \(httpResponse.statusCode): \(body.prefix(100))")
                    }
                }

                // Success or non-retryable error
                guard (200...299).contains(httpResponse.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    logger.debug("OpenAI API returned error", metadata: [
                        "status": "\(httpResponse.statusCode)",
                        "body": body.prefix(200).description
                    ])
                    throw CaptionServiceError.generationFailed("HTTP \(httpResponse.statusCode): \(body.prefix(100))")
                }

                // Parse response JSON
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CaptionServiceError.generationFailed("Invalid JSON response")
                }

                // Extract caption from OpenAI Responses API format
                // Response structure: {"output": [{"content": [{"type": "output_text", "text": "..."}]}]}
                var caption: String? = nil

                if let output = json["output"] as? [[String: Any]] {
                    for block in output {
                        if let content = block["content"] as? [[String: Any]] {
                            for item in content {
                                if let type = item["type"] as? String,
                                   type == "output_text",
                                   let text = item["text"] as? String, !text.isEmpty {
                                    caption = text
                                    break
                                }
                            }
                            if caption != nil {
                                break
                            }
                        }
                    }
                }

                // Extract token usage from response
                let usage = json["usage"] as? [String: Any]
                let inputTokens = usage?["input_tokens"] as? Int ?? usage?["prompt_tokens"] as? Int ?? 0
                let outputTokens = usage?["output_tokens"] as? Int ?? usage?["completion_tokens"] as? Int ?? 0

                if let captionText = caption {
                    // Truncate to reasonable length (200 chars)
                    let truncated = captionText.count > 200 ? String(captionText.prefix(200)) + "…" : captionText
                    logger.info("Caption generated successfully with OpenAI", metadata: [
                        "caption_length": "\(captionText.count)",
                        "truncated": captionText.count > 200,
                        "caption_preview": truncated.prefix(50).description,
                        "input_tokens": "\(inputTokens)",
                        "output_tokens": "\(outputTokens)"
                    ])
                    return (caption: truncated.trimmingCharacters(in: .whitespacesAndNewlines), tokens: (input: inputTokens, output: outputTokens))
                }

                logger.warning("OpenAI response missing caption", metadata: [
                    "response_keys": "\(json.keys.joined(separator: ", "))",
                    "response_preview": "\(String(describing: json).prefix(200))"
                ])
                return nil

            } catch let error as CaptionServiceError {
                // Business logic errors - don't retry
                logger.warning("Caption service error", metadata: [
                    "error": error.localizedDescription
                ])
                throw error
            } catch let error as URLError where error.code == .timedOut || error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                lastError = error
                if attempt < self.openaiMaxRetries {
                    // Exponential backoff with jitter for network errors
                    var delayMs = min(
                        Double(self.openaiBaseDelayMs) * pow(2.0, Double(attempt)),
                        Double(self.openaiMaxDelayMs)
                    )
                    // Apply jitter: ±20%
                    delayMs *= (1.0 + Double.random(in: -jitterFactor...jitterFactor))

                    logger.warning("OpenAI API network error, retrying", metadata: [
                        "attempt": "\(attempt + 1)",
                        "max_retries": "\(self.openaiMaxRetries)",
                        "error": error.localizedDescription,
                        "delay_ms": String(format: "%.2f", delayMs)
                    ])

                    try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000)) // Convert ms to nanoseconds
                    continue
                } else {
                    logger.error("OpenAI API failed after all retries", metadata: [
                        "attempts": "\(self.openaiMaxRetries + 1)",
                        "final_error": error.localizedDescription
                    ])
                    throw CaptionServiceError.generationFailed("Network error after retries: \(error.localizedDescription)")
                }
            } catch {
                lastError = error
                if attempt < self.openaiMaxRetries {
                    // Exponential backoff with jitter for other transient errors
                    var delayMs = min(
                        Double(self.openaiBaseDelayMs) * pow(2.0, Double(attempt)),
                        Double(self.openaiMaxDelayMs)
                    )
                    // Apply jitter: ±20%
                    delayMs *= (1.0 + Double.random(in: -jitterFactor...jitterFactor))

                    logger.warning("OpenAI API error, retrying", metadata: [
                        "attempt": "\(attempt + 1)",
                        "max_retries": "\(self.openaiMaxRetries)",
                        "error": error.localizedDescription,
                        "delay_ms": String(format: "%.2f", delayMs)
                    ])

                    try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000)) // Convert ms to nanoseconds
                    continue
                } else {
                    logger.error("OpenAI API failed after all retries", metadata: [
                        "attempts": "\(self.openaiMaxRetries + 1)",
                        "final_error": error.localizedDescription
                    ])
                    throw CaptionServiceError.generationFailed("Request failed after retries: \(error.localizedDescription)")
                }
            }
        }

        // All retries exhausted (should not reach here due to throws above)
        if let error = lastError {
            throw CaptionServiceError.generationFailed("Request failed after \(self.openaiMaxRetries + 1) attempts: \(error.localizedDescription)")
        } else {
            throw CaptionServiceError.generationFailed("Request failed after \(self.openaiMaxRetries + 1) attempts")
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

