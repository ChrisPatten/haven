import Foundation
import Vision
import CoreImage

#if canImport(AppKit)
import AppKit
#endif

/// Represents a detected face with bounding box and optional landmarks
public struct DetectedFace: Codable {
    public let boundingBox: BoundingBox
    public let confidence: Double
    public let qualityScore: Double?
    public let landmarks: FaceLandmarks?
    public let faceId: String  // Placeholder UUID for future recognition
    
    public struct BoundingBox: Codable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
    
    public struct FaceLandmarks: Codable {
        public let leftEye: Point?
        public let rightEye: Point?
        public let nose: Point?
        public let mouth: Point?
        public let leftPupil: Point?
        public let rightPupil: Point?
    }
    
    public struct Point: Codable {
        public let x: Double
        public let y: Double
    }
}

/// Result of face detection operation
public struct FaceDetectionResult: Codable {
    public let faces: [DetectedFace]
    public let imageSize: ImageSize?
    
    public struct ImageSize: Codable {
        public let width: Int
        public let height: Int
    }
}

/// Face detection service using Apple Vision framework
public actor FaceService {
    private let minFaceSize: Double
    private let minConfidence: Double
    private let includeLandmarks: Bool
    
    public init(minFaceSize: Double = 0.01, minConfidence: Double = 0.7, includeLandmarks: Bool = false) {
        self.minFaceSize = minFaceSize
        self.minConfidence = minConfidence
        self.includeLandmarks = includeLandmarks
    }
    
    /// Detect faces in an image at the given path
    public func detectFaces(imagePath: String, includeLandmarks: Bool? = nil) async throws -> FaceDetectionResult {
        let url = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw FaceServiceError.imageNotFound(path: imagePath)
        }
        
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FaceServiceError.invalidImageFormat
        }
        
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw FaceServiceError.invalidImageFormat
        }
        
        return try await detectFaces(cgImage: cgImage, includeLandmarks: includeLandmarks)
    }
    
    /// Detect faces in an image from base64 data
    public func detectFaces(imageData: Data, includeLandmarks: Bool? = nil) async throws -> FaceDetectionResult {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw FaceServiceError.invalidImageFormat
        }
        
        return try await detectFaces(cgImage: cgImage, includeLandmarks: includeLandmarks)
    }
    
    /// Core face detection implementation
    private func detectFaces(cgImage: CGImage, includeLandmarks: Bool?) async throws -> FaceDetectionResult {
        let shouldIncludeLandmarks = includeLandmarks ?? self.includeLandmarks
        
        // Create face detection request
        let faceRequest = VNDetectFaceRectanglesRequest()
        
        // Create landmarks request if needed
        let landmarksRequest = shouldIncludeLandmarks ? VNDetectFaceLandmarksRequest() : nil
        
        // Prepare image request handler
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        // Perform detection
        var requests: [VNRequest] = [faceRequest]
        if let landmarksRequest = landmarksRequest {
            requests.append(landmarksRequest)
        }
        
        try handler.perform(requests)
        
        // Process face observations
        guard let faceObservations = faceRequest.results else {
            return FaceDetectionResult(
                faces: [],
                imageSize: FaceDetectionResult.ImageSize(width: cgImage.width, height: cgImage.height)
            )
        }
        
        // Get landmark observations if available
        let landmarkObservations = (landmarksRequest?.results as? [VNFaceObservation]) ?? []
        
        // Filter and process faces
        let imageWidth = Double(cgImage.width)
        let imageHeight = Double(cgImage.height)
        
        let detectedFaces = faceObservations.compactMap { observation -> DetectedFace? in
            // Filter by confidence
            guard observation.confidence >= Float(minConfidence) else {
                return nil
            }
            
            // Filter by minimum face size
            let faceArea = observation.boundingBox.width * observation.boundingBox.height
            guard faceArea >= minFaceSize else {
                return nil
            }
            
            // Convert Vision coordinates (bottom-left origin) to standard top-left origin
            let bbox = observation.boundingBox
            let standardBBox = DetectedFace.BoundingBox(
                x: bbox.origin.x,
                y: 1.0 - bbox.origin.y - bbox.height,  // Flip Y axis
                width: bbox.width,
                height: bbox.height
            )
            
            // Calculate quality score based on face size, confidence, and position
            let qualityScore = calculateQualityScore(
                boundingBox: bbox,
                confidence: Double(observation.confidence),
                imageSize: CGSize(width: imageWidth, height: imageHeight)
            )
            
            // Extract landmarks if available
            var faceLandmarks: DetectedFace.FaceLandmarks? = nil
            if shouldIncludeLandmarks,
               let landmarkObs = landmarkObservations.first(where: { $0.uuid == observation.uuid }),
               let landmarks = landmarkObs.landmarks {
                faceLandmarks = extractLandmarks(from: landmarks, boundingBox: bbox)
            }
            
            return DetectedFace(
                boundingBox: standardBBox,
                confidence: Double(observation.confidence),
                qualityScore: qualityScore,
                landmarks: faceLandmarks,
                faceId: UUID().uuidString
            )
        }
        
        return FaceDetectionResult(
            faces: detectedFaces,
            imageSize: FaceDetectionResult.ImageSize(width: cgImage.width, height: cgImage.height)
        )
    }
    
    /// Calculate quality score for a detected face
    private func calculateQualityScore(boundingBox: CGRect, confidence: Double, imageSize: CGSize) -> Double {
        // Base score from confidence
        var score = confidence
        
        // Penalize very small faces
        let faceArea = boundingBox.width * boundingBox.height
        let areaPenalty = min(1.0, faceArea / 0.1)  // Faces smaller than 10% of image get penalized
        score *= areaPenalty
        
        // Penalize faces near edges (may be cut off)
        let centerX = boundingBox.midX
        let centerY = boundingBox.midY
        let edgeDistance = min(centerX, 1.0 - centerX, centerY, 1.0 - centerY)
        let edgePenalty = min(1.0, edgeDistance / 0.1)  // Penalize if within 10% of edge
        score *= (0.8 + 0.2 * edgePenalty)  // Reduce penalty weight
        
        return score
    }
    
    /// Extract facial landmarks from VNFaceLandmarks2D
    private func extractLandmarks(from landmarks: VNFaceLandmarks2D, boundingBox: CGRect) -> DetectedFace.FaceLandmarks {
        func normalizePoint(_ points: [CGPoint]?, in bbox: CGRect) -> DetectedFace.Point? {
            guard let points = points, let first = points.first else {
                return nil
            }
            // Convert from face-relative coordinates to image coordinates
            let x = bbox.origin.x + first.x * bbox.width
            let y = 1.0 - (bbox.origin.y + first.y * bbox.height)  // Flip Y axis
            return DetectedFace.Point(x: x, y: y)
        }
        
        return DetectedFace.FaceLandmarks(
            leftEye: normalizePoint(landmarks.leftEye?.normalizedPoints, in: boundingBox),
            rightEye: normalizePoint(landmarks.rightEye?.normalizedPoints, in: boundingBox),
            nose: normalizePoint(landmarks.nose?.normalizedPoints, in: boundingBox),
            mouth: normalizePoint(landmarks.outerLips?.normalizedPoints, in: boundingBox),
            leftPupil: normalizePoint(landmarks.leftPupil?.normalizedPoints, in: boundingBox),
            rightPupil: normalizePoint(landmarks.rightPupil?.normalizedPoints, in: boundingBox)
        )
    }
}

/// Errors that can occur during face detection
public enum FaceServiceError: LocalizedError {
    case imageNotFound(path: String)
    case invalidImageFormat
    case detectionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .imageNotFound(let path):
            return "Image not found at path: \(path)"
        case .invalidImageFormat:
            return "Invalid or unsupported image format"
        case .detectionFailed(let message):
            return "Face detection failed: \(message)"
        }
    }
}
