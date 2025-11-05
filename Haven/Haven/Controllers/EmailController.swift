//
//  EmailController.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import HavenCore

/// Controller for Email (IMAP) collector
public actor EmailController: CollectorController {
    public let collectorId = "email_imap"
    
    private let handler: EmailImapHandler
    private let baseState: BaseCollectorController
    private let logger = StubLogger(category: "email-controller")
    
    public init(config: HavenConfig, serviceController: ServiceController) async throws {
        self.baseState = BaseCollectorController()
        
        // EmailImapHandler creates its own collector and services
        self.handler = EmailImapHandler(config: config)
    }
    
    public func run(request: CollectorRunRequest?) async throws -> RunResponse {
        let currentlyRunning = await isRunning()
        guard !currentlyRunning else {
            throw CollectorError.alreadyRunning
        }
        
        // Mark as running
        baseState.isRunning = true
        
        do {
            // Call handler's direct Swift API - types match, no conversion needed
            let runResponse = try await handler.runCollector(request: request)
            
            // Update state
            baseState.updateState(from: runResponse)
            baseState.isRunning = false
            
            return runResponse
        } catch {
            baseState.isRunning = false
            baseState.lastRunError = error.localizedDescription
            throw error
        }
    }
    
    public func getState() async -> CollectorStateResponse? {
        // EmailImapHandler doesn't have getCollectorState() yet
        // Return base state if available
        return baseState.buildStateResponse()
    }
    
    public func isRunning() async -> Bool {
        return baseState.isRunning
    }
}
