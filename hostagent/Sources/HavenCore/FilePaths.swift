import Foundation

/// Centralized file path management following macOS conventions
/// Shared between Haven.app and hostagent
public struct HavenFilePaths {
    private static let appName = "Haven"
    
    // MARK: - Base Directories
    
    /// Application Support directory: ~/Library/Application Support/Haven
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }
    
    /// Caches directory: ~/Library/Caches/Haven
    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }
    
    /// Logs directory: ~/Library/Logs/Haven
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
    public static func configFile(_ name: String) -> URL {
        let fileName = name.hasSuffix(".plist") ? name : "\(name).plist"
        return configDirectory.appendingPathComponent(fileName)
    }
    
    // MARK: - State Files
    
    /// State directory: ~/Library/Application Support/Haven/State
    public static var stateDirectory: URL {
        applicationSupport.appendingPathComponent("State", isDirectory: true)
    }
    
    /// Get path to a state file
    public static func stateFile(_ name: String) -> URL {
        return stateDirectory.appendingPathComponent(name)
    }
    
    // MARK: - Cache Files
    
    /// Cache directory: ~/Library/Caches/Haven
    public static var cacheDirectory: URL {
        caches
    }
    
    /// Get path to a cache file
    public static func cacheFile(_ name: String) -> URL {
        return cacheDirectory.appendingPathComponent(name)
    }
    
    /// Remote mail cache directory: ~/Library/Caches/Haven/remote_mail
    public static var remoteMailCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("remote_mail", isDirectory: true)
    }
    
    // MARK: - Backup Files
    
    /// Backups directory: ~/Library/Application Support/Haven/Backups
    public static var backupsDirectory: URL {
        applicationSupport.appendingPathComponent("Backups", isDirectory: true)
    }
    
    /// Chat backup directory: ~/Library/Application Support/Haven/Backups/chat_backup
    public static var chatBackupDirectory: URL {
        backupsDirectory.appendingPathComponent("chat_backup", isDirectory: true)
    }
    
    // MARK: - Log Files
    
    /// Logs directory: ~/Library/Logs/Haven
    public static var logsDirectory: URL {
        logs
    }
    
    /// Get path to a log file
    public static func logFile(_ name: String) -> URL {
        return logsDirectory.appendingPathComponent(name)
    }
    
    // MARK: - Debug Files
    
    /// Debug directory: ~/Library/Application Support/Haven/Debug
    public static var debugDirectory: URL {
        applicationSupport.appendingPathComponent("Debug", isDirectory: true)
    }
    
    /// Get path to a debug file
    public static func debugFile(_ name: String) -> URL {
        return debugDirectory.appendingPathComponent(name)
    }
    
    // MARK: - Directory Initialization
    
    /// Ensure all required directories exist
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
}

