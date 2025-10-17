import Core
import Foundation
import Logging

struct IMessagesSnapshot {
    let directory: URL
    let databaseURL: URL

    static func createTmpSnapshot(base: URL) throws -> IMessagesSnapshot {
        let logger = Logger(label: "HostAgent.IMessages.Snapshot")
        let tempDir = try FileUtils.createTemporaryDirectory(base: base, prefix: "imessage-db")
        let sourceDBPath = ProcessInfo.processInfo.environment["IMESSAGE_DB_PATH"] ?? NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
        let sourceDBURL = URL(fileURLWithPath: sourceDBPath)
        let destinationDBURL = tempDir.appendingPathComponent("chat.db")
        try FileUtils.copyIfExists(sourceDBURL, to: destinationDBURL)

        let walSource = sourceDBURL.deletingLastPathComponent().appendingPathComponent(sourceDBURL.lastPathComponent + "-wal")
        let walDestination = destinationDBURL.deletingLastPathComponent().appendingPathComponent(destinationDBURL.lastPathComponent + "-wal")
        if FileManager.default.fileExists(atPath: walSource.path) {
            try FileUtils.copyIfExists(walSource, to: walDestination)
            logger.debug("Copied WAL for snapshot")
        }

        let shmSource = sourceDBURL.deletingLastPathComponent().appendingPathComponent(sourceDBURL.lastPathComponent + "-shm")
        let shmDestination = destinationDBURL.deletingLastPathComponent().appendingPathComponent(destinationDBURL.lastPathComponent + "-shm")
        if FileManager.default.fileExists(atPath: shmSource.path) {
            try FileUtils.copyIfExists(shmSource, to: shmDestination)
            logger.debug("Copied SHM for snapshot")
        }
        return IMessagesSnapshot(directory: tempDir, databaseURL: destinationDBURL)
    }

    func cleanup() {
        FileUtils.removeIfExists(directory)
    }
}
