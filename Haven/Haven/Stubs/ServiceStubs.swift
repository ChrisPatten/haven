//
//  ServiceStubs.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//  Stub implementation for service types until package dependencies are added
//

import Foundation

// MARK: - OCR Service Stub

public actor OCRService {
    private let timeoutMs: Int
    private let languages: [String]
    private let recognitionLevel: String
    private let includeLayout: Bool
    private let maxImageDimension: Int
    
    public init(timeoutMs: Int = 2000, 
                languages: [String] = ["en"],
                recognitionLevel: String = "fast",
                includeLayout: Bool = true,
                maxImageDimension: Int = 1600) {
        self.timeoutMs = timeoutMs
        self.languages = languages
        self.recognitionLevel = recognitionLevel
        self.includeLayout = includeLayout
        self.maxImageDimension = maxImageDimension
    }
    
    public func processImage(path: String? = nil, data: Data? = nil, recognitionLevel: String? = nil, includeLayout: Bool? = nil) async throws -> OCRResult {
        // Stub implementation
        return OCRResult(text: "", confidence: 0.0, languages: [], layout: nil, timingsMs: [:])
    }
}

public struct OCRResult: Codable {
    public let text: String
    public let confidence: Double
    public let languages: [String]
    public let layout: [OCRRegion]?
    public let timingsMs: [String: Int]
    
    public init(text: String, confidence: Double, languages: [String], layout: [OCRRegion]?, timingsMs: [String: Int]) {
        self.text = text
        self.confidence = confidence
        self.languages = languages
        self.layout = layout
        self.timingsMs = timingsMs
    }
}

public struct OCRRegion: Codable {
    public let text: String
    public let bounds: OCRBounds
    public let confidence: Double
}

public struct OCRBounds: Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

// MARK: - Entity Service Stub

public actor EntityService {
    private let enabledTypes: Set<EntityType>
    private let minConfidence: Float
    
    public init(enabledTypes: [EntityType] = EntityType.allCases, minConfidence: Float = 0.0) {
        self.enabledTypes = Set(enabledTypes)
        self.minConfidence = minConfidence
    }
    
    public func extractEntities(from text: String, enabledTypes: [EntityType]? = nil, minConfidence: Float? = nil) async throws -> EntityExtractionResult {
        // Stub implementation
        return EntityExtractionResult(entities: [], totalEntities: 0, timingsMs: [:])
    }
}

public enum EntityType: String, Codable, CaseIterable {
    case person
    case organization
    case location
    case date
    case phoneNumber
    case emailAddress
}

public struct EntityExtractionResult: Codable {
    public let entities: [Entity]
    public let totalEntities: Int
    public let timingsMs: [String: Int]
}

public struct Entity: Codable {
    public let text: String
    public let type: EntityType
    public let confidence: Float
    public let range: NSRange?
}

// MARK: - FSWatch Service Stub

public actor FSWatchService {
    private let config: FSWatchModuleConfig
    private var watchers: [String: FileSystemWatcher] = [:]
    private var eventQueue: [FileSystemEvent] = []
    private let maxQueueSize: Int
    private var fileIngestionHandler: FileIngestionHandler?
    
    public init(config: FSWatchModuleConfig, maxQueueSize: Int = 1000) {
        self.config = config
        self.maxQueueSize = maxQueueSize
    }
    
    public func setFileIngestionHandler(_ handler: FileIngestionHandler?) {
        self.fileIngestionHandler = handler
    }
    
    public func start() async throws {
        // Stub implementation
    }
    
    public func stop() async {
        // Stub implementation
    }
}

public typealias FileIngestionHandler = (String) async -> Void

public struct FileSystemWatcher {
    // Stub implementation
}

public struct FileSystemEvent {
    // Stub implementation
}

