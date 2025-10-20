import Foundation
import ArgumentParser
import HavenCore
import HostHTTP
import Face
import FSWatch

@main
struct HavenHostAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hostagent",
        abstract: "Haven Host Agent - localhost HTTP API for macOS capabilities",
        version: "1.0.0"
    )
    
    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String?
    
    func run() async throws {
        printBanner()
        
        // Load configuration
        let configLoader = ConfigLoader()
        let config = try configLoader.load(from: self.config)
        let logger = HavenLogger(category: "main")

        logger.info("Configuration loaded", metadata: [
            "port": config.port,
            "auth_header": config.auth.header,
            "gateway_url": config.gateway.baseUrl
        ])
        logger.info("Beginning hostagent initialization")
        
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

        // Handle shutdown gracefully
        let signalSource = setupSignalHandlers()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Start server
                group.addTask {
                    do {
                        logger.info("server.start() task beginning")
                        try await server.start()
                        logger.info("server.start() returned (server stopped)")
                    } catch {
                        logger.error("server.start() task threw an error", metadata: ["error": "\(error)"])
                        throw error
                    }
                }

                // Wait for signal
                group.addTask {
                    logger.info("Waiting for shutdown signal...")
                    await signalSource.wait()
                    logger.info("Shutdown signal received, stopping server...")

                    // Stop services
                    await fsWatchService.stop()

                    do {
                        try await server.stop()
                        logger.info("Server stopped cleanly")
                    } catch {
                        logger.error("Error while stopping server", metadata: ["error": "\(error)"])
                    }
                }

                // Wait for first task to complete
                _ = try await group.next()
                logger.info("A task completed, cancelling remaining tasks")
                group.cancelAll()
            }
        } catch {
            logger.error("Unhandled error in task group", metadata: ["error": "\(error)"])
            throw error
        }

        logger.info("Haven Host Agent stopped")
    }
    
    private func printBanner() {
        print("╔════════════════════════════════════════════════╗")
        print("║     🏠 Haven Host Agent v1.0.0                 ║")
        print("║     Native macOS capabilities API              ║")
        print("╚════════════════════════════════════════════════╝")
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

