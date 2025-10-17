import Foundation
@preconcurrency import Vision
import CoreImage
import OSLog

/// Vision-based OCR service for macOS
public actor OCRService {
    private let logger = Logger(subsystem: "com.haven.hostagent", category: "ocr")
    private let timeoutMs: Int
    private let languages: [String]
    private let recognitionLevel: String
    private let includeLayout: Bool
    
    public init(timeoutMs: Int = 2000, 
                languages: [String] = ["en"],
                recognitionLevel: String = "fast",
                includeLayout: Bool = true) {
        self.timeoutMs = timeoutMs
        self.languages = languages
        self.recognitionLevel = recognitionLevel
        self.includeLayout = includeLayout
    }
    
    /// Process image from file path or data
    public func processImage(path: String? = nil, 
                            data: Data? = nil,
                            recognitionLevel: String? = nil,
                            includeLayout: Bool? = nil) async throws -> OCRResult {
        let startTime = Date()
        var timings: [String: Int] = [:]
        
        // Use provided parameters or fall back to instance defaults
        let effectiveRecognitionLevel = recognitionLevel ?? self.recognitionLevel
        let effectiveIncludeLayout = includeLayout ?? self.includeLayout
        
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
        let (text, boxes, regions, detectedLanguages) = try await performVisionOCR(
            imageData: imageData,
            recognitionLevel: effectiveRecognitionLevel,
            includeLayout: effectiveIncludeLayout
        )
        timings["ocr"] = Int(Date().timeIntervalSince(ocrStart) * 1000)
        timings["total"] = Int(Date().timeIntervalSince(startTime) * 1000)
        
        logger.info("OCR completed: \(text.count) chars, \(boxes.count) boxes, \(regions?.count ?? 0) regions, \(timings["total"] ?? 0)ms")
        
        return OCRResult(
            ocrText: text,
            ocrBoxes: boxes,
            regions: effectiveIncludeLayout ? regions : nil,
            detectedLanguages: effectiveIncludeLayout ? detectedLanguages : nil,
            recognitionLevel: effectiveRecognitionLevel,
            lang: detectedLanguages?.first ?? languages.first ?? "en",
            tooling: ["vision": "macOS-\(ProcessInfo.processInfo.operatingSystemVersionString)"],
            timingsMs: timings
        )
    }
    
    private func performVisionOCR(imageData: Data, 
                                  recognitionLevel: String,
                                  includeLayout: Bool) async throws -> (String, [OCRBox], [OCRRegion]?, [String]?) {
        guard let cgImage = createCGImage(from: imageData) else {
            throw OCRError.invalidImage
        }
        
        let request = VNRecognizeTextRequest()
        
        // Set recognition level based on parameter
        request.recognitionLevel = recognitionLevel == "accurate" ? .accurate : .fast
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        
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
                    var regions: [OCRRegion] = []
                    var detectedLanguageSet = Set<String>()
                    
                    for observation in results {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let text = candidate.string
                        fullText += text + "\n"
                        
                        // Extract bounding box (Vision uses bottom-left origin, convert to top-left)
                        let visionBox = observation.boundingBox
                        
                        // Convert from bottom-left to top-left coordinate system
                        let normalizedBox = [
                            Float(visionBox.origin.x),
                            Float(1.0 - visionBox.origin.y - visionBox.height),  // Convert Y coordinate
                            Float(visionBox.width),
                            Float(visionBox.height)
                        ]
                        
                        let box = OCRBox(
                            text: text,
                            bbox: normalizedBox,
                            level: "line",
                            confidence: Float(observation.confidence)
                        )
                        boxes.append(box)
                        
                        // Build enhanced region if layout is requested
                        if includeLayout {
                            // For language detection, we rely on the request's configuration
                            // Individual text observations don't expose per-text language in Vision API
                            // We'll use the configured languages as hints
                            let detectedLang = self.languages.first
                            if let lang = detectedLang {
                                detectedLanguageSet.insert(lang)
                            }
                            
                            let region = OCRRegion(
                                text: text,
                                boundingBox: BoundingBox(
                                    x: normalizedBox[0],
                                    y: normalizedBox[1],
                                    width: normalizedBox[2],
                                    height: normalizedBox[3]
                                ),
                                confidence: Float(observation.confidence),
                                detectedLanguage: detectedLang
                            )
                            regions.append(region)
                        }
                    }
                    
                    let detectedLanguages = includeLayout ? Array(detectedLanguageSet) : nil
                    let returnRegions = includeLayout ? regions : nil
                    
                    continuation.resume(returning: (
                        fullText.trimmingCharacters(in: .whitespacesAndNewlines), 
                        boxes, 
                        returnRegions,
                        detectedLanguages
                    ))
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
        if #available(macOS 13.0, *) {
            do {
                let request = VNRecognizeTextRequest()
                supportedLanguages = try request.supportedRecognitionLanguages()
            } catch {
                supportedLanguages = ["en"]
            }
        } else {
            // Fallback for older macOS versions
            supportedLanguages = ["en", "es", "fr", "de", "it", "pt", "zh-Hans", "zh-Hant"]
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
    public let regions: [OCRRegion]?
    public let detectedLanguages: [String]?
    public let recognitionLevel: String?
    public let lang: String
    public let tooling: [String: String]
    public let timingsMs: [String: Int]
    
    enum CodingKeys: String, CodingKey {
        case ocrText = "ocr_text"
        case ocrBoxes = "ocr_boxes"
        case regions
        case detectedLanguages = "detected_languages"
        case recognitionLevel = "recognition_level"
        case lang
        case tooling
        case timingsMs = "timings_ms"
    }
}

public struct OCRRegion: Codable {
    public let text: String
    public let boundingBox: BoundingBox
    public let confidence: Float
    public let detectedLanguage: String?
    
    enum CodingKeys: String, CodingKey {
        case text
        case boundingBox = "bounding_box"
        case confidence
        case detectedLanguage = "detected_language"
    }
    
    public init(text: String, boundingBox: BoundingBox, confidence: Float, detectedLanguage: String? = nil) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.detectedLanguage = detectedLanguage
    }
}

public struct BoundingBox: Codable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float
    
    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
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
