import Foundation
import Logging

public enum ModuleKind: String, Codable, Sendable, CaseIterable {
    case imessage
    case ocr
    case fswatch
    case contacts
    case calendar
    case reminders
    case mail
    case notes
    case faces
}

public protocol HostAgentModule: AnyObject, Sendable {
    var kind: ModuleKind { get }
    var logger: Logger { get }
    func boot(context: ModuleContext) async throws
    func shutdown() async
    func summary() async -> ModuleSummary
}

public struct ModuleContext: Sendable {
    public let configuration: HostAgentConfiguration
    public let moduleConfigPath: String?
    public let stateDirectory: URL
    public let tmpDirectory: URL
    public let gatewayClient: GatewayTransport

    public init(
        configuration: HostAgentConfiguration,
        moduleConfigPath: String?,
        stateDirectory: URL,
        tmpDirectory: URL,
        gatewayClient: GatewayTransport
    ) {
        self.configuration = configuration
        self.moduleConfigPath = moduleConfigPath
        self.stateDirectory = stateDirectory
        self.tmpDirectory = tmpDirectory
        self.gatewayClient = gatewayClient
    }
}

public struct ModuleSummary: Codable, Sendable {
    public var kind: ModuleKind
    public var enabled: Bool
    public var status: String
    public var lastError: String?
    public var extra: [String: String]

    public init(kind: ModuleKind, enabled: Bool, status: String, lastError: String? = nil, extra: [String: String] = [:]) {
        self.kind = kind
        self.enabled = enabled
        self.status = status
        self.lastError = lastError
        self.extra = extra
    }
}

@MainActor
public final class ModuleManager {
    private let logger = Logger(label: "HostAgent.ModuleManager")
    private var modules: [ModuleKind: HostAgentModule] = [:]
    private var config: HostAgentConfiguration
    private let stateDirectory: URL
    private let tmpDirectory: URL
    private let gatewayClient: GatewayTransport
    private let configPath: String?
    private var running: Set<ModuleKind> = []

    public init(
        configuration: HostAgentConfiguration,
        configPath: String?,
        stateDirectory: URL,
        tmpDirectory: URL,
        gatewayClient: GatewayTransport
    ) {
        self.config = configuration
        self.stateDirectory = stateDirectory
        self.tmpDirectory = tmpDirectory
        self.gatewayClient = gatewayClient
        self.configPath = configPath
    }

    public func register(_ module: HostAgentModule) {
        modules[module.kind] = module
    }

    public func bootModules() async {
        for (kind, module) in modules where isEnabled(kind: kind) {
            do {
                try await module.boot(context: context)
                running.insert(kind)
                logger.info("Module booted", metadata: ["module": "\(kind.rawValue)"])
            } catch {
                logger.error("Failed to boot module \(kind.rawValue): \(error)")
            }
        }
    }

    public func shutdown() async {
        for module in modules.values {
            await module.shutdown()
        }
        running.removeAll()
    }

    public func summaries() async -> [ModuleSummary] {
        var results: [ModuleSummary] = []
        for (kind, module) in modules {
            var summary = await module.summary()
            summary.enabled = isEnabled(kind: kind)
            results.append(summary)
        }
        return results.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    public func summary(for kind: ModuleKind) async -> ModuleSummary? {
        guard let module = modules[kind] else { return nil }
        var summary = await module.summary()
        summary.enabled = isEnabled(kind: kind)
        return summary
    }

    public func updateConfiguration(_ transform: @Sendable (inout HostAgentConfiguration) -> Void) async throws {
        transform(&config)
        try ConfigurationLoader.save(config, to: configPath)
    }

    public func configuration() -> HostAgentConfiguration {
        config
    }

    public func applyModuleState(kind: ModuleKind, enabled: Bool) async {
        guard let module = modules[kind] else { return }
        let isRunning = running.contains(kind)
        if enabled, !isRunning {
            do {
                try await module.boot(context: context)
                running.insert(kind)
                logger.info("Module \(kind.rawValue) enabled")
            } catch {
                logger.error("Failed to enable module \(kind.rawValue)", metadata: ["error": "\(error)"])
            }
        } else if !enabled, isRunning {
            await module.shutdown()
            running.remove(kind)
            logger.info("Module \(kind.rawValue) disabled")
        }
    }

    private func isEnabled(kind: ModuleKind) -> Bool {
        switch kind {
        case .imessage:
            return config.modules.imessage.enabled
        case .ocr:
            return config.modules.ocr.enabled
        case .fswatch:
            return config.modules.fswatch.enabled
        case .contacts:
            return config.modules.contacts.enabled
        case .calendar:
            return config.modules.calendar.enabled
        case .reminders:
            return config.modules.reminders.enabled
        case .mail:
            return config.modules.mail.enabled
        case .notes:
            return config.modules.notes.enabled
        case .faces:
            return config.modules.faces.enabled
        }
    }

    private var context: ModuleContext {
        ModuleContext(
            configuration: config,
            moduleConfigPath: configPath,
            stateDirectory: stateDirectory,
            tmpDirectory: tmpDirectory,
            gatewayClient: gatewayClient
        )
    }

}
