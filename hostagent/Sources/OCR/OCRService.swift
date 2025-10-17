import Foundation
@preconcurrency import Vision
import CoreImage
import OSLog

/// Vision-based OCR service for macOS
public actor OCRService {
    private let logger = Logger(subsystem: "com.haven.hostagent", category: "ocr")
    private let timeoutMs: Int
    private let languages: [String]
    
    public init(timeoutMs: Int = 2000, languages: [String] = ["en"]) {
        self.timeoutMs = timeoutMs
        self.languages = languages
    }
    
    /// Process image from file path or data
    public func processImage(path: String? = nil, data: Data? = nil) async throws -> OCRResult {
        let startTime = Date()
        var timings: [String: Int] = [:]
        
        // Load image
        let imageData: Data
        if let path = path {
            let readStart = Date()
            imageData = try Data(contentsOf: URL(fileURLWithPath: path))
            timings["read"] = Int(Date().timeIntervalSince(readStart) * 1000)
        } else if let data = data {
            imageData = data
        } else {
            throw OCRError.noInput
        }
        
        // Perform OCR
        let ocrStart = Date()
        let (text, boxes, detectedLang) = try await performVisionOCR(imageData: imageData)
        timings["ocr"] = Int(Date().timeIntervalSince(ocrStart) * 1000)
        timings["total"] = Int(Date().timeIntervalSince(startTime) * 1000)
        
        logger.info("OCR completed: \(text.count) chars, \(boxes.count) boxes, \(timings["total"] ?? 0)ms")
        
        return OCRResult(
            ocrText: text,
            ocrBoxes: boxes,
            lang: detectedLang,
            tooling: ["vision": "macOS-\(ProcessInfo.processInfo.operatingSystemVersionString)"],
            timingsMs: timings
        )
    }
    
    private func performVisionOCR(imageData: Data) async throws -> (String, [OCRBox], String) {
        guard let cgImage = createCGImage(from: imageData) else {
            throw OCRError.invalidImage
        }
        
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        // Set language hints if provided
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        return try await withCheckedThrowingContinuation { continuation in
            // Add timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                continuation.resume(throwing: OCRError.timeout)
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    timeoutTask.cancel()
                    
                    guard let results = request.results else {
                        continuation.resume(throwing: OCRError.noResults)
                        return
                    }
                    
                    var fullText = ""
                    var boxes: [OCRBox] = []
                    let detectedLang = self.languages.first ?? "en"
                    
                    for observation in results {
                        let text = observation.topCandidates(1).first?.string ?? ""
                        fullText += text + "\n"
                        
                        // Extract bounding box
                        let boundingBox = observation.boundingBox
                        let box = OCRBox(
                            text: text,
                            bbox: [
                                Float(boundingBox.origin.x),
                                Float(boundingBox.origin.y),
                                Float(boundingBox.width),
                                Float(boundingBox.height)
                            ],
                            level: "line",
                            confidence: Float(observation.confidence)
                        )
                        boxes.append(box)
                    }
                    
                    continuation.resume(returning: (fullText.trimmingCharacters(in: .whitespacesAndNewlines), boxes, detectedLang))
                } catch {
                    timeoutTask.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func createCGImage(from data: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        return cgImage
    }
    
    public func healthCheck() -> OCRHealth {
        let supportedLanguages: [String]
        do {
            supportedLanguages = try VNRecognizeTextRequest.supportedRecognitionLanguages(
                for: .accurate,
                revision: VNRecognizeTextRequestRevision3
            )
        } catch {
            supportedLanguages = ["en"]
        }
        
        return OCRHealth(
            available: true,
            supportedLanguages: supportedLanguages,
            configuredLanguages: languages,
            visionVersion: "macOS-\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
    }
}

// MARK: - Data Types

public struct OCRResult: Codable {
    public let ocrText: String
    public let ocrBoxes: [OCRBox]
    public let lang: String
    public let tooling: [String: String]
    public let timingsMs: [String: Int]
    
    enum CodingKeys: String, CodingKey {
        case ocrText = "ocr_text"
        case ocrBoxes = "ocr_boxes"
        case lang
        case tooling
        case timingsMs = "timings_ms"
    }
}

public struct OCRBox: Codable {
    public let text: String
    public let bbox: [Float]  // [x, y, w, h] normalized 0-1
    public let level: String  // "line", "word", etc.
    public let confidence: Float?
    
    public init(text: String, bbox: [Float], level: String, confidence: Float? = nil) {
        self.text = text
        self.bbox = bbox
        self.level = level
        self.confidence = confidence
    }
}

public struct OCRHealth: Codable {
    public let available: Bool
    public let supportedLanguages: [String]
    public let configuredLanguages: [String]
    public let visionVersion: String
    
    enum CodingKeys: String, CodingKey {
        case available
        case supportedLanguages = "supported_languages"
        case configuredLanguages = "configured_languages"
        case visionVersion = "vision_version"
    }
}

public enum OCRError: Error, LocalizedError {
    case noInput
    case invalidImage
    case timeout
    case noResults
    case visionError(String)
    
    public var errorDescription: String? {
        switch self {
        case .noInput:
            return "No image path or data provided"
        case .invalidImage:
            return "Failed to create image from data"
        case .timeout:
            return "OCR processing timed out"
        case .noResults:
            return "No text detected in image"
        case .visionError(let msg):
            return "Vision framework error: \(msg)"
        }
    }
}
