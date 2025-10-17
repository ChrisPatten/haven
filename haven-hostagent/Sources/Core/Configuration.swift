import Foundation
import Yams

public struct HostAgentConfiguration: Codable, Sendable {
    public struct Auth: Sendable, Codable {
        public var header: String
        public var secret: String

        public init(header: String = "x-auth", secret: String = "change-me") {
            self.header = header
            self.secret = secret
        }
    }

    public struct Gateway: Sendable, Codable {
        public var baseURL: URL
        public var ingestPath: String

        public init(baseURL: URL = URL(string: "http://gateway:8080")!, ingestPath: String = "/v1/ingest") {
            self.baseURL = baseURL
            self.ingestPath = ingestPath
        }
    }

    public struct ModuleToggle<T: Codable & Sendable>: Codable, Sendable {
        public var enabled: Bool
        public var config: T

        public init(enabled: Bool, config: T) {
            self.enabled = enabled
            self.config = config
        }
    }

    public struct IMessagesConfig: Codable, Sendable {
        public var batchSize: Int
        public var ocrEnabled: Bool
        public var timeoutSeconds: Int
        public var backfillMaxRows: Int?

        public init(
            batchSize: Int = 500,
            ocrEnabled: Bool = true,
            timeoutSeconds: Int = 30,
            backfillMaxRows: Int? = nil
        ) {
            self.batchSize = batchSize
            self.ocrEnabled = ocrEnabled
            self.timeoutSeconds = timeoutSeconds
            self.backfillMaxRows = backfillMaxRows
        }
    }

    public struct OCRConfig: Codable, Sendable {
        public var languages: [String]
        public var timeoutMilliseconds: Int

        public init(languages: [String] = ["en"], timeoutMilliseconds: Int = 2_000) {
            self.languages = languages
            self.timeoutMilliseconds = timeoutMilliseconds
        }
    }

    public struct FSWatchConfig: Codable, Sendable {
        public struct WatchDescriptor: Codable, Sendable, Identifiable {
            public var id: String
            public var path: String
            public var glob: String
            public var target: String
            public var handoff: String

            public init(
                id: String,
                path: String,
                glob: String,
                target: String,
                handoff: String
            ) {
                self.id = id
                self.path = path
                self.glob = glob
                self.target = target
                self.handoff = handoff
            }
        }

        public var watches: [WatchDescriptor]

        public init(watches: [WatchDescriptor] = []) {
            self.watches = watches
        }
    }

    public let port: Int
    public let auth: Auth
    public let gateway: Gateway
    public var modules: Modules

    public struct Modules: Codable, Sendable {
        public var imessage: ModuleToggle<IMessagesConfig>
        public var ocr: ModuleToggle<OCRConfig>
        public var fswatch: ModuleToggle<FSWatchConfig>
        public var contacts: ModuleToggle<EmptyToggle>
        public var calendar: ModuleToggle<EmptyToggle>
        public var reminders: ModuleToggle<EmptyToggle>
        public var mail: ModuleToggle<EmptyToggle>
        public var notes: ModuleToggle<EmptyToggle>
        public var faces: ModuleToggle<EmptyToggle>

        public init(
            imessage: ModuleToggle<IMessagesConfig> = .init(enabled: true, config: IMessagesConfig()),
            ocr: ModuleToggle<OCRConfig> = .init(enabled: true, config: OCRConfig()),
            fswatch: ModuleToggle<FSWatchConfig> = .init(enabled: false, config: FSWatchConfig()),
            contacts: ModuleToggle<EmptyToggle> = .init(enabled: false, config: EmptyToggle()),
            calendar: ModuleToggle<EmptyToggle> = .init(enabled: false, config: EmptyToggle()),
            reminders: ModuleToggle<EmptyToggle> = .init(enabled: false, config: EmptyToggle()),
            mail: ModuleToggle<EmptyToggle> = .init(enabled: false, config: EmptyToggle()),
            notes: ModuleToggle<EmptyToggle> = .init(enabled: false, config: EmptyToggle()),
            faces: ModuleToggle<EmptyToggle> = .init(enabled: false, config: EmptyToggle())
        ) {
            self.imessage = imessage
            self.ocr = ocr
            self.fswatch = fswatch
            self.contacts = contacts
            self.calendar = calendar
            self.reminders = reminders
            self.mail = mail
            self.notes = notes
            self.faces = faces
        }
    }

    public struct EmptyToggle: Codable, Sendable {
        public init() {}
    }

    public init(
        port: Int = 7090,
        auth: Auth = Auth(),
        gateway: Gateway = Gateway(),
        modules: Modules = Modules()
    ) {
        self.port = port
        self.auth = auth
        self.gateway = gateway
        self.modules = modules
    }
}

public enum ConfigurationLoader {
    public static let defaultConfigPath = NSString(string: "~/.haven/hostagent.yaml").expandingTildeInPath

    public static func load(from path: String? = nil) throws -> HostAgentConfiguration {
        let effectivePath = path ?? defaultConfigPath
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: effectivePath) {
            try ensureDirectory(for: effectivePath)
            let defaults = HostAgentConfiguration()
            let encoder = YAMLEncoder()
            let yaml = try encoder.encode(defaults, userInfo: [:])
            try yaml.write(toFile: effectivePath, atomically: true, encoding: String.Encoding.utf8)
            return defaults
        }

        let yaml = try String(contentsOfFile: effectivePath, encoding: String.Encoding.utf8)
        let decoder = YAMLDecoder()
        let fileConfig = try decoder.decode(HostAgentConfiguration.self, from: yaml)
        return applyEnvironmentOverrides(config: fileConfig)
    }

    public static func save(_ config: HostAgentConfiguration, to path: String? = nil) throws {
        let effectivePath = path ?? defaultConfigPath
        try ensureDirectory(for: effectivePath)
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config, userInfo: [:])
        try yaml.write(toFile: effectivePath, atomically: true, encoding: String.Encoding.utf8)
    }

    private static func ensureDirectory(for filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func applyEnvironmentOverrides(config: HostAgentConfiguration) -> HostAgentConfiguration {
        var updated = config
        if let portEnv = ProcessInfo.processInfo.environment["HOST_AGENT_PORT"], let port = Int(portEnv) {
            updated = HostAgentConfiguration(
                port: port,
                auth: updated.auth,
                gateway: updated.gateway,
                modules: updated.modules
            )
        }

        if let secretEnv = ProcessInfo.processInfo.environment["HOST_AGENT_AUTH"] {
            var auth = updated.auth
            auth.secret = secretEnv
            updated = HostAgentConfiguration(
                port: updated.port,
                auth: auth,
                gateway: updated.gateway,
                modules: updated.modules
            )
        }

        if let baseUrlEnv = ProcessInfo.processInfo.environment["HOST_AGENT_BASE_URL"], let url = URL(string: baseUrlEnv) {
            var gateway = updated.gateway
            gateway = HostAgentConfiguration.Gateway(baseURL: url, ingestPath: gateway.ingestPath)
            updated = HostAgentConfiguration(
                port: updated.port,
                auth: updated.auth,
                gateway: gateway,
                modules: updated.modules
            )
        }

        return updated
    }
}
