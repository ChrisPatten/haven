import Foundation

public struct OCRRequest: Sendable {
    public enum Payload: Sendable {
        case fileURL(URL)
        case data(Data, filename: String?)
    }

    public let payload: Payload
    public let languages: [String]
    public let timeout: TimeInterval

    public init(payload: Payload, languages: [String], timeout: TimeInterval) {
        self.payload = payload
        self.languages = languages
        self.timeout = timeout
    }
}

public struct OCRBox: Codable, Sendable {
    public let text: String
    public let bbox: [Double]
    public let level: String

    public init(text: String, bbox: [Double], level: String) {
        self.text = text
        self.bbox = bbox
        self.level = level
    }
}

public struct OCRResponseBody: Codable, Sendable {
    public let ocrText: String
    public let ocrBoxes: [OCRBox]
    public let lang: String
    public let tooling: [String: String]
    public let timingsMs: [String: Int]
    public let error: String?

    public init(
        ocrText: String,
        ocrBoxes: [OCRBox],
        lang: String,
        tooling: [String: String],
        timingsMs: [String: Int],
        error: String?
    ) {
        self.ocrText = ocrText
        self.ocrBoxes = ocrBoxes
        self.lang = lang
        self.tooling = tooling
        self.timingsMs = timingsMs
        self.error = error
    }
}

public protocol OCRService: HostAgentModule {
    func performOCR(payload: OCRRequest.Payload, preferredLanguages: [String], timeout: TimeInterval) async throws -> OCRResponseBody
    func health() async -> [String: String]
    func updateConfiguration(_ config: HostAgentConfiguration.OCRConfig) async
}
