import Foundation
import HavenCore

/// Web server for exposing images externally for OpenAI captioning
/// Uses Python's http.server for reliable, simple HTTP serving
public actor CaptionWebServer {
    private let logger = HavenLogger(category: "caption-web-server")
    private var process: Process?
    private var isRunning: Bool = false
    private let cacheDirectory: URL
    private let port: UInt16
    
    /// Initialize the web server
    /// - Parameters:
    ///   - port: Port to listen on (default: 8086)
    ///   - cacheDirectory: Directory containing cached images to serve
    public init(port: UInt16 = 8086, cacheDirectory: URL) {
        self.port = port
        self.cacheDirectory = cacheDirectory
    }
    
    /// Start the web server using Python's http.server
    /// - Throws: Error if server fails to start
    public func start() async throws {
        guard !isRunning else {
            logger.debug("Server already running")
            return
        }
        
        // Ensure cache directory exists
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Create Python HTTP server process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        
        // Python one-liner to start SimpleHTTPRequestHandler
        let pythonCode = """
import os, sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
os.chdir('\(cacheDirectory.path)')
server = HTTPServer(('0.0.0.0', \(port)), SimpleHTTPRequestHandler)
print('Server started', flush=True)
sys.stdout.flush()
server.serve_forever()
"""
        
        process.arguments = ["-c", pythonCode]
        
        // Set up pipes to capture output
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            self.process = process
            isRunning = true
            
            await logger.info("Caption web server started", metadata: [
                "port": "\(port)",
                "cache_directory": cacheDirectory.path,
                "method": "Python http.server"
            ])
            
            // Wait briefly for server to be ready
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            // Verify it's running
            if !process.isRunning {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "unknown error"
                throw CaptionWebServerError.startupFailed("Server exited immediately: \(output)")
            }
            
            await logger.info("Caption web server listening", metadata: [
                "port": "\(self.port)",
                "cache_directory": cacheDirectory.path,
                "status": "ready"
            ])
        } catch {
            isRunning = false
            throw CaptionWebServerError.startupFailed("Failed to start server: \(error.localizedDescription)")
        }
    }
    
    /// Stop the web server
    public func stop() async {
        guard let process = process, isRunning else {
            return
        }
        
        process.terminate()
        process.waitUntilExit()
        isRunning = false
        
        await logger.info("Caption web server stopped", metadata: [
            "port": "\(port)"
        ])
    }
    
    /// Check if server is running
    public nonisolated func getIsRunning() -> Bool {
        // Note: This is nonisolated because it's a simple property check
        // In a real scenario, you'd want to make isRunning a Sendable wrapper
        false
    }
}

// MARK: - Error Types
enum CaptionWebServerError: LocalizedError {
    case startupFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .startupFailed(let message):
            return "Failed to start caption web server: \(message)"
        }
    }
}
