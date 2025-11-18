import Foundation
import HavenCore  // For ImageAttachment and ImageDimensions
import OCR
import Face
import Entity

/// Content type for documents
public enum DocumentContentType: String, Codable, Sendable {
    case email
    case imessage
    case localfs
    case contact
}

/// Document metadata
public struct DocumentMetadata: Codable, Sendable {
    public let contentHash: String
    public let mimeType: String
    public let timestamp: Date?
    public let timestampType: String?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let additionalMetadata: [String: String]
    
    public init(
        contentHash: String,
        mimeType: String = "text/plain",
        timestamp: Date? = nil,
        timestampType: String? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        additionalMetadata: [String: String] = [:]
    ) {
        self.contentHash = contentHash
        self.mimeType = mimeType
        self.timestamp = timestamp
        self.timestampType = timestampType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.additionalMetadata = additionalMetadata
    }
}

/// Base document structure from collectors
public struct CollectorDocument: Sendable {
    public let content: String  // Markdown text extracted from source
    public let sourceType: String
    public let externalId: String
    public let metadata: DocumentMetadata
    public let images: [ImageAttachment]  // Array of extracted images (files not retained, only metadata)
    public let contentType: DocumentContentType
    public let title: String?
    public let canonicalUri: String?
    
    public init(
        content: String,
        sourceType: String,
        externalId: String,
        metadata: DocumentMetadata,
        images: [ImageAttachment] = [],
        contentType: DocumentContentType,
        title: String? = nil,
        canonicalUri: String? = nil
    ) {
        self.content = content
        self.sourceType = sourceType
        self.externalId = externalId
        self.metadata = metadata
        self.images = images
        self.contentType = contentType
        self.title = title
        self.canonicalUri = canonicalUri
    }
}

/// Enrichment for a single image attachment
public struct ImageEnrichment: Sendable {
    public let ocr: OCRResult?  // OCR results for this image
    public let faces: FaceDetectionResult?  // Face detection results for this image
    public let caption: String?  // Caption for this image (NOT enriched further)
    public let enrichmentTimestamp: Date
    
    public init(
        ocr: OCRResult? = nil,
        faces: FaceDetectionResult? = nil,
        caption: String? = nil,
        enrichmentTimestamp: Date = Date()
    ) {
        self.ocr = ocr
        self.faces = faces
        self.caption = caption
        self.enrichmentTimestamp = enrichmentTimestamp
    }
}

/// Enrichment for the primary document (text content)
public struct DocumentEnrichment: Sendable {
    public let entities: [Entity]?  // Entities extracted from text + OCR text from all images
    public let enrichmentTimestamp: Date
    
    public init(
        entities: [Entity]? = nil,
        enrichmentTimestamp: Date = Date()
    ) {
        self.entities = entities
        self.enrichmentTimestamp = enrichmentTimestamp
    }
}

/// Enriched document with progressive enhancements
public struct EnrichedDocument: Sendable {
    public let base: CollectorDocument
    public let documentEnrichment: DocumentEnrichment?  // Enrichment for primary document
    public let imageEnrichments: [ImageEnrichment]  // One per image, parallel to base.images array
    
    public init(
        base: CollectorDocument,
        documentEnrichment: DocumentEnrichment? = nil,
        imageEnrichments: [ImageEnrichment] = []
    ) {
        self.base = base
        self.documentEnrichment = documentEnrichment
        self.imageEnrichments = imageEnrichments
    }
}

/// Submission result
public struct SubmissionResult: Sendable {
    public let success: Bool
    public let statusCode: Int?
    public let submission: GatewaySubmissionResponse?
    public let error: String?
    public let retryable: Bool
    
    public init(
        success: Bool,
        statusCode: Int? = nil,
        submission: GatewaySubmissionResponse? = nil,
        error: String? = nil,
        retryable: Bool = false
    ) {
        self.success = success
        self.statusCode = statusCode
        self.submission = submission
        self.error = error
        self.retryable = retryable
    }
}

/// Submission statistics tracked by the submitter
public struct SubmissionStats: Sendable {
    public let submittedCount: Int  // Successfully submitted documents
    public let errorCount: Int      // Documents that failed to submit
    
    public init(submittedCount: Int, errorCount: Int) {
        self.submittedCount = submittedCount
        self.errorCount = errorCount
    }
    
    public static let zero = SubmissionStats(submittedCount: 0, errorCount: 0)
}

extension SubmissionResult {
    public static func success(submission: GatewaySubmissionResponse) -> SubmissionResult {
        SubmissionResult(success: true, statusCode: 202, submission: submission)
    }
    
    public static func failure(error: String, statusCode: Int? = nil, retryable: Bool = false) -> SubmissionResult {
        SubmissionResult(success: false, statusCode: statusCode, error: error, retryable: retryable)
    }
}
