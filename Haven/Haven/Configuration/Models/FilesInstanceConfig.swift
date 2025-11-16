//
//  FilesInstanceConfig.swift
//  Haven
//
//  LocalFS collector instance configuration
//  Persisted in ~/.haven/files.plist
//

import Foundation

/// LocalFS collector instances configuration
public struct FilesInstancesConfig: Codable, Equatable, @unchecked Sendable {
    public var instances: [FilesInstance]
    
    public init(instances: [FilesInstance] = []) {
        self.instances = instances
    }
}

/// Individual LocalFS collector instance
public struct FilesInstance: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var paths: [String]  // Watch directories
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var tags: [String]
    public var moveTo: String?  // Destination directory
    public var deleteAfter: Bool
    public var followSymlinks: Bool
    public var stateFile: String?  // Override state file path
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case paths
        case includeGlobs = "include_globs"
        case excludeGlobs = "exclude_globs"
        case tags
        case moveTo = "move_to"
        case deleteAfter = "delete_after"
        case followSymlinks = "follow_symlinks"
        case stateFile = "state_file"
    }
    
    public init(
        id: String = UUID().uuidString,
        name: String = "",
        enabled: Bool = true,
        paths: [String] = [],
        includeGlobs: [String] = ["*.txt", "*.md", "*.pdf", "*.jpg", "*.jpeg", "*.png", "*.gif", "*.heic", "*.heif"],
        excludeGlobs: [String] = [],
        tags: [String] = [],
        moveTo: String? = nil,
        deleteAfter: Bool = false,
        followSymlinks: Bool = false,
        stateFile: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.paths = paths
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.tags = tags
        self.moveTo = moveTo
        self.deleteAfter = deleteAfter
        self.followSymlinks = followSymlinks
        self.stateFile = stateFile
    }
}

