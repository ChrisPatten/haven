import Core
import FSWatch
import HostHTTP
import IMessages
import OCR
import Foundation
import Logging
import NIO

@main
struct HostAgentMain {
    static func main() async {
        await LoggingSystemBootstrapper.shared.bootstrap(level: .info)

        do {
            let configPath = ConfigurationLoader.defaultConfigPath
            let configuration = try ConfigurationLoader.load(from: configPath)
            try HostAgentPaths.prepare()
            let gatewayClient = GatewayClient(configuration: configuration)

            let moduleManager = ModuleManager(
                configuration: configuration,
                configPath: configPath,
                stateDirectory: HostAgentPaths.stateDirectory,
                tmpDirectory: HostAgentPaths.tmpDirectory,
                gatewayClient: gatewayClient
            )

            let ocrModule = OCRModule(configuration: configuration.modules.ocr.config)
            moduleManager.register(ocrModule)

            let imessagesModule = IMessagesModule(
                configuration: configuration.modules.imessage.config,
                ocr: ocrModule,
                gateway: gatewayClient,
                stateURL: HostAgentPaths.imessageStatePath,
                ocrLanguages: configuration.modules.ocr.config.languages
            )
            moduleManager.register(imessagesModule)

            let fsWatchModule = FSWatchModule(
                configuration: configuration.modules.fswatch.config,
                gateway: gatewayClient
            )
            moduleManager.register(fsWatchModule)

            await moduleManager.bootModules()

            let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            let router = HostHTTPRouter(
                moduleManager: moduleManager,
                imessages: imessagesModule,
                ocr: ocrModule,
                fswatch: fsWatchModule,
                authHeader: configuration.auth.header,
                authSecret: configuration.auth.secret
            )

            let server = HostHTTPServer(group: group, router: router)
            try await server.start(on: configuration.port)

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

            let shutdown = {
                Task {
                    await moduleManager.shutdown()
                    try? await server.shutdown()
                    exit(EXIT_SUCCESS)
                }
                return ()
            }
            signalSource.setEventHandler(handler: shutdown)
            interruptSource.setEventHandler(handler: shutdown)
            signalSource.resume()
            interruptSource.resume()

            // Keep the task alive
            try await Task.sleep(for: .seconds(Int.max))
        } catch {
            let logger = Logger(label: "HostAgentMain")
            logger.critical("Host agent failed to start", metadata: ["error": "\(error)"])
            exit(EXIT_FAILURE)
        }
    }
}
