import Foundation
import EventKit

/// Shared EventKit store manager for Reminders and Calendar collectors
/// Provides thread-safe access to EKEventStore
public actor EventKitStore {
    private let eventStore: EKEventStore
    private let logger = HavenLogger(category: "eventkit-store")
    
    public init() {
        self.eventStore = EKEventStore()
    }
    
    /// Get the underlying EKEventStore instance
    /// Note: EKEventStore is thread-safe, so this can be nonisolated
    nonisolated public func getEventStore() -> EKEventStore {
        return eventStore
    }
    
    /// Fetch all reminder calendars
    public func fetchReminderCalendars() throws -> [EKCalendar] {
        let calendars = eventStore.calendars(for: .reminder)
        logger.debug("Fetched reminder calendars", metadata: ["count": String(calendars.count)])
        return calendars
    }
    
    /// Fetch all event calendars (for future Calendar collector)
    public func fetchEventCalendars() throws -> [EKCalendar] {
        let calendars = eventStore.calendars(for: .event)
        logger.debug("Fetched event calendars", metadata: ["count": String(calendars.count)])
        return calendars
    }
    
    /// Fetch reminders matching a predicate
    public func fetchReminders(matching predicate: NSPredicate) async throws -> [EKReminder] {
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders = reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(throwing: EventKitError.fetchFailed("Failed to fetch reminders"))
                }
            }
        }
    }
}

/// EventKit-related errors
public enum EventKitError: Error, LocalizedError {
    case fetchFailed(String)
    case authorizationFailed(String)
    case storeError(String)
    
    public var errorDescription: String? {
        switch self {
        case .fetchFailed(let msg):
            return "EventKit fetch failed: \(msg)"
        case .authorizationFailed(let msg):
            return "EventKit authorization failed: \(msg)"
        case .storeError(let msg):
            return "EventKit store error: \(msg)"
        }
    }
}

