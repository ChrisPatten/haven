//
//  ICloudDriveInstanceConfig.swift
//  Haven
//
//  iCloud Drive collector instance configuration
//  Persisted in ~/.haven/icloud_drive.plist
//

import Foundation

/// iCloud Drive collector instances configuration
public struct ICloudDriveInstancesConfig: Codable, Equatable, @unchecked Sendable {
    public var instances: [ICloudDriveInstance]
    
    public init(instances: [ICloudDriveInstance] = []) {
        self.instances = instances
    }
}

/// Individual iCloud Drive collector instance
public struct ICloudDriveInstance: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var path: String?  // Optional override path (defaults to iCloud Drive root)
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var tags: [String]
    public var stateFile: String?  // Override state file path
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case path
        case includeGlobs = "include_globs"
        case excludeGlobs = "exclude_globs"
        case tags
        case stateFile = "state_file"
    }
    
    public init(
        id: String = UUID().uuidString,
        name: String = "",
        enabled: Bool = true,
        path: String? = nil,  // nil means use default iCloud Drive root
        includeGlobs: [String] = ["*.txt", "*.md", "*.pdf", "*.jpg", "*.jpeg", "*.png", "*.gif", "*.heic", "*.heif"],
        excludeGlobs: [String] = [],
        tags: [String] = [],
        stateFile: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.path = path
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.tags = tags
        self.stateFile = stateFile
    }
}

