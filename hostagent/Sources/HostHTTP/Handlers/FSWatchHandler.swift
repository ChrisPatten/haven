import Foundation
import HavenCore
import FSWatch

/// HTTP handler for file system watch endpoints
public struct FSWatchHandler {
    private let fsWatchService: FSWatchService
    private let config: FSWatchModuleConfig
    
    public init(fsWatchService: FSWatchService, config: FSWatchModuleConfig) {
        self.fsWatchService = fsWatchService
        self.config = config
    }
    
    // MARK: - Event Polling
    
    /// Handle GET /v1/fs-watches/events - Poll events from queue
    public func handlePollEvents(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Parse query parameters
        let queryParams = request.queryParameters
        let limit = queryParams["limit"].flatMap { Int($0) } ?? 100
        let since = queryParams["since"].flatMap { parseISO8601Date($0) }
        
        // Poll events
        let events = await fsWatchService.pollEvents(limit: limit, since: since)
        
        // Check if client wants to acknowledge
        if queryParams["acknowledge"] == "true" {
            let eventIds = events.map { $0.id }
            await fsWatchService.acknowledgeEvents(eventIds: eventIds)
        }
        
        let response = EventsResponse(
            status: "success",
            data: EventsData(
                events: events,
                hasMore: events.count == limit
            )
        )
        
        return encodeResponse(response)
    }
    
    // MARK: - Watch Management
    
    /// Handle GET /v1/fs-watches - List all active watches
    public func handleListWatches(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        let watches = await fsWatchService.listWatches()
        let stats = await fsWatchService.getStats()
        
        let response = WatchesResponse(
            status: "success",
            data: WatchesData(
                watches: watches,
                stats: stats
            )
        )
        
        return encodeResponse(response)
    }
    
    /// Handle POST /v1/fs-watches - Add a new watch
    public func handleAddWatch(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Parse request body
        guard let body = request.body else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: formatError("Request body required")
            )
        }
        
        guard let addRequest = try? JSONDecoder().decode(AddWatchRequest.self, from: body) else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: formatError("Invalid request format")
            )
        }
        
        // Create watch entry
        let entry = FSWatchEntry(
            id: addRequest.id ?? UUID().uuidString,
            path: addRequest.path,
            glob: addRequest.glob,
            target: addRequest.target ?? "gateway",
            handoff: addRequest.handoff ?? "presigned"
        )
        
        // Add watch
        do {
            try await fsWatchService.addWatch(entry: entry)
            
            let response = AddWatchResponse(
                status: "success",
                data: AddWatchData(
                    id: entry.id,
                    message: "Watch added successfully"
                )
            )
            
            return encodeResponse(response)
            
        } catch let error as FSWatchError {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: formatError(error.localizedDescription)
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: formatError("Failed to add watch: \(error.localizedDescription)")
            )
        }
    }
    
    /// Handle DELETE /v1/fs-watches/{id} - Remove a watch
    public func handleRemoveWatch(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Extract watch ID from path
        guard let watchId = extractWatchId(from: request.path) else {
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: formatError("Invalid watch ID")
            )
        }
        
        // Remove watch
        do {
            try await fsWatchService.removeWatch(id: watchId)
            
            let response = RemoveWatchResponse(
                status: "success",
                data: RemoveWatchData(message: "Watch removed successfully")
            )
            
            return encodeResponse(response)
            
        } catch let error as FSWatchError {
            return HTTPResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: formatError(error.localizedDescription)
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: formatError("Failed to remove watch: \(error.localizedDescription)")
            )
        }
    }
    
    /// Handle POST /v1/fs-watches/events:clear - Clear all events
    public func handleClearEvents(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        await fsWatchService.clearEvents()
        
        let response = GenericResponse(
            status: "success",
            message: "Events cleared"
        )
        
        return encodeResponse(response)
    }
    
    // MARK: - Helper Methods
    
    private func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
    
    private func extractWatchId(from path: String) -> String? {
        // Extract ID from /v1/fs-watches/{id}
        let components = path.split(separator: "/")
        guard components.count >= 3,
              components[0] == "v1",
              components[1] == "fs-watches",
              components.count > 2 else {
            return nil
        }
        
        return String(components[2])
    }
    
    private func encodeResponse<T: Encodable>(_ response: T) -> HTTPResponse {
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: formatError("Failed to encode response")
            )
        }
        
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }
    
    private func formatError(_ message: String) -> Data {
        let error = FSWatchErrorResponse(status: "error", error: message)
        return (try? JSONEncoder().encode(error)) ?? Data()
    }
}

// MARK: - Request/Response Models

struct AddWatchRequest: Codable {
    let id: String?
    let path: String
    let glob: String?
    let target: String?
    let handoff: String?
}

struct EventsResponse: Codable {
    let status: String
    let data: EventsData
}

struct EventsData: Codable {
    let events: [FileSystemEvent]
    let hasMore: Bool
    
    enum CodingKeys: String, CodingKey {
        case events
        case hasMore = "has_more"
    }
}

struct WatchesResponse: Codable {
    let status: String
    let data: WatchesData
}

struct WatchesData: Codable {
    let watches: [FSWatchEntry]
    let stats: FSWatchStats
}

struct AddWatchResponse: Codable {
    let status: String
    let data: AddWatchData
}

struct AddWatchData: Codable {
    let id: String
    let message: String
}

struct RemoveWatchResponse: Codable {
    let status: String
    let data: RemoveWatchData
}

struct RemoveWatchData: Codable {
    let message: String
}

struct GenericResponse: Codable {
    let status: String
    let message: String
}

// Use a uniquely named error response to avoid conflicts
private struct FSWatchErrorResponse: Codable {
    let status: String
    let error: String
}
