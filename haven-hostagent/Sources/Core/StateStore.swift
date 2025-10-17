import Foundation
import Logging

public protocol StateSerializable: Codable, Sendable {
    static var defaultValue: Self { get }
}

public final class JSONStateStore<State: StateSerializable>: @unchecked Sendable {
    private let url: URL
    private let logger = Logger(label: "HostAgent.JSONStateStore")
    private let queue = DispatchQueue(label: "hostagent.state.\(State.self)")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = .prettyPrinted
    }

    public func load() -> State {
        queue.sync {
            do {
                let data = try Data(contentsOf: url)
                return try decoder.decode(State.self, from: data)
            } catch {
                logger.warning("Falling back to default state", metadata: ["error": "\(error)"])
                return State.defaultValue
            }
        }
    }

    public func save(_ state: State) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try self.encoder.encode(state)
                try data.write(to: self.url, options: .atomic)
            } catch {
                self.logger.error("Failed to persist state", metadata: ["error": "\(error)"])
            }
        }
    }
}
