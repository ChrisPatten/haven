import Foundation

public struct FileWatchRegistrationRequest: Codable, Sendable {
    public let path: String
    public let glob: String
    public let target: String
    public let handoff: String

    public init(path: String, glob: String, target: String, handoff: String) {
        self.path = path
        self.glob = glob
        self.target = target
        self.handoff = handoff
    }
}

public struct FileWatchInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let glob: String
    public let target: String
    public let handoff: String
    public let createdAt: Date

    public init(id: String, path: String, glob: String, target: String, handoff: String, createdAt: Date) {
        self.id = id
        self.path = path
        self.glob = glob
        self.target = target
        self.handoff = handoff
        self.createdAt = createdAt
    }
}

public protocol FSWatchService: HostAgentModule {
    func registerWatch(_ request: FileWatchRegistrationRequest) async throws -> FileWatchInfo
    func listWatches() async -> [FileWatchInfo]
    func removeWatch(id: String) async throws
    func updateConfiguration(_ config: HostAgentConfiguration.FSWatchConfig) async
}
