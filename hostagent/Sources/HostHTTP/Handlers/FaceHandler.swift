import Foundation
import HavenCore
import Face

/// HTTP handler for face detection endpoint
public struct FaceHandler {
    private let faceService: FaceService
    private let config: FaceModuleConfig
    
    public init(faceService: FaceService, config: FaceModuleConfig) {
        self.faceService = faceService
        self.config = config
    }
    
    /// Handle face detection request
    public func handle(request: HTTPRequest) async -> HTTPResponse {
        // Check if module is enabled
        guard config.enabled else {
            return HTTPResponse(
                statusCode: 501,
                headers: ["Content-Type": "application/json"],
                body: formatError("Face detection module is disabled")
            )
        }
        
        // Parse request body
        guard let body = request.body else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: formatError("Request body required")
            )
        }
        
        guard let requestData = try? JSONDecoder().decode(FaceDetectRequest.self, from: body) else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: formatError("Invalid request format. Expected JSON with 'image_path' or 'image_data'")
            )
        }
        
        do {
            // Perform face detection
            let result: FaceDetectionResult
            
            if let imagePath = requestData.imagePath {
                result = try await faceService.detectFaces(
                    imagePath: imagePath,
                    includeLandmarks: requestData.includeLandmarks
                )
            } else if let imageDataB64 = requestData.imageData,
                      let imageData = Data(base64Encoded: imageDataB64) {
                result = try await faceService.detectFaces(
                    imageData: imageData,
                    includeLandmarks: requestData.includeLandmarks
                )
            } else {
                return HTTPResponse(
                    statusCode: 400,
                    headers: ["Content-Type": "application/json"],
                    body: formatError("Either 'image_path' or 'image_data' (base64) must be provided")
                )
            }
            
            // Format successful response
            let response = FaceDetectResponse(
                status: "success",
                data: result
            )
            
            let responseData = try JSONEncoder().encode(response)
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
            )
            
        } catch let error as FaceServiceError {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: formatError(error.localizedDescription)
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: formatError("Face detection failed: \(error.localizedDescription)")
            )
        }
    }
    
    private func formatError(_ message: String) -> Data {
        let error = ErrorResponse(status: "error", error: message)
        return (try? JSONEncoder().encode(error)) ?? Data()
    }
}

// MARK: - Request/Response Models

struct FaceDetectRequest: Codable {
    let imagePath: String?
    let imageData: String?  // Base64 encoded
    let includeLandmarks: Bool?
    
    enum CodingKeys: String, CodingKey {
        case imagePath = "image_path"
        case imageData = "image_data"
        case includeLandmarks = "include_landmarks"
    }
}

struct FaceDetectResponse: Codable {
    let status: String
    let data: FaceDetectionResult
}

struct ErrorResponse: Codable {
    let status: String
    let error: String
}

// Re-export FaceDetectionResult for the handler
import Face
