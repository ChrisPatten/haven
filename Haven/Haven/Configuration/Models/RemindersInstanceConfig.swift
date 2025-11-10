//
//  RemindersInstanceConfig.swift
//  Haven
//
//  Reminders collector configuration
//  Persisted in ~/.haven/reminders.plist
//

import Foundation

/// Reminders collector configuration (single instance, system-level)
public struct RemindersInstanceConfig: Codable, @unchecked Sendable {
    /// Selected reminder calendar identifiers to collect from
    /// Empty array means collect from all calendars
    public var selectedCalendarIds: [String]
    
    enum CodingKeys: String, CodingKey {
        case selectedCalendarIds = "selected_calendar_ids"
    }
    
    public init(selectedCalendarIds: [String] = []) {
        self.selectedCalendarIds = selectedCalendarIds
    }
}

