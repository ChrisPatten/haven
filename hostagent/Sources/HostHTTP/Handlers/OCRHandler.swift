import Foundation
import HavenCore
import OCR

/// Handler for OCR endpoint
public struct OCRHandler {
    private let config: HavenConfig
    private let ocrService: OCRService
    private let logger = HavenLogger(category: "ocr-handler")
    
    public init(config: HavenConfig) {
        self.config = config
        self.ocrService = OCRService(
            timeoutMs: config.modules.ocr.timeoutMs,
            languages: config.modules.ocr.languages,
            recognitionLevel: config.modules.ocr.recognitionLevel,
            includeLayout: config.modules.ocr.includeLayout
        )
    }
    
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Check if OCR is enabled
        guard config.modules.ocr.enabled else {
            logger.warning("OCR request rejected - module disabled")
            return HTTPResponse(
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"OCR module is disabled"}"#.data(using: .utf8)
            )
        }
        
        // Parse request body
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            logger.warning("Invalid request body")
            return HTTPResponse.badRequest(message: "Invalid request body - expected JSON")
        }
        
        // Extract parameters
        let imagePath = json["image_path"] as? String
        let imageDataBase64 = json["image_data"] as? String
        let recognitionLevel = json["recognition_level"] as? String
        let includeLayout = json["include_layout"] as? Bool
        
        // Validate input
        var imageData: Data? = nil
        if let path = imagePath {
            do {
                imageData = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                logger.error("Failed to read image file", metadata: ["path": path, "error": error.localizedDescription])
                return HTTPResponse.badRequest(message: "Failed to read image file: \(error.localizedDescription)")
            }
        } else if let base64 = imageDataBase64 {
            imageData = Data(base64Encoded: base64)
        }
        
        guard imageData != nil else {
            logger.warning("No image data provided")
            return HTTPResponse.badRequest(message: "Either image_path or image_data must be provided")
        }
        
        // Perform OCR
        do {
            let result = try await ocrService.processImage(
                data: imageData,
                recognitionLevel: recognitionLevel,
                includeLayout: includeLayout
            )
            
            logger.info("OCR completed successfully", metadata: [
                "text_length": result.ocrText.count,
                "boxes": result.ocrBoxes.count,
                "regions": result.regions?.count ?? 0
            ])
            
            // Encode result
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let resultData = try encoder.encode(result)
            
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: resultData
            )
        } catch {
            logger.error("OCR processing failed", metadata: ["error": error.localizedDescription])
            return HTTPResponse.internalError(message: "OCR processing failed: \(error.localizedDescription)")
        }
    }
}
