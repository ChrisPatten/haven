import Foundation

/// Image dimensions
public struct ImageDimensions: Codable, Sendable {
    public let width: Int
    public let height: Int
    
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Image attachment metadata (file not retained, only metadata)
public struct ImageAttachment: Codable, Sendable {
    public let hash: String  // SHA-256 hash of image
    public let mimeType: String
    public let dimensions: ImageDimensions?
    public let extractedAt: Date
    public let filename: String?
    public let size: Int64?
    
    // Temporary storage for enrichment (not persisted)
    // In practice, this would be loaded from source when needed
    public var temporaryPath: String?
    public var temporaryData: Data?
    
    public init(
        hash: String,
        mimeType: String,
        dimensions: ImageDimensions? = nil,
        extractedAt: Date = Date(),
        filename: String? = nil,
        size: Int64? = nil,
        temporaryPath: String? = nil,
        temporaryData: Data? = nil
    ) {
        self.hash = hash
        self.mimeType = mimeType
        self.dimensions = dimensions
        self.extractedAt = extractedAt
        self.filename = filename
        self.size = size
        self.temporaryPath = temporaryPath
        self.temporaryData = temporaryData
    }
}

