import Logging

public actor LoggingSystemBootstrapper {
    public static let shared = LoggingSystemBootstrapper()
    private var isBootstrapped = false

    public func bootstrap(level: Logger.Level = .info) {
        guard !isBootstrapped else { return }
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }
        isBootstrapped = true
    }
}
