//
//  StateManager.swift
//  Haven
//
//  State management utility for clearing collector state files and handler status
//

import Foundation
import HavenCore

/// Actor-based state manager for clearing collector state and handler status files
public actor StateManager {
    private let logger = HavenLogger(category: "state-manager")
    
    public init() {
        // Ensure directories exist
        try? HavenFilePaths.initializeDirectories()
    }
    
    /// Clear all collector state files and handler status files
    /// This will reset all collectors to a fresh state, causing them to reprocess data
    /// - Returns: Result containing list of cleared files and any errors
    public func clearAllState() async -> (clearedFiles: [String], errors: [String]) {
        var clearedFiles: [String] = []
        var errors: [String] = []
        let fm = FileManager.default
        
        // Collector state files (in Application Support/State)
        let collectorStateFiles = [
            "localfs_collector_state.json",
            "icloud_drive_collector_state.json",
            "contacts_collector_state.json",
            "imessage_state.json",
            "email_collector_state_run.json",
            "email_collector.lock"
        ]
        
        for fileName in collectorStateFiles {
            let fileURL = HavenFilePaths.stateFile(fileName)
            if fm.fileExists(atPath: fileURL.path) {
                do {
                    try fm.removeItem(at: fileURL)
                    clearedFiles.append(fileURL.path)
                    logger.info("Cleared collector state file", metadata: ["file": fileName])
                } catch {
                    let errorMsg = "Failed to clear \(fileName): \(error.localizedDescription)"
                    errors.append(errorMsg)
                    logger.error("Failed to clear collector state file", metadata: [
                        "file": fileName,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
        
        // IMAP state files (pattern matching for account/folder combinations)
        let remoteMailDir = HavenFilePaths.remoteMailCacheDirectory
        if fm.fileExists(atPath: remoteMailDir.path) {
            do {
                let contents = try fm.contentsOfDirectory(at: remoteMailDir, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    if fileURL.lastPathComponent.hasPrefix("imap_state_") && fileURL.pathExtension == "json" {
                        do {
                            try fm.removeItem(at: fileURL)
                            clearedFiles.append(fileURL.path)
                            logger.info("Cleared IMAP state file", metadata: ["file": fileURL.lastPathComponent])
                        } catch {
                            let errorMsg = "Failed to clear \(fileURL.lastPathComponent): \(error.localizedDescription)"
                            errors.append(errorMsg)
                            logger.error("Failed to clear IMAP state file", metadata: [
                                "file": fileURL.lastPathComponent,
                                "error": error.localizedDescription
                            ])
                        }
                    }
                }
            } catch {
                let errorMsg = "Failed to enumerate IMAP cache directory: \(error.localizedDescription)"
                errors.append(errorMsg)
                logger.error("Failed to enumerate IMAP cache directory", metadata: ["error": error.localizedDescription])
            }
        }
        
        // Handler status files (in Caches)
        let handlerStatusFiles = [
            "imessage_handler_state.json",
            "imap_handler_state.json"
        ]
        
        for fileName in handlerStatusFiles {
            let fileURL = HavenFilePaths.cacheFile(fileName)
            if fm.fileExists(atPath: fileURL.path) {
                do {
                    try fm.removeItem(at: fileURL)
                    clearedFiles.append(fileURL.path)
                    logger.info("Cleared handler status file", metadata: ["file": fileName])
                } catch {
                    let errorMsg = "Failed to clear \(fileName): \(error.localizedDescription)"
                    errors.append(errorMsg)
                    logger.error("Failed to clear handler status file", metadata: [
                        "file": fileName,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
        
        logger.info("State clearing completed", metadata: [
            "cleared_count": String(clearedFiles.count),
            "error_count": String(errors.count)
        ])
        
        return (clearedFiles, errors)
    }
    
    /// Clear all debug files
    /// - Returns: Result containing list of cleared files and any errors
    public func clearDebugFiles() async -> (clearedFiles: [String], errors: [String]) {
        var clearedFiles: [String] = []
        var errors: [String] = []
        let fm = FileManager.default
        
        let debugDir = HavenFilePaths.debugDirectory
        if fm.fileExists(atPath: debugDir.path) {
            do {
                let contents = try fm.contentsOfDirectory(at: debugDir, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    do {
                        try fm.removeItem(at: fileURL)
                        clearedFiles.append(fileURL.path)
                        logger.info("Cleared debug file", metadata: ["file": fileURL.lastPathComponent])
                    } catch {
                        let errorMsg = "Failed to clear \(fileURL.lastPathComponent): \(error.localizedDescription)"
                        errors.append(errorMsg)
                        logger.error("Failed to clear debug file", metadata: [
                            "file": fileURL.lastPathComponent,
                            "error": error.localizedDescription
                        ])
                    }
                }
            } catch {
                let errorMsg = "Failed to enumerate debug directory: \(error.localizedDescription)"
                errors.append(errorMsg)
                logger.error("Failed to enumerate debug directory", metadata: ["error": error.localizedDescription])
            }
        }
        
        logger.info("Debug files clearing completed", metadata: [
            "cleared_count": String(clearedFiles.count),
            "error_count": String(errors.count)
        ])
        
        return (clearedFiles, errors)
    }
    
    /// Clear all state files and debug files
    /// Convenience method that calls both clearAllState() and clearDebugFiles()
    /// - Returns: Combined result with all cleared files and errors
    public func clearAll() async -> (clearedFiles: [String], errors: [String]) {
        let (stateFiles, stateErrors) = await clearAllState()
        let (debugFiles, debugErrors) = await clearDebugFiles()
        
        return (
            clearedFiles: stateFiles + debugFiles,
            errors: stateErrors + debugErrors
        )
    }
    
    /// Get list of all state files that would be cleared
    /// Useful for displaying to users before clearing
    /// - Returns: Array of file paths that exist and would be cleared
    public func listStateFiles() async -> [String] {
        var files: [String] = []
        let fm = FileManager.default
        
        // Collector state files
        let collectorStateFiles = [
            "localfs_collector_state.json",
            "icloud_drive_collector_state.json",
            "contacts_collector_state.json",
            "imessage_state.json",
            "email_collector_state_run.json",
            "email_collector.lock"
        ]
        
        for fileName in collectorStateFiles {
            let fileURL = HavenFilePaths.stateFile(fileName)
            if fm.fileExists(atPath: fileURL.path) {
                files.append(fileURL.path)
            }
        }
        
        // IMAP state files
        let remoteMailDir = HavenFilePaths.remoteMailCacheDirectory
        if fm.fileExists(atPath: remoteMailDir.path) {
            if let contents = try? fm.contentsOfDirectory(at: remoteMailDir, includingPropertiesForKeys: nil) {
                for fileURL in contents {
                    if fileURL.lastPathComponent.hasPrefix("imap_state_") && fileURL.pathExtension == "json" {
                        files.append(fileURL.path)
                    }
                }
            }
        }
        
        // Handler status files
        let handlerStatusFiles = [
            "imessage_handler_state.json",
            "imap_handler_state.json"
        ]
        
        for fileName in handlerStatusFiles {
            let fileURL = HavenFilePaths.cacheFile(fileName)
            if fm.fileExists(atPath: fileURL.path) {
                files.append(fileURL.path)
            }
        }
        
        return files
    }
    
    /// Get list of all debug files that would be cleared
    /// - Returns: Array of file paths that exist and would be cleared
    public func listDebugFiles() async -> [String] {
        var files: [String] = []
        let fm = FileManager.default
        
        let debugDir = HavenFilePaths.debugDirectory
        if fm.fileExists(atPath: debugDir.path) {
            if let contents = try? fm.contentsOfDirectory(at: debugDir, includingPropertiesForKeys: nil) {
                for fileURL in contents {
                    files.append(fileURL.path)
                }
            }
        }
        
        return files
    }
}

