//
//  EmailController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore
import CollectorHandlers
import HostAgentEmail

/// Controller for Email (IMAP) collector
public actor EmailController: CollectorController {
    public let collectorId = "email_imap"
    
    private let handler: EmailImapHandler
    private let baseState: BaseCollectorController
    private let logger = HavenLogger(category: "email-controller")
    
    public init(config: HavenConfig, serviceController: ServiceController) async throws {
        self.baseState = BaseCollectorController()
        
        // EmailImapHandler creates its own collector and services
        self.handler = EmailImapHandler(config: config)
    }
    
    public func run(request: HostAgentEmail.CollectorRunRequest?, onProgress: ((JobProgress) -> Void)?) async throws -> HostAgentEmail.RunResponse {
        let currentlyRunning = await isRunning()
        guard !currentlyRunning else {
            throw CollectorError.alreadyRunning
        }
        
        // Mark as running
        baseState.isRunning = true
        
        // Use defer to ensure isRunning is always reset, even on cancellation
        defer {
            baseState.isRunning = false
        }
        
        do {
            // Bridge handler's progress callback to JobProgress
            let handlerProgress: ((Int, Int, Int, Int) -> Void)? = onProgress != nil ? { scanned, matched, submitted, skipped in
                Task { @MainActor in
                    let progress = JobProgress(
                        scanned: scanned,
                        matched: matched,
                        submitted: submitted,
                        skipped: skipped,
                        currentPhase: "Processing emails",
                        phaseProgress: nil
                    )
                    onProgress?(progress)
                }
            } : nil
            
            // Call handler's direct Swift API with progress callback
            let runResponse = try await handler.runCollector(request: request, onProgress: handlerProgress)
            
            // Update state
            baseState.updateState(from: runResponse)
            
            return runResponse
        } catch {
            // Check if this is a cancellation error
            if error is CancellationError {
                baseState.lastRunStatus = "cancelled"
                baseState.lastRunError = "Collection was cancelled"
            } else {
                baseState.lastRunError = error.localizedDescription
            }
            throw error
        }
    }
    
    public func getState() async -> CollectorStateResponse? {
        // Call handler's direct Swift API
        let stateInfo = await handler.getCollectorState()
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        // Convert HavenCore.AnyCodable to Haven.AnyCodable
        let stats = stateInfo.lastRunStats
        var lastRunStats: [String: AnyCodable]? = nil
        if let stats = stats {
            var dict: [String: AnyCodable] = [:]
            for (key, havenCoreValue) in stats {
                let value = havenCoreValue.value
                switch value {
                case let str as String:
                    dict[key] = .string(str)
                case let int as Int:
                    dict[key] = .int(int)
                case let double as Double:
                    dict[key] = .double(double)
                case let bool as Bool:
                    dict[key] = .bool(bool)
                default:
                    dict[key] = .null
                }
            }
            lastRunStats = dict
        }
        
        return CollectorStateResponse(
            isRunning: stateInfo.isRunning,
            lastRunStatus: stateInfo.lastRunStatus,
            lastRunTime: stateInfo.lastRunTime.map { formatter.string(from: $0) },
            lastRunStats: lastRunStats,
            lastRunError: stateInfo.lastRunError
        )
    }
    
    public func isRunning() async -> Bool {
        return baseState.isRunning
    }
    
    /// Test IMAP connection and list folders
    public func testConnection(
        host: String,
        port: Int,
        tls: Bool,
        username: String,
        authKind: String,
        secretRef: String?
    ) async -> EmailImapHandler.TestConnectionResult {
        return await handler.testConnection(
            host: host,
            port: port,
            tls: tls,
            username: username,
            authKind: authKind,
            secretRef: secretRef
        )
    }
    
    public func reset() async throws {
        let fm = FileManager.default
        
        // Get cache directory (same logic as EmailImapHandler)
        let home = fm.homeDirectoryForCurrentUser
        let cacheDir = home.appendingPathComponent("Library/Caches/Haven/remote_mail")
        
        // Delete all IMAP fence state files (one per account/folder combination)
        if fm.fileExists(atPath: cacheDir.path) {
            let files = try fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            for file in files {
                if file.lastPathComponent.hasPrefix("imap_state_") && file.pathExtension == "json" {
                    try fm.removeItem(at: file)
                    logger.info("Deleted IMAP fence state file", metadata: ["path": file.path])
                }
            }
        }
        
        // Delete handler state file
        let handlerStateFile = cacheDir.appendingPathComponent("imap_handler_state.json")
        if fm.fileExists(atPath: handlerStateFile.path) {
            try fm.removeItem(at: handlerStateFile)
            logger.info("Deleted IMAP handler state file", metadata: ["path": handlerStateFile.path])
        }
        
        // Reset in-memory state
        baseState.lastRunTime = nil
        baseState.lastRunStatus = nil
        baseState.lastRunStats = nil
        baseState.lastRunError = nil
    }
}
