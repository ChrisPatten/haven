import Foundation
import EventKit

/// Manages EventKit authorization for Reminders and Calendar access
public actor EventKitAuthorizationManager {
    private let eventStore: EKEventStore
    private let logger = HavenLogger(category: "eventkit-auth")
    
    // Cache authorization status to avoid repeated checks
    private var remindersAuthStatus: EKAuthorizationStatus?
    private var calendarAuthStatus: EKAuthorizationStatus?
    
    public init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }
    
    /// Request Reminders access
    /// Returns true if authorized, false if denied
    /// Throws if authorization request fails
    public func requestRemindersAccess() async throws -> Bool {
        // Check current status
        let currentStatus = EKEventStore.authorizationStatus(for: .reminder)
        
        // Return cached status if already determined
        if let cached = remindersAuthStatus, cached == currentStatus {
            return isAuthorizedStatus(cached)
        }
        
        remindersAuthStatus = currentStatus
        
        // If already authorized, return true
        if isAuthorizedStatus(currentStatus) {
            logger.info("Reminders access already authorized")
            return true
        }
        
        // If denied or restricted, return false
        if currentStatus == .denied || currentStatus == .restricted {
            logger.warning("Reminders access denied or restricted", metadata: [
                "status": String(currentStatus.rawValue)
            ])
            return false
        }
        
        // Request authorization
        if currentStatus == .notDetermined {
            logger.info("Requesting Reminders permission")
            do {
                let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    // Use macOS 14+ API: requestFullAccessToRemindersWithCompletion
                    if #available(macOS 14.0, *) {
                        eventStore.requestFullAccessToReminders { granted, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: granted)
                            }
                        }
                    } else {
                        // Fallback for older macOS (shouldn't happen since we target macOS 14+)
                        eventStore.requestAccess(to: .reminder) { granted, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: granted)
                            }
                        }
                    }
                }
                
                // Update cached status - check new status after request
                let newStatus = EKEventStore.authorizationStatus(for: .reminder)
                remindersAuthStatus = newStatus
                
                if granted {
                    logger.info("Reminders permission granted")
                } else {
                    logger.warning("Reminders permission denied by user")
                }
                
                return granted
            } catch {
                logger.error("Failed to request Reminders permission", metadata: ["error": error.localizedDescription])
                remindersAuthStatus = .denied
                throw EventKitError.authorizationFailed("Failed to request Reminders permission: \(error.localizedDescription)")
            }
        }
        
        // Unknown status
        return false
    }
    
    /// Check if a status represents authorized access (handles both .authorized and .fullAccess)
    private func isAuthorizedStatus(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            // In macOS 14+, .fullAccess is the new authorized state
            return status == .fullAccess
        } else {
            // Pre-macOS 14, use .authorized
            return status == .authorized
        }
    }
    
    /// Request Calendar access (for future Calendar collector)
    /// Returns true if authorized, false if denied
    /// Throws if authorization request fails
    public func requestCalendarAccess() async throws -> Bool {
        // Check current status
        let currentStatus = EKEventStore.authorizationStatus(for: .event)
        
        // Return cached status if already determined
        if let cached = calendarAuthStatus, cached == currentStatus {
            return isAuthorizedStatus(cached)
        }
        
        calendarAuthStatus = currentStatus
        
        // If already authorized, return true
        if isAuthorizedStatus(currentStatus) {
            logger.info("Calendar access already authorized")
            return true
        }
        
        // If denied or restricted, return false
        if currentStatus == .denied || currentStatus == .restricted {
            logger.warning("Calendar access denied or restricted", metadata: [
                "status": String(currentStatus.rawValue)
            ])
            return false
        }
        
        // Request authorization
        if currentStatus == .notDetermined {
            logger.info("Requesting Calendar permission")
            do {
                let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    // Use macOS 14+ API: requestFullAccessToEventsWithCompletion
                    if #available(macOS 14.0, *) {
                        eventStore.requestFullAccessToEvents { granted, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: granted)
                            }
                        }
                    } else {
                        // Fallback for older macOS (shouldn't happen since we target macOS 14+)
                        eventStore.requestAccess(to: .event) { granted, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: granted)
                            }
                        }
                    }
                }
                
                // Update cached status - check new status after request
                let newStatus = EKEventStore.authorizationStatus(for: .event)
                calendarAuthStatus = newStatus
                
                if granted {
                    logger.info("Calendar permission granted")
                } else {
                    logger.warning("Calendar permission denied by user")
                }
                
                return granted
            } catch {
                logger.error("Failed to request Calendar permission", metadata: ["error": error.localizedDescription])
                calendarAuthStatus = .denied
                throw EventKitError.authorizationFailed("Failed to request Calendar permission: \(error.localizedDescription)")
            }
        }
        
        // Unknown status
        return false
    }
    
    /// Get current Reminders authorization status
    public func getRemindersAuthorizationStatus() -> EKAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        remindersAuthStatus = status
        return status
    }
    
    /// Get current Calendar authorization status
    public func getCalendarAuthorizationStatus() -> EKAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarAuthStatus = status
        return status
    }
    
    /// Check if Reminders access is authorized
    public func isRemindersAuthorized() -> Bool {
        return isAuthorizedStatus(getRemindersAuthorizationStatus())
    }
    
    /// Check if Calendar access is authorized
    public func isCalendarAuthorized() -> Bool {
        return isAuthorizedStatus(getCalendarAuthorizationStatus())
    }
}

