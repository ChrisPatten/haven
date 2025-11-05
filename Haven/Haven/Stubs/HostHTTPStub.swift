//
//  HostHTTPStub.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//  Stub implementation for HostHTTP types until package dependencies are added
//

import Foundation
import HavenCore

// MARK: - HostHTTP Types Stub

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?
    
    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?
    
    public init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
    
    public static func ok(json: Codable) -> HTTPResponse {
        // Stub implementation
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: nil)
    }
    
    public static func badRequest(message: String) -> HTTPResponse {
        return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: message.data(using: .utf8))
    }
    
    public static func notFound(message: String? = nil) -> HTTPResponse {
        return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"], body: message?.data(using: .utf8))
    }
    
    public static func internalError(message: String) -> HTTPResponse {
        return HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"], body: message.data(using: .utf8))
    }
}

public struct RequestContext {
    public let requestId: String
    
    public init(requestId: String = UUID().uuidString) {
        self.requestId = requestId
    }
}

public actor IMessageHandler {
    private let config: HavenConfig
    private let gatewayClient: GatewayClient
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunError: String?
    
    public init(config: HavenConfig, gatewayClient: GatewayClient) {
        self.config = config
        self.gatewayClient = gatewayClient
    }
    
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Stub implementation - deprecated, use runCollector() instead
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        
        // Simulate work
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        lastRunStatus = "completed"
        
        // Return stub adapter response
        let adapterResponse: [String: Any] = [
            "scanned": 0,
            "matched": 0,
            "submitted": 0,
            "skipped": 0,
            "warnings": [],
            "errors": []
        ]
        
        let data = try? JSONSerialization.data(withJSONObject: adapterResponse)
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    
    public func handleState(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Stub implementation - deprecated, use getCollectorState() instead
        var state: [String: Any] = [
            "is_running": isRunning,
            "last_run_status": lastRunStatus
        ]
        
        if let lastRunTime = lastRunTime {
            state["last_run_time"] = ISO8601DateFormatter().string(from: lastRunTime)
        }
        
        if let lastRunError = lastRunError {
            state["last_run_error"] = lastRunError
        }
        
        let data = try? JSONSerialization.data(withJSONObject: state)
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    
    // MARK: - Direct Swift APIs (stub implementation)
    // These will be replaced by real implementations when hostagent package is integrated
    
    public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse {
        // Stub implementation - will be replaced by real handler when package is integrated
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        
        // Simulate work
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        lastRunStatus = "completed"
        
        let runID = UUID().uuidString
        let startTime = lastRunTime ?? Date()
        
        return RunResponse(
            collector: "imessage",
            runID: runID,
            startedAt: startTime
        )
    }
    
    public func getCollectorState() async -> CollectorStateInfo {
        return CollectorStateInfo(
            isRunning: isRunning,
            lastRunTime: lastRunTime,
            lastRunStatus: lastRunStatus,
            lastRunStats: nil,
            lastRunError: lastRunError
        )
    }
}

public actor ContactsHandler {
    private let config: HavenConfig
    private let gatewayClient: GatewayClient
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunError: String?
    
    public init(config: HavenConfig, gatewayClient: GatewayClient) {
        self.config = config
        self.gatewayClient = gatewayClient
    }
    
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Stub implementation - deprecated, use runCollector() instead
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        
        // Simulate work
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        lastRunStatus = "completed"
        
        // Return stub adapter response
        let adapterResponse: [String: Any] = [
            "scanned": 0,
            "matched": 0,
            "submitted": 0,
            "skipped": 0,
            "warnings": [],
            "errors": []
        ]
        
        let data = try? JSONSerialization.data(withJSONObject: adapterResponse)
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    
    public func handleState(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Stub implementation - deprecated, use getCollectorState() instead
        var state: [String: Any] = [
            "is_running": isRunning,
            "last_run_status": lastRunStatus
        ]
        
        if let lastRunTime = lastRunTime {
            state["last_run_time"] = ISO8601DateFormatter().string(from: lastRunTime)
        }
        
        if let lastRunError = lastRunError {
            state["last_run_error"] = lastRunError
        }
        
        let data = try? JSONSerialization.data(withJSONObject: state)
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    
    // MARK: - Direct Swift APIs (stub implementation)
    
    public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse {
        // Stub implementation - will be replaced by real handler when package is integrated
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        lastRunStatus = "completed"
        
        let runID = UUID().uuidString
        let startTime = lastRunTime ?? Date()
        
        return RunResponse(
            collector: "contacts",
            runID: runID,
            startedAt: startTime
        )
    }
    
    public func getCollectorState() async -> CollectorStateInfo {
        return CollectorStateInfo(
            isRunning: isRunning,
            lastRunTime: lastRunTime,
            lastRunStatus: lastRunStatus,
            lastRunStats: nil,
            lastRunError: lastRunError
        )
    }
}

public actor LocalFSHandler {
    private let config: HavenConfig
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunError: String?
    
    public init(config: HavenConfig) {
        self.config = config
    }
    
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Stub implementation - deprecated, use runCollector() instead
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        lastRunStatus = "completed"
        
        let adapterResponse: [String: Any] = [
            "scanned": 0,
            "matched": 0,
            "submitted": 0,
            "skipped": 0,
            "warnings": [],
            "errors": []
        ]
        
        let data = try? JSONSerialization.data(withJSONObject: adapterResponse)
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    
    public func handleState(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Stub implementation - deprecated, use getCollectorState() instead
        var state: [String: Any] = [
            "is_running": isRunning,
            "last_run_status": lastRunStatus
        ]
        
        if let lastRunTime = lastRunTime {
            state["last_run_time"] = ISO8601DateFormatter().string(from: lastRunTime)
        }
        
        if let lastRunError = lastRunError {
            state["last_run_error"] = lastRunError
        }
        
        let data = try? JSONSerialization.data(withJSONObject: state)
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    
    // MARK: - Direct Swift APIs (stub implementation)
    
    public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse {
        // Stub implementation - will be replaced by real handler when package is integrated
        isRunning = true
        lastRunTime = Date()
        lastRunStatus = "running"
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        lastRunStatus = "completed"
        
        let runID = UUID().uuidString
        let startTime = lastRunTime ?? Date()
        
        return RunResponse(
            collector: "localfs",
            runID: runID,
            startedAt: startTime
        )
    }
    
    public func getCollectorState() async -> CollectorStateInfo {
        return CollectorStateInfo(
            isRunning: isRunning,
            lastRunTime: lastRunTime,
            lastRunStatus: lastRunStatus,
            lastRunStats: nil,
            lastRunError: lastRunError
        )
    }
}

public actor EmailImapHandler {
    private let config: HavenConfig
    private var isRunning: Bool = false
    
    public init(config: HavenConfig) {
        self.config = config
    }
    
    public func handleRun(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Stub implementation - deprecated, use runCollector() instead
        isRunning = true
        
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        
        let adapterResponse: [String: Any] = [
            "scanned": 0,
            "matched": 0,
            "submitted": 0,
            "skipped": 0,
            "warnings": [],
            "errors": []
        ]
        
        let data = try? JSONSerialization.data(withJSONObject: adapterResponse)
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    
    // MARK: - Direct Swift APIs (stub implementation)
    
    public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse {
        // Stub implementation - will be replaced by real handler when package is integrated
        isRunning = true
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        isRunning = false
        
        let runID = UUID().uuidString
        let startTime = Date()
        
        return RunResponse(
            collector: "email_imap",
            runID: runID,
            startedAt: startTime
        )
    }
}

