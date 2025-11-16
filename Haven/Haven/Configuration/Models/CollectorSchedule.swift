//
//  CollectorSchedule.swift
//  Haven
//
//  Automated collector run schedules
//  Persisted in ~/.haven/schedules.plist
//

import Foundation

/// Collector schedules configuration
public struct CollectorSchedulesConfig: Codable, Equatable, @unchecked Sendable {
    public var schedules: [CollectorSchedule]
    
    public init(schedules: [CollectorSchedule] = []) {
        self.schedules = schedules
    }
}

/// Individual collector schedule
public struct CollectorSchedule: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var collectorInstanceId: String  // Collector instance to run (e.g., "email:personal-icloud", "localfs:documents")
    public var enabled: Bool
    public var scheduleType: ScheduleType
    public var cronExpression: String?  // If scheduleType is .cron
    public var intervalSeconds: Int?  // If scheduleType is .interval
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case collectorInstanceId = "collector_instance_id"
        case enabled
        case scheduleType = "schedule_type"
        case cronExpression = "cron_expression"
        case intervalSeconds = "interval_seconds"
    }
    
    public init(
        id: String = UUID().uuidString,
        name: String = "",
        collectorInstanceId: String = "",
        enabled: Bool = true,
        scheduleType: ScheduleType = .interval,
        cronExpression: String? = nil,
        intervalSeconds: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.collectorInstanceId = collectorInstanceId
        self.enabled = enabled
        self.scheduleType = scheduleType
        self.cronExpression = cronExpression
        self.intervalSeconds = intervalSeconds
    }
}

/// Schedule type
public enum ScheduleType: String, Codable, Equatable {
    case cron = "cron"
    case interval = "interval"
}

