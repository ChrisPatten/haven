//
//  ContactsPermissionChecker.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import Foundation
import Contacts

/// Utility to check if the app has contacts permission
struct ContactsPermissionChecker {
    /// Checks if the app has contacts permission
    /// Returns true if permission is granted, false otherwise
    static func checkContactsPermission() -> Bool {
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        return authStatus == .authorized
    }
    
    /// Requests contacts permission, showing the native dialog if needed
    /// Returns true if permission is granted, false otherwise
    /// Note: If permission was previously denied, the dialog won't appear and user must grant via System Settings
    static func requestContactsPermission() async -> Bool {
        let store = CNContactStore()
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        
        switch authStatus {
        case .authorized:
            return true
        case .notDetermined:
            // Request permission - this will show the native dialog
            do {
                let granted = try await store.requestAccess(for: .contacts)
                return granted
            } catch {
                print("Error requesting contacts permission: \(error)")
                return false
            }
        case .denied, .restricted:
            // Permission was previously denied - can't show dialog, must go to System Settings
            // Return false to indicate permission is not granted
            return false
        @unknown default:
            return false
        }
    }
}

