//
//  HavenFilePaths.swift
//  Haven
//
//  Centralized file path management following macOS conventions
//  Uses standard Library directories: Application Support, Caches, Logs
//

import Foundation

/// Centralized file path management following macOS conventions
public struct HavenFilePaths {
    private static let appName = "Haven"
    
    // MARK: - Base Directories
    
    /// Application Support directory: ~/Library/Application Support/Haven
    /// For persistent data that should survive app deletion
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }
    
    /// Caches directory: ~/Library/Caches/Haven
    /// For regenerable data that can be cleared
    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }
    
    /// Logs directory: ~/Library/Logs/Haven
    /// For log files
    public static var logs: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
    }
    
    // MARK: - Configuration Files
    
    /// Configuration directory: ~/Library/Application Support/Haven/Config
    public static var configDirectory: URL {
        applicationSupport.appendingPathComponent("Config", isDirectory: true)
    }
    
    /// Get path to a configuration file
    /// - Parameter name: Configuration file name (without .plist extension)
    /// - Returns: Full URL to the configuration file
    public static func configFile(_ name: String) -> URL {
        let fileName = name.hasSuffix(".plist") ? name : "\(name).plist"
        return configDirectory.appendingPathComponent(fileName)
    }
    
    // MARK: - State Files
    
    /// State directory: ~/Library/Application Support/Haven/State
    /// For collector state files (fences, hashes) that track what's been processed
    public static var stateDirectory: URL {
        applicationSupport.appendingPathComponent("State", isDirectory: true)
    }
    
    /// Get path to a state file
    /// - Parameter name: State file name (e.g., "localfs_collector_state.json")
    /// - Returns: Full URL to the state file
    public static func stateFile(_ name: String) -> URL {
        return stateDirectory.appendingPathComponent(name)
    }
    
    // MARK: - Cache Files
    
    /// Cache directory: ~/Library/Caches/Haven
    /// For handler status files and other regenerable data
    public static var cacheDirectory: URL {
        caches
    }
    
    /// Get path to a cache file
    /// - Parameter name: Cache file name
    /// - Returns: Full URL to the cache file
    public static func cacheFile(_ name: String) -> URL {
        return cacheDirectory.appendingPathComponent(name)
    }
    
    /// Remote mail cache directory: ~/Library/Caches/Haven/remote_mail
    /// For IMAP state files
    public static var remoteMailCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("remote_mail", isDirectory: true)
    }
    
    // MARK: - Backup Files
    
    /// Backups directory: ~/Library/Application Support/Haven/Backups
    /// For database snapshots and backups
    public static var backupsDirectory: URL {
        applicationSupport.appendingPathComponent("Backups", isDirectory: true)
    }
    
    /// Chat backup directory: ~/Library/Application Support/Haven/Backups/chat_backup
    /// For Messages.app database snapshots
    public static var chatBackupDirectory: URL {
        backupsDirectory.appendingPathComponent("chat_backup", isDirectory: true)
    }
    
    // MARK: - Log Files
    
    /// Logs directory: ~/Library/Logs/Haven
    public static var logsDirectory: URL {
        logs
    }
    
    /// Get path to a log file
    /// - Parameter name: Log file name
    /// - Returns: Full URL to the log file
    public static func logFile(_ name: String) -> URL {
        return logsDirectory.appendingPathComponent(name)
    }
    
    // MARK: - Debug Files
    
    /// Debug directory: ~/Library/Application Support/Haven/Debug
    /// For debug output files
    public static var debugDirectory: URL {
        applicationSupport.appendingPathComponent("Debug", isDirectory: true)
    }
    
    /// Get path to a debug file
    /// - Parameter name: Debug file name
    /// - Returns: Full URL to the debug file
    public static func debugFile(_ name: String) -> URL {
        return debugDirectory.appendingPathComponent(name)
    }
    
    // MARK: - Directory Initialization
    
    /// Ensure all required directories exist
    /// Creates all directories with intermediate directories as needed
    /// - Throws: File system errors if directory creation fails
    public static func initializeDirectories() throws {
        let directories = [
            configDirectory,
            stateDirectory,
            cacheDirectory,
            remoteMailCacheDirectory,
            backupsDirectory,
            chatBackupDirectory,
            logsDirectory,
            debugDirectory
        ]
        
        let fm = FileManager.default
        for directory in directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Legacy Path Support (for migration)
    
    /// Legacy config directory: ~/.haven
    /// Used for reading existing configs during migration
    public static var legacyConfigDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".haven", isDirectory: true)
    }
    
    /// Legacy state directory: ~/.haven
    /// Used for reading existing state files during migration
    public static var legacyStateDirectory: URL {
        legacyConfigDirectory
    }
    
    /// Legacy cache directory: ~/.haven/cache
    /// Used for reading existing cache files during migration
    public static var legacyCacheDirectory: URL {
        legacyConfigDirectory.appendingPathComponent("cache", isDirectory: true)
    }
}

