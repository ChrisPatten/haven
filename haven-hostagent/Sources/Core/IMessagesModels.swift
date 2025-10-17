import Foundation

public enum IMessagesRunMode: String, Codable, Sendable {
    case backfill
    case tail
}

public struct IMessagesRunRequest: Codable, Sendable {
    public let mode: IMessagesRunMode
    public let batchSize: Int?
    public let maxRows: Int?

    public init(mode: IMessagesRunMode, batchSize: Int? = nil, maxRows: Int? = nil) {
        self.mode = mode
        self.batchSize = batchSize
        self.maxRows = maxRows
    }
}

public struct IMessagesRunResponse: Codable, Sendable {
    public let processed: Int
    public let attachments: Int
    public let cursorRowID: Int64
    public let headRowID: Int64
    public let durationMs: Int
    
    public init(processed: Int, attachments: Int, cursorRowID: Int64, headRowID: Int64, durationMs: Int) {
        self.processed = processed
        self.attachments = attachments
        self.cursorRowID = cursorRowID
        self.headRowID = headRowID
        self.durationMs = durationMs
    }
}

public struct IMessagesState: Codable, Sendable, StateSerializable {
    public var cursorRowID: Int64
    public var headRowID: Int64
    public var floorRowID: Int64
    public var lastRun: Date?
    public var lastError: String?

    public init(cursorRowID: Int64, headRowID: Int64, floorRowID: Int64, lastRun: Date?, lastError: String?) {
        self.cursorRowID = cursorRowID
        self.headRowID = headRowID
        self.floorRowID = floorRowID
        self.lastRun = lastRun
        self.lastError = lastError
    }

    public static let defaultValue = IMessagesState(
        cursorRowID: 0,
        headRowID: 0,
        floorRowID: 0,
        lastRun: nil,
        lastError: nil
    )
}

public struct IMessagesLogEntry: Codable, Sendable {
    public let timestamp: Date
    public let level: String
    public let message: String
    public let metadata: [String: String]
    
    public init(timestamp: Date, level: String, message: String, metadata: [String: String]) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

public protocol IMessagesService: HostAgentModule {
    func run(request: IMessagesRunRequest) async throws -> IMessagesRunResponse
    func state() async -> IMessagesState
    func logs(since interval: TimeInterval) async -> [IMessagesLogEntry]
    func updateConfiguration(_ config: HostAgentConfiguration.IMessagesConfig) async
    func updateOCRLanguages(_ languages: [String]) async
}
