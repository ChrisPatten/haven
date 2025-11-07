//
//  FullDiskAccessChecker.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation

/// Utility to check if the app has full disk access by attempting to access protected directories
struct FullDiskAccessChecker {
    /// Checks if the app has full disk access by attempting to list a protected directory
    /// Uses ~/Library/Safari as a test since it requires full disk access
    /// Returns true if access is granted, false otherwise
    static func checkFullDiskAccess() -> Bool {
        // Try accessing a protected directory that requires full disk access
        // ~/Library/Safari is a good test case
        let protectedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Safari")
        
        do {
            // Try to list contents of the protected directory
            // This requires full disk access on macOS
            _ = try FileManager.default.contentsOfDirectory(atPath: protectedPath.path)
            // If we can list contents, we have full disk access
            return true
        } catch {
            // Check if the error is specifically a permission error
            let nsError = error as NSError
            if nsError.code == NSFileReadNoPermissionError || nsError.domain == NSCocoaErrorDomain {
                // Permission denied - full disk access not granted
                return false
            }
            // For other errors (e.g., directory doesn't exist), try a fallback check
            // Try ~/Library itself as a fallback
            return checkLibraryAccess()
        }
    }
    
    /// Fallback check using ~/Library directory
    private static func checkLibraryAccess() -> Bool {
        let libraryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
        
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: libraryPath.path)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.code == NSFileReadNoPermissionError || nsError.domain == NSCocoaErrorDomain {
                return false
            }
            // If directory doesn't exist or other error, assume we don't have access
            return false
        }
    }
}

