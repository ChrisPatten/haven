import Core
import Foundation
import Logging

public actor FSWatchModule: FSWatchService {
    public let kind: ModuleKind = .fswatch
    public let logger = Logger(label: "HostAgent.FSWatch")

    private var configuration: HostAgentConfiguration.FSWatchConfig
    private let gateway: GatewayTransport
    private var watches: [String: DirectoryWatch] = [:]
    private let queue = DispatchQueue(label: "hostagent.fswatch", qos: .utility)

    public init(configuration: HostAgentConfiguration.FSWatchConfig, gateway: GatewayTransport) {
        self.configuration = configuration
        self.gateway = gateway
    }

    public func boot(context: ModuleContext) async throws {
        guard configuration.watches.isEmpty == false else { return }
        for watchConfig in configuration.watches {
            _ = try await registerWatchInternal(id: watchConfig.id, request: .init(path: watchConfig.path, glob: watchConfig.glob, target: watchConfig.target, handoff: watchConfig.handoff))
        }
    }

    public func shutdown() async {
        for (_, watch) in watches {
            watch.stop()
        }
        watches.removeAll()
    }

    public func summary() async -> ModuleSummary {
        ModuleSummary(
            kind: kind,
            enabled: true,
            status: "active",
            extra: ["watch_count": "\(watches.count)"]
        )
    }

    public func registerWatch(_ request: FileWatchRegistrationRequest) async throws -> FileWatchInfo {
        let id = Hashing.sha256Hex("\(request.path)|\(request.glob)|\(UUID().uuidString)").prefix(12)
        let info = try await registerWatchInternal(id: String(id), request: request)
        return info
    }

    private func registerWatchInternal(id: String, request: FileWatchRegistrationRequest) async throws -> FileWatchInfo {
        let info = FileWatchInfo(
            id: id,
            path: request.path,
            glob: request.glob,
            target: request.target,
            handoff: request.handoff,
            createdAt: Date()
        )

        let watch = DirectoryWatch(
            id: id,
            path: request.path,
            glob: request.glob,
            target: request.target,
            handoff: request.handoff,
            queue: queue
        ) { @Sendable [weak self] fileURL in
            Task { @MainActor in
                await self?.handleFile(url: fileURL, watchID: id, request: request)
            }
        }
        try watch.start()
        watches[id] = watch
        return info
    }

    public func listWatches() async -> [FileWatchInfo] {
        watches.values.map { watch in
            FileWatchInfo(
                id: watch.id,
                path: watch.path,
                glob: watch.glob,
                target: watch.target,
                handoff: watch.handoff,
                createdAt: watch.createdAt
            )
        }
    }

    public func removeWatch(id: String) async throws {
        guard let watch = watches.removeValue(forKey: id) else { return }
        watch.stop()
    }

    public func updateConfiguration(_ config: HostAgentConfiguration.FSWatchConfig) async {
        configuration = config
        let desired = Set(config.watches.map { $0.id })
        for (id, watch) in watches where !desired.contains(id) {
            watch.stop()
            watches.removeValue(forKey: id)
        }
        for descriptor in config.watches where watches[descriptor.id] == nil {
            let request = FileWatchRegistrationRequest(path: descriptor.path, glob: descriptor.glob, target: descriptor.target, handoff: descriptor.handoff)
            do {
                _ = try await registerWatchInternal(id: descriptor.id, request: request)
            } catch {
                logger.error("Failed to start watch", metadata: ["id": "\(descriptor.id)", "error": "\(error)"])
            }
        }
    }

    private func handleFile(url: URL, watchID: String, request: FileWatchRegistrationRequest) async {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? Int64 else { return }
            let modifiedAt = (attributes[.modificationDate] as? Date) ?? Date()
            let data = try Data(contentsOf: url)
            let sha = Hashing.sha256Hex(data: data)
            let presigned = try await gateway.requestPresignedPut(path: url.path, sha256: sha, size: size)
            try await gateway.upload(fileData: data, to: presigned)
            let event = FileIngestEvent(
                id: "\(watchID):\(sha)",
                path: url.path,
                sha256: sha,
                size: size,
                modifiedAt: modifiedAt
            )
            try await gateway.notifyFileIngested(event)
            logger.info("File handed off", metadata: ["path": "\(url.path)", "sha": "\(sha.prefix(8))"])
        } catch {
            logger.error("Failed to hand off file", metadata: ["path": "\(url.path)", "error": "\(error)"])
        }
    }
}
