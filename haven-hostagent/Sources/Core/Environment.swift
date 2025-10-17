import Foundation

public enum HostAgentPaths {
    public static let applicationSupportBase: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent("Haven/hostagent", isDirectory: true)
    }()

    public static let logsDirectory: URL = applicationSupportBase.appendingPathComponent("logs", isDirectory: true)
    public static let stateDirectory: URL = applicationSupportBase.appendingPathComponent("state", isDirectory: true)
    public static let tmpDirectory: URL = applicationSupportBase.appendingPathComponent("tmp", isDirectory: true)
    public static let imessageStatePath: URL = stateDirectory.appendingPathComponent("imessage_state.json")

    public static func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationSupportBase, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
    }
}
