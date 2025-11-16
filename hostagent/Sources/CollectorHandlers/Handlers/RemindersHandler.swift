import Foundation
import EventKit
import HavenCore
import CommonCrypto
import HostAgentEmail

/// Handler for Reminders collector endpoints
public actor RemindersHandler {
    private let config: HavenConfig
    private let gatewayClient: GatewayClient
    private let submitter: DocumentSubmitter?
    private let logger = HavenLogger(category: "reminders-handler")
    
    // EventKit infrastructure
    private let eventKitStore: EventKitStore
    private let authManager: EventKitAuthorizationManager
    private let changeTracker: EventKitChangeTracker
    
    // State tracking
    private var isRunning: Bool = false
    private var lastRunTime: Date?
    private var lastRunStatus: String = "idle"
    private var lastRunStats: CollectorStats?
    private var lastRunError: String?
    private var runRequest: CollectorRunRequest?
    
    private struct CollectorStats: Codable {
        var remindersScanned: Int
        var remindersProcessed: Int
        var remindersSubmitted: Int
        var remindersSkipped: Int
        var batchesSubmitted: Int
        var startTime: Date
        var endTime: Date?
        var durationMs: Int?
        
        var toDict: [String: Any] {
            var dict: [String: Any] = [
                "reminders_scanned": remindersScanned,
                "reminders_processed": remindersProcessed,
                "reminders_submitted": remindersSubmitted,
                "reminders_skipped": remindersSkipped,
                "batches_submitted": batchesSubmitted,
                "start_time": ISO8601DateFormatter().string(from: startTime)
            ]
            if let endTime = endTime {
                dict["end_time"] = ISO8601DateFormatter().string(from: endTime)
            }
            if let durationMs = durationMs {
                dict["duration_ms"] = durationMs
            }
            return dict
        }
    }
    
    public init(config: HavenConfig, gatewayClient: GatewayClient, submitter: DocumentSubmitter? = nil) {
        self.config = config
        self.gatewayClient = gatewayClient
        self.submitter = submitter
        
        // Initialize EventKit infrastructure
        self.eventKitStore = EventKitStore()
        // Note: eventStore will be accessed via eventKitStore when needed
        // We'll initialize authManager and changeTracker asynchronously
        self.authManager = EventKitAuthorizationManager(eventStore: eventKitStore.getEventStore())
        self.changeTracker = EventKitChangeTracker()
        
        // Load existing sync state
        Task {
            await changeTracker.loadSyncState()
        }
    }
    
    // MARK: - Direct Swift APIs
    
    /// Direct Swift API for running the Reminders collector
    public func runCollector(
        request: CollectorRunRequest?,
        onProgress: ((Int, Int, Int, Int) -> Void)? = nil
    ) async throws -> RunResponse {
        // Extract selected calendar IDs from scope if provided
        var selectedCalendarIds: Set<String>? = nil
        if let scopeDict = request?.scope?.value as? [String: Any] {
            if let calendarIdsString = scopeDict["calendar_ids"] as? String {
                // Parse comma-separated string
                let ids = calendarIdsString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                if !ids.isEmpty {
                    selectedCalendarIds = Set(ids)
                }
            }
        }
        // Check if already running
        guard !isRunning else {
            throw RemindersError.reminderAccessFailed("Collector is already running")
        }
        
        // Parse request
        let mode: CollectorRunRequest.Mode = request?.mode ?? .real
        let limit = request?.limit
        
        // Store request for access in collectReminders
        self.runRequest = request
        
        logger.info("Starting Reminders collector", metadata: [
            "mode": mode.rawValue,
            "limit": limit?.description ?? "unlimited"
        ])
        
        // Initialize response
        let runID = UUID().uuidString
        let startTime = Date()
        var response = RunResponse(collector: "reminders", runID: runID, startedAt: startTime)
        
        // Run collection
        isRunning = true
        lastRunTime = startTime
        lastRunStatus = "running"
        lastRunError = nil
        
        var stats = CollectorStats(
            remindersScanned: 0,
            remindersProcessed: 0,
            remindersSubmitted: 0,
            remindersSkipped: 0,
            batchesSubmitted: 0,
            startTime: startTime
        )
        
            do {
                let result = try await collectReminders(mode: mode, limit: limit, selectedCalendarIds: selectedCalendarIds, stats: &stats)
            
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "ok"
            lastRunStats = stats
            
            logger.info("Reminders collection completed", metadata: [
                "scanned": String(stats.remindersScanned),
                "submitted": String(stats.remindersSubmitted),
                "batches": String(stats.batchesSubmitted),
                "duration_ms": String(stats.durationMs ?? 0)
            ])
            
            // Convert stats to RunResponse
            response.finish(status: .ok, finishedAt: endTime)
            response.stats = RunResponse.Stats(
                scanned: stats.remindersScanned,
                matched: stats.remindersProcessed,
                submitted: stats.remindersSubmitted,
                skipped: stats.remindersSkipped,
                earliest_touched: nil,
                latest_touched: nil,
                batches: stats.batchesSubmitted
            )
            response.warnings = result.warnings
            response.errors = result.errors
            
            // Report final progress
            onProgress?(stats.remindersScanned, stats.remindersProcessed, stats.remindersSubmitted, stats.remindersSkipped)
            
            return response
            
        } catch {
            let endTime = Date()
            stats.endTime = endTime
            stats.durationMs = Int((endTime.timeIntervalSince(startTime)) * 1000)
            
            isRunning = false
            lastRunStatus = "failed"
            lastRunStats = stats
            lastRunError = error.localizedDescription
            
            logger.error("Reminders collection failed", metadata: ["error": error.localizedDescription])
            
            response.finish(status: .error, finishedAt: endTime)
            response.errors = [error.localizedDescription]
            
            throw error
        }
    }
    
    /// Direct Swift API for getting collector state
    public func getCollectorState() async -> CollectorStateInfo {
        // Convert lastRunStats to [String: HavenCore.AnyCodable]
        var statsDict: [String: HavenCore.AnyCodable]? = nil
        if let stats = lastRunStats {
            var dict: [String: HavenCore.AnyCodable] = [:]
            let statsDictAny = stats.toDict
            for (key, value) in statsDictAny {
                dict[key] = HavenCore.AnyCodable(value)
            }
            statsDict = dict
        }
        
        return CollectorStateInfo(
            isRunning: isRunning,
            lastRunTime: lastRunTime,
            lastRunStatus: lastRunStatus,
            lastRunStats: statsDict,
            lastRunError: lastRunError
        )
    }
    
    // MARK: - Collection Logic
    
    private struct CollectionResult {
        let warnings: [String]
        let errors: [String]
    }
    
    private func collectReminders(mode: CollectorRunRequest.Mode, limit: Int?, selectedCalendarIds: Set<String>?, stats: inout CollectorStats) async throws -> CollectionResult {
        var warnings: [String] = []
        var errors: [String] = []
        
        // In simulate mode, return mock data
        if mode == .simulate {
            logger.info("Running in simulate mode - returning mock reminders")
            let mockReminders = generateMockReminders(limit: limit ?? 5)
            stats.remindersScanned = mockReminders.count
            stats.remindersProcessed = mockReminders.count
            stats.remindersSubmitted = mockReminders.count
            
            try await submitRemindersToGateway(reminders: mockReminders, stats: &stats)
            
            return CollectionResult(warnings: warnings, errors: errors)
        }
        
        // Real mode: request authorization
        let authorized = try await authManager.requestRemindersAccess()
        guard authorized else {
            let status = await authManager.getRemindersAuthorizationStatus()
            let statusDescription: String
            switch status {
            case .notDetermined:
                statusDescription = "not determined"
            case .denied:
                statusDescription = "denied - please grant Reminders access in System Settings"
            case .restricted:
                statusDescription = "restricted by parental controls"
            case .authorized:
                statusDescription = "authorized" // Should not reach here
            @unknown default:
                statusDescription = "unknown (\(status.rawValue))"
            }
            throw RemindersError.reminderAccessDenied("Reminders access denied. Status: \(statusDescription). Please grant Reminders permission in System Settings → Privacy & Security → Reminders.")
        }
        
        // Fetch reminders
        let reminders: [EKReminder]
        do {
            reminders = try await fetchReminders(limit: limit, selectedCalendarIds: selectedCalendarIds)
        } catch {
            let errorMsg = "Failed to fetch reminders: \(error.localizedDescription)"
            logger.error(errorMsg)
            errors.append(errorMsg)
            throw RemindersError.eventStoreError(errorMsg)
        }
        
        stats.remindersScanned = reminders.count
        
        // Convert EKReminder to document payloads
        var documentPayloads: [ReminderDocumentPayload] = []
        for reminder in reminders {
            do {
                let payload = try convertReminderToPayload(reminder: reminder)
                documentPayloads.append(payload)
                stats.remindersProcessed += 1
                
                // Update sync state
                if let lastModified = reminder.lastModifiedDate {
                    await changeTracker.updateItem(identifier: reminder.calendarItemIdentifier, lastModified: lastModified)
                }
            } catch {
                let errorMsg = "Failed to convert reminder: \(error.localizedDescription)"
                logger.warning("reminder_conversion_failed", metadata: [
                    "error": error.localizedDescription,
                    "identifier": reminder.calendarItemIdentifier
                ])
                warnings.append(errorMsg)
                stats.remindersSkipped += 1
                continue
            }
        }
        
        // Submit to gateway
        try await submitRemindersToGateway(reminders: documentPayloads, stats: &stats)
        stats.remindersSubmitted = documentPayloads.count
        
        // Update last sync timestamp
        await changeTracker.updateLastSyncTimestamp(Date())
        await changeTracker.saveSyncState()
        
        return CollectionResult(warnings: warnings, errors: errors)
    }
    
    private func fetchReminders(limit: Int?, selectedCalendarIds: Set<String>?) async throws -> [EKReminder] {
        let eventStore = eventKitStore.getEventStore()
        
        // Fetch all reminder calendars
        var allCalendars = try await eventKitStore.fetchReminderCalendars()
        
        // Filter calendars if specific IDs are selected
        if let selectedIds = selectedCalendarIds, !selectedIds.isEmpty {
            allCalendars = allCalendars.filter { selectedIds.contains($0.calendarIdentifier) }
        }
        
        // Build predicate - fetch incomplete reminders
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: allCalendars.isEmpty ? nil : allCalendars
        )
        
        // Fetch reminders
        let reminders = try await eventKitStore.fetchReminders(matching: predicate)
        
        // Apply limit if specified
        if let limit = limit {
            return Array(reminders.prefix(limit))
        }
        
        return reminders
    }
    
    private func convertReminderToPayload(reminder: EKReminder) throws -> ReminderDocumentPayload {
        let identifier = reminder.calendarItemIdentifier
        let title = reminder.title ?? "Untitled Reminder"
        let notes = reminder.notes ?? ""
        
        // Build text content (title + notes)
        var textContent = title
        if !notes.isEmpty {
            textContent += "\n\n\(notes)"
        }
        
        // Compute content hash
        let contentHash = sha256Hex(of: textContent.data(using: .utf8)!)
        
        // Build idempotency key
        // If force is enabled, include current timestamp to make key unique and force re-ingestion
        let lastModifiedStr = reminder.lastModifiedDate?.timeIntervalSince1970.description ?? "0"
        let forceSuffix = (runRequest?.force == true) ? ":\(Date().timeIntervalSince1970)" : ""
        let idempotencyKey = sha256Hex(of: "reminders:\(identifier):\(lastModifiedStr)\(forceSuffix)".data(using: .utf8)!)
        
        // Extract dates
        let dueDate: Date?
        if let dueComponents = reminder.dueDateComponents {
            let calendar = Calendar.current
            dueDate = calendar.date(from: dueComponents)
        } else {
            dueDate = nil
        }
        
        let startDate: Date?
        if let startComponents = reminder.startDateComponents {
            let calendar = Calendar.current
            startDate = calendar.date(from: startComponents)
        } else {
            startDate = nil
        }
        
        // Determine content_timestamp and content_timestamp_type following reminder rules
        // If due date exists, use it as primary; else use created/modified
        let contentTimestamp: Date
        let contentTimestampType: String
        
        if let due = dueDate {
            contentTimestamp = due
            contentTimestampType = "due"
        } else if let modified = reminder.lastModifiedDate {
            contentTimestamp = modified
            contentTimestampType = "modified"
        } else if let created = reminder.creationDate {
            contentTimestamp = created
            contentTimestampType = "created"
        } else {
            contentTimestamp = Date()
            contentTimestampType = "modified"
        }
        
        // Build timestamp metadata structure
        var sourceSpecificTimestamps: [String: Any] = [:]
        if let created = reminder.creationDate {
            sourceSpecificTimestamps["created_at"] = ISO8601DateFormatter().string(from: created)
        }
        if let modified = reminder.lastModifiedDate {
            sourceSpecificTimestamps["modified_at"] = ISO8601DateFormatter().string(from: modified)
        }
        if let due = dueDate {
            sourceSpecificTimestamps["due_at"] = ISO8601DateFormatter().string(from: due)
        }
        if let completed = reminder.completionDate {
            sourceSpecificTimestamps["completed_at"] = ISO8601DateFormatter().string(from: completed)
        }
        if let start = startDate {
            sourceSpecificTimestamps["start_at"] = ISO8601DateFormatter().string(from: start)
        }
        
        let timestampsMetadata: [String: Any] = [
            "primary": [
                "value": ISO8601DateFormatter().string(from: contentTimestamp),
                "type": contentTimestampType
            ],
            "source_specific": sourceSpecificTimestamps
        ]
        
        // Build metadata with new structure
        var metadata: [String: Any] = [
            "timestamps": timestampsMetadata,
            "source": [
                "reminder": [
                    "calendar_item_identifier": identifier,
                    "calendar": reminder.calendar?.title ?? "Unknown",
                    "calendar_id": reminder.calendar?.calendarIdentifier ?? ""
                ]
            ],
            "type": [
                "kind": "reminder",
                "reminder": [
                    "status": reminder.isCompleted ? "completed" : "open",
                    "priority": reminder.priority,
                    "due_date": dueDate.map { ISO8601DateFormatter().string(from: $0) }
                ]
            ],
            "extraction": [
                "collector_name": "reminders",
                "collector_version": "1.0.0",
                "hostagent_modules": []
            ]
        ]
        
        // Add reminder-specific details to source
        if let location = reminder.location {
            if var reminderSource = metadata["source"] as? [String: Any],
               var reminderDict = reminderSource["reminder"] as? [String: Any] {
                reminderDict["location"] = location
                reminderSource["reminder"] = reminderDict
                metadata["source"] = reminderSource
            }
        }
        
        // Extract alarm information
        if let alarms = reminder.alarms, !alarms.isEmpty {
            var alarmInfo: [[String: Any]] = []
            for alarm in alarms {
                var alarmDict: [String: Any] = [:]
                if let absoluteDate = alarm.absoluteDate {
                    alarmDict["absolute_date"] = ISO8601DateFormatter().string(from: absoluteDate)
                }
                // relativeOffset is a TimeInterval (Double), not optional
                let relativeOffset = alarm.relativeOffset
                if relativeOffset != 0 {
                    alarmDict["relative_offset"] = relativeOffset
                }
                if let structuredLocation = alarm.structuredLocation {
                    var locationDict: [String: Any] = [:]
                    locationDict["title"] = structuredLocation.title ?? ""
                    if let geoLocation = structuredLocation.geoLocation {
                        locationDict["latitude"] = geoLocation.coordinate.latitude
                        locationDict["longitude"] = geoLocation.coordinate.longitude
                    }
                    alarmDict["structured_location"] = locationDict
                }
                alarmInfo.append(alarmDict)
            }
            if var reminderSource = metadata["source"] as? [String: Any],
               var reminderDict = reminderSource["reminder"] as? [String: Any] {
                reminderDict["alarms"] = alarmInfo
                reminderSource["reminder"] = reminderDict
                metadata["source"] = reminderSource
            }
        }
        
        return ReminderDocumentPayload(
            idempotencyKey: idempotencyKey,
            sourceType: "macos_reminders",
            sourceId: identifier,
            externalId: identifier,
            title: title,
            text: textContent,
            contentSha256: contentHash,
            contentTimestamp: contentTimestamp,
            contentTimestampType: contentTimestampType,
            hasDueDate: dueDate != nil,
            dueDate: dueDate,
            isCompleted: reminder.isCompleted,
            completedAt: reminder.completionDate,
            metadata: metadata
        )
    }
    
    private func submitRemindersToGateway(reminders: [ReminderDocumentPayload], stats: inout CollectorStats) async throws {
        guard !reminders.isEmpty else {
            logger.info("No reminders to submit")
            return
        }
        
        // Get batch size from config or environment
        let batchSize = getBatchSize()
        let useBatch = runRequest?.batch ?? false
        
        if useBatch {
            // Submit as batch
            try await submitBatch(reminders: reminders)
            stats.batchesSubmitted = 1
        } else {
            // Submit individually or in smaller batches
            for i in stride(from: 0, to: reminders.count, by: batchSize) {
                let endIndex = min(i + batchSize, reminders.count)
                let batch = Array(reminders[i..<endIndex])
                
                try await submitBatch(reminders: batch)
                stats.batchesSubmitted += 1
                
                logger.debug("Submitted batch", metadata: [
                    "batch_size": String(batch.count),
                    "batch_index": String(stats.batchesSubmitted)
                ])
            }
        }
    }
    
    private func submitBatch(reminders: [ReminderDocumentPayload]) async throws {
        guard !reminders.isEmpty else { return }
        
        // Use DocumentSubmitter if available, otherwise fall back to direct HTTP (legacy)
        if let submitter = submitter {
            // Convert reminders to EnrichedDocument and submit via DocumentSubmitter
            let enrichedDocuments = reminders.map { reminder in
                convertToEnrichedDocument(reminder: reminder)
            }
            
            logger.debug("Submitting reminders batch via DocumentSubmitter", metadata: [
                "count": String(reminders.count)
            ])
            
            let results = try await submitter.submitBatch(enrichedDocuments)
            
            // Check for failures
            let failures = results.filter { !$0.success }
            if !failures.isEmpty {
                let errorMessages = failures.compactMap { $0.error }.joined(separator: "; ")
                logger.warning("Some reminders failed to submit", metadata: [
                    "failed_count": String(failures.count),
                    "total_count": String(reminders.count),
                    "errors": errorMessages
                ])
                // Don't throw - partial success is acceptable
            }
            
            logger.debug("Reminders batch submitted via DocumentSubmitter", metadata: [
                "success_count": String(results.filter { $0.success }.count),
                "failure_count": String(failures.count)
            ])
            
            return
        }
        
        // Fallback: direct HTTP submission (should not be used in normal operation)
        logger.warning("DocumentSubmitter not available, using direct HTTP submission (legacy)")
        throw RemindersError.gatewayHttpError(500, "DocumentSubmitter not configured")
    }
    
    /// Convert ReminderDocumentPayload to EnrichedDocument for submission
    private func convertToEnrichedDocument(reminder: ReminderDocumentPayload) -> EnrichedDocument {
        // Convert metadata dictionary to DocumentMetadata
        var additionalMetadata: [String: String] = [:]
        for (key, value) in reminder.metadata {
            if let stringValue = value as? String {
                additionalMetadata[key] = stringValue
            } else if let intValue = value as? Int {
                additionalMetadata[key] = String(intValue)
            } else if let boolValue = value as? Bool {
                additionalMetadata[key] = String(boolValue)
            } else if let arrayValue = value as? [[String: Any]] {
                // Serialize arrays (like reminder.alarms) to JSON string
                if let jsonData = try? JSONSerialization.data(withJSONObject: arrayValue),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    additionalMetadata[key] = jsonString
                }
            } else if let dictValue = value as? [String: Any] {
                // Serialize dictionaries to JSON string
                if let jsonData = try? JSONSerialization.data(withJSONObject: dictValue),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    additionalMetadata[key] = jsonString
                }
            }
        }
        
        // Store reminder-specific fields in additionalMetadata so they can be extracted later
        if reminder.hasDueDate {
            additionalMetadata["has_due_date"] = "true"
        }
        if let dueDate = reminder.dueDate {
            let formatter = ISO8601DateFormatter()
            additionalMetadata["due_date"] = formatter.string(from: dueDate)
        }
        if let isCompleted = reminder.isCompleted {
            additionalMetadata["is_completed"] = isCompleted ? "true" : "false"
        }
        if let completedAt = reminder.completedAt {
            let formatter = ISO8601DateFormatter()
            additionalMetadata["completed_at"] = formatter.string(from: completedAt)
        }
        
        let documentMetadata = DocumentMetadata(
            contentHash: reminder.contentSha256,
            mimeType: "text/plain",
            timestamp: reminder.contentTimestamp,
            timestampType: reminder.contentTimestampType,
            createdAt: nil,
            modifiedAt: nil,
            additionalMetadata: additionalMetadata
        )
        
        let collectorDocument = CollectorDocument(
            content: reminder.text,
            sourceType: reminder.sourceType,
            externalId: reminder.externalId ?? reminder.sourceId,
            metadata: documentMetadata,
            images: [], // Reminders don't have images
            contentType: .contact, // Using contact as closest match (no reminder type yet)
            title: reminder.title,
            canonicalUri: reminder.externalId.map { "reminder://\($0)" }
        )
        
        // Reminders don't need enrichment, so create EnrichedDocument without enrichment
        return EnrichedDocument(
            base: collectorDocument,
            documentEnrichment: nil,
            imageEnrichments: []
        )
    }
    
    
    private func generateMockReminders(limit: Int) -> [ReminderDocumentPayload] {
        let mockTitles = [
            "Buy groceries",
            "Call dentist",
            "Review project proposal",
            "Schedule team meeting",
            "Update documentation"
        ]
        
        return mockTitles.prefix(limit).enumerated().map { index, title in
            let identifier = "mock-reminder-\(index)"
            let textContent = title + "\n\nThis is a mock reminder for testing."
            let contentHash = sha256Hex(of: textContent.data(using: .utf8)!)
            let idempotencyKey = sha256Hex(of: "reminders:\(identifier):\(Date().timeIntervalSince1970)".data(using: .utf8)!)
            
            return ReminderDocumentPayload(
                idempotencyKey: idempotencyKey,
                sourceType: "macos_reminders",
                sourceId: identifier,
                externalId: identifier,
                title: title,
                text: textContent,
                contentSha256: contentHash,
                contentTimestamp: Date(),
                contentTimestampType: "modified",
                hasDueDate: false,
                dueDate: nil,
                isCompleted: false,
                completedAt: nil,
                metadata: ["reminder.calendar": "Mock Calendar"]
            )
        }
    }
    
    private func getBatchSize() -> Int {
        if let envValue = ProcessInfo.processInfo.environment["REMINDERS_BATCH_SIZE"],
           let size = Int(envValue), size > 0 {
            return size
        }
        return 50 // Default batch size
    }
    
    private func sha256Hex(of data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Error Types
    
    public enum RemindersError: Error, LocalizedError {
        case reminderAccessFailed(String)
        case reminderAccessDenied(String)
        case eventStoreError(String)
        case gatewayHttpError(Int, String)
        case invalidGatewayResponse
        
        public var errorDescription: String? {
            switch self {
            case .reminderAccessFailed(let msg):
                return "Reminder access failed: \(msg)"
            case .reminderAccessDenied(let msg):
                return "Reminder access denied: \(msg)"
            case .eventStoreError(let msg):
                return "EventKit store error: \(msg)"
            case .invalidGatewayResponse:
                return "Invalid response from gateway"
            case .gatewayHttpError(let code, let body):
                return "Gateway HTTP error \(code): \(body)"
            }
        }
    }
}

// MARK: - Reminder Document Payload

struct ReminderDocumentPayload {
    let idempotencyKey: String
    let sourceType: String
    let sourceId: String
    let externalId: String?
    let title: String?
    let text: String
    let contentSha256: String
    let contentTimestamp: Date
    let contentTimestampType: String
    let hasDueDate: Bool
    let dueDate: Date?
    let isCompleted: Bool?
    let completedAt: Date?
    let metadata: [String: Any]
}
