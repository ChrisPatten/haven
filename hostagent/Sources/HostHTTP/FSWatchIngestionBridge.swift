import Foundation
@preconcurrency import HavenCore
import FSWatch

/// Bridge that connects fswatch file detection to localfs collector ingestion
public actor FSWatchIngestionBridge {
    private let localFSHandler: LocalFSHandler
    private let logger = HavenLogger(category: "fswatch-ingestion-bridge")
    
    public init(localFSHandler: LocalFSHandler) {
        self.localFSHandler = localFSHandler
    }
    
    /// Create a file ingestion handler closure for use with FSWatchService
    public func createIngestionHandler() -> FileIngestionHandler {
        return { [weak self] filePath in
            await self?.ingestFile(filePath: filePath)
        }
    }
    
    /// Handle ingesting a single file detected by fswatch
    private func ingestFile(filePath: String) async {
        self.logger.info("FSWatch detected file, initiating ingestion", metadata: ["path": filePath])
        
        // Create an empty request - localfs handler will use the default config
        let mockRequest = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/localfs:run",
            headers: ["Content-Type": "application/json"],
            body: "{}".data(using: .utf8)
        )
        
        let context = RequestContext()
        
        // Call the localfs handler to process the file
        let response = await localFSHandler.handleRun(request: mockRequest, context: context)
        
        if response.statusCode == 200 || response.statusCode == 202 {
            self.logger.info("File ingested successfully", metadata: ["path": filePath])
        } else {
            self.logger.warning("File ingestion failed", metadata: [
                "path": filePath,
                "status": response.statusCode
            ])
        }
    }
}
