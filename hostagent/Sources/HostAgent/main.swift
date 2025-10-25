import Foundation
import ArgumentParser
import HavenCore
import HostHTTP
import HostAgentEmail
import Face
import FSWatch

@main
struct HavenHostAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hostagent",
        abstract: "Haven Host Agent - localhost HTTP API for macOS capabilities",
        version: BuildInfo.versionWithBuildID
    )
    
    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String?
    
    func run() async throws {
        printBanner()
        // Respect environment override for logging level early (before config load)
        if let envLevel = ProcessInfo.processInfo.environment["HAVEN_LOG_LEVEL"] {
            HavenLogger.setMinimumLevel(envLevel)
        }
        // Respect environment override for logging format early
        if let envFormat = ProcessInfo.processInfo.environment["HAVEN_LOG_FORMAT"] {
            HavenLogger.setOutputFormat(envFormat)
        }
        // Load configuration
        let configLoader = ConfigLoader()
        let config = try configLoader.load(from: self.config)
    // Apply configured minimum level from file (overrides env)
    HavenLogger.setMinimumLevel(config.logging.level)
    // Apply configured output format from file (overrides env)
    HavenLogger.setOutputFormat(config.logging.format)
        let logger = HavenLogger(category: "main")

        logger.info("Configuration loaded", metadata: [
            "port": config.port,
            "auth_header": config.auth.header,
            "gateway_url": config.gateway.baseUrl
        ])
        logger.info("Beginning hostagent initialization")
    print("[hostagent] initialization: starting (pid:\(ProcessInfo.processInfo.processIdentifier))")
        
        // Initialize services
        let fsWatchService = FSWatchService(
            config: config.modules.fswatch,
            maxQueueSize: config.modules.fswatch.eventQueueSize
        )

        // Start FSWatch if enabled
        if config.modules.fswatch.enabled {
            logger.info("FSWatch enabled in config; starting service...")
            do {
                try await fsWatchService.start()
                logger.info("FSWatch service started successfully")
            } catch {
                logger.error("FSWatch failed to start", metadata: ["error": "\(error)"])
                // Continue startup even if FSWatch fails to start; allow server to come up
            }
        } else {
            logger.info("FSWatch disabled in configuration; skipping start")
        }
        
        // Build router with handlers
        let router = buildRouter(config: config, configLoader: configLoader, fsWatchService: fsWatchService)
        
        // Create and start server
        let server = try HavenHTTPServer(config: config, router: router)

        logger.info("Server created; preparing to start")
    print("[hostagent] server instance created; preparing to start")

        // Handle shutdown gracefully
    let signalSource = setupSignalHandlers()
    print("[hostagent] signal handlers registered")

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Start server
                group.addTask {
                    do {
                        logger.info("server.start() task beginning")
                        print("[hostagent] server.start() task beginning")
                        try await server.start()
                        logger.info("server.start() returned (server stopped)")
                        print("[hostagent] server.start() returned (server stopped)")
                    } catch {
                        logger.error("server.start() task threw an error", metadata: ["error": "\(error)"])
                        print("[hostagent] server.start() task threw an error: \(error)")
                        throw error
                    }
                }

                // Wait for signal
                group.addTask {
                    logger.info("Waiting for shutdown signal...")
                    print("[hostagent] waiting for shutdown signal...")
                    await signalSource.wait()
                    logger.info("Shutdown signal received, stopping server...")
                    print("[hostagent] shutdown signal received, stopping server...")

                    // Stop services
                    await fsWatchService.stop()

                    do {
                        try await server.stop()
                        logger.info("Server stopped cleanly")
                        print("[hostagent] server stopped cleanly")
                    } catch {
                        logger.error("Error while stopping server", metadata: ["error": "\(error)"])
                        print("[hostagent] error while stopping server: \(error)")
                    }
                }

                // Wait for first task to complete
                logger.info("Waiting for first task to complete in group")
                print("[hostagent] awaiting first task completion in task group...")
                if let _ = try await group.next() {
                    logger.info("A task completed (group.next returned non-nil)")
                    print("[hostagent] a task completed; cancelling remaining tasks")
                } else {
                    logger.info("Task group completed with no tasks")
                    print("[hostagent] task group next returned nil (no tasks)")
                }

                group.cancelAll()
            }
        } catch {
            logger.error("Unhandled error in task group", metadata: ["error": "\(error)"])
            print("[hostagent] unhandled error in task group: \(error)")
            throw error
        }

        logger.info("Haven Host Agent stopped")
    }
    
    private func printBanner() {
        // Build dynamic banner width based on longest line content
        let versionLineContent = "🏠 Haven Host Agent v" + BuildInfo.versionWithBuildID
        let secondaryLineContent = "Native macOS capabilities API"
        let paddingLeft = 3 // spaces after leading border before content
        let lines = [versionLineContent, secondaryLineContent]

        // Approximate display width: count ASCII as 1, wide emoji/CJK as 2
        func displayWidth(of s: String) -> Int {
            var w = 0
            for ch in s {
                // Basic heuristic: treat characters outside ASCII range as width 2
                if ch.unicodeScalars.allSatisfy({ $0.value < 128 }) {
                    w += 1
                } else {
                    w += 2
                }
            }
            return w
        }

        let maxContentWidth = lines.map { displayWidth(of: $0) }.max() ?? 0
        let innerWidth = paddingLeft + maxContentWidth + 1 // +1 trailing space before border
        let topBorder = "╔" + String(repeating: "═", count: innerWidth) + "╗"
        let bottomBorder = "╚" + String(repeating: "═", count: innerWidth) + "╝"
        print(topBorder)
        // Print each content line with padding, using displayWidth for calculations
        for content in lines {
            let contentDisplayWidth = displayWidth(of: content)
            let padCount = maxContentWidth - contentDisplayWidth
            let padded = content + String(repeating: " ", count: padCount)
            print("║" + String(repeating: " ", count: paddingLeft) + padded + " ║")
        }
        print(bottomBorder)
        print("")
    }
    
    private func buildRouter(config: HavenConfig, configLoader: ConfigLoader, fsWatchService: FSWatchService) -> Router {
        let startTime = Date()
        
        let healthHandler = HealthHandler(config: config, startTime: startTime)
        let capabilitiesHandler = CapabilitiesHandler(config: config)
        let metricsHandler = MetricsHandler()
        let modulesHandler = ModulesHandler(config: config, configLoader: configLoader)
        let ocrHandler = OCRHandler(config: config)
        let entityHandler = EntityHandler(config: config)
        
        // Initialize face service and handler
        let faceService = FaceService(
            minFaceSize: config.modules.face.minFaceSize,
            minConfidence: config.modules.face.minConfidence,
            includeLandmarks: config.modules.face.includeLandmarks
        )
        let faceHandler = FaceHandler(faceService: faceService, config: config.modules.face)
        
        // Initialize FSWatch handler
        let fsWatchHandler = FSWatchHandler(fsWatchService: fsWatchService, config: config.modules.fswatch)
        
        // Initialize gateway client for iMessage handler
        let gatewayClient = GatewayClient(config: config.gateway, authToken: config.auth.secret)
        let iMessageHandler = IMessageHandler(config: config, gatewayClient: gatewayClient)
        
        // Initialize email handlers
        let emailHandler = EmailHandler(config: config)
        let emailIndexedCollector = EmailIndexedCollector()
        let emailLocalHandler = EmailLocalHandler(config: config, indexedCollector: emailIndexedCollector)
        let emailImapHandler = EmailImapHandler(config: config)
        
        let handlers: [RouteHandler] = [
            // Core endpoints
            PatternRouteHandler(method: "GET", pattern: "/v1/health") { req, ctx in
                await healthHandler.handle(request: req, context: ctx)
            },
            PatternRouteHandler(method: "GET", pattern: "/v1/capabilities") { req, ctx in
                await capabilitiesHandler.handle(request: req, context: ctx)
            },
            PatternRouteHandler(method: "GET", pattern: "/v1/metrics") { req, ctx in
                await metricsHandler.handle(request: req, context: ctx)
            },
            PatternRouteHandler(method: "GET", pattern: "/v1/modules") { req, ctx in
                await modulesHandler.handleList(request: req, context: ctx)
            },
            
            // OCR endpoint
            PatternRouteHandler(method: "POST", pattern: "/v1/ocr") { req, ctx in
                await ocrHandler.handle(request: req, context: ctx)
            },
            
            // Entity extraction endpoint
            PatternRouteHandler(method: "POST", pattern: "/v1/entities") { req, ctx in
                await entityHandler.handle(request: req, context: ctx)
            },
            
            // Face detection endpoint
            PatternRouteHandler(method: "POST", pattern: "/v1/face/detect") { req, ctx in
                await faceHandler.handle(request: req)
            },
            
            // FSWatch endpoints
            PatternRouteHandler(method: "GET", pattern: "/v1/fs-watches/events") { req, ctx in
                await fsWatchHandler.handlePollEvents(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/fs-watches/events:clear") { req, ctx in
                await fsWatchHandler.handleClearEvents(request: req, context: ctx)
            },
            PatternRouteHandler(method: "GET", pattern: "/v1/fs-watches") { req, ctx in
                await fsWatchHandler.handleListWatches(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/fs-watches") { req, ctx in
                await fsWatchHandler.handleAddWatch(request: req, context: ctx)
            },
            PatternRouteHandler(method: "DELETE", pattern: "/v1/fs-watches/*") { req, ctx in
                await fsWatchHandler.handleRemoveWatch(request: req, context: ctx)
            },
            
            // TODO: Add more handlers
            // - POST /v1/collectors/imessage:run (IMessageHandler)
            // - GET /v1/collectors/imessage/state (IMessageHandler)
            // Generic collector run router: validates request JSON strictly and dispatches to adapters
            PatternRouteHandler(method: "POST", pattern: "/v1/collectors/*") { req, ctx in
                let dispatch: [String: (HTTPRequest, RequestContext) async -> HTTPResponse] = [
                    "imessage": { r, c in await iMessageHandler.handleRun(request: r, context: c) },
                    "email_local": { r, c in await emailLocalHandler.handleRun(request: r, context: c) },
                    "email_imap": { r, c in await emailImapHandler.handleRun(request: r, context: c) }
                ]

                return await RunRouter.handle(request: req, context: ctx, dispatchMap: dispatch)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/collectors/imessage:run") { req, ctx in
                await iMessageHandler.handleRun(request: req, context: ctx)
            },
            PatternRouteHandler(method: "GET", pattern: "/v1/collectors/imessage/state") { req, ctx in
                await iMessageHandler.handleState(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/collectors/email_local:run") { req, ctx in
                await emailLocalHandler.handleRun(request: req, context: ctx)
            },
            PatternRouteHandler(method: "GET", pattern: "/v1/collectors/email_local/state") { req, ctx in
                await emailLocalHandler.handleState(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/collectors/email_imap:run") { req, ctx in
                await emailImapHandler.handleRun(request: req, context: ctx)
            },
            
            // Email utility endpoints
            PatternRouteHandler(method: "POST", pattern: "/v1/email/parse") { req, ctx in
                await emailHandler.handleParse(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/email/metadata") { req, ctx in
                await emailHandler.handleMetadata(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/email/classify-intent") { req, ctx in
                await emailHandler.handleClassifyIntent(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/email/redact-pii") { req, ctx in
                await emailHandler.handleRedactPII(request: req, context: ctx)
            },
            PatternRouteHandler(method: "POST", pattern: "/v1/email/is-noise") { req, ctx in
                await emailHandler.handleIsNoise(request: req, context: ctx)
            },
        ]
        
        return Router(handlers: handlers)
    }
    
    private func setupSignalHandlers() -> SignalWaiter {
        return SignalWaiter.shared
    }
}

/// Handles shutdown signals using DispatchSource
final class SignalWaiter: @unchecked Sendable {
    static let shared = SignalWaiter()
    
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    
    private init() {
        // Set up signal sources
        setupSignalSource(for: SIGINT)
        setupSignalSource(for: SIGTERM)
    }
    
    private func setupSignalSource(for sig: Int32) {
        // Ignore the signal in the default handler to prevent termination
        Darwin.signal(sig, SIG_IGN)
        
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { [weak self] in
            self?.triggerShutdown()
        }
        source.resume()
        signalSources.append(source)
    }
    
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }
    
    private func triggerShutdown() {
        lock.lock()
        continuation?.resume()
        continuation = nil
        lock.unlock()
    }
}
