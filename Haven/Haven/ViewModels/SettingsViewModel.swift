//
//  SettingsViewModel.swift
//  Haven
//
//  Centralized settings management ViewModel
//  Eliminates race conditions by providing a single source of truth
//

import Foundation
import Combine
import HavenCore

/// Centralized ViewModel for all settings management
/// Provides a single source of truth and eliminates race conditions
@MainActor
class SettingsViewModel: ObservableObject {
    let configManager: ConfigManager
    private let logger = HavenLogger(category: "settings-viewmodel")
    
    // MARK: - Published State
    
    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?
    
    // MARK: - Configuration State (Single Source of Truth)
    
    @Published var systemConfig: SystemConfig?
    @Published var emailConfig: EmailInstancesConfig?
    @Published var filesConfig: FilesInstancesConfig?
    @Published var icloudDriveConfig: ICloudDriveInstancesConfig?
    @Published var contactsConfig: ContactsInstancesConfig?
    @Published var imessageConfig: IMessageInstanceConfig?
    @Published var remindersConfig: RemindersInstanceConfig?
    @Published var schedulesConfig: CollectorSchedulesConfig?
    
    // MARK: - Initialization
    
    init(configManager: ConfigManager) {
        self.configManager = configManager
    }
    
    // MARK: - Loading
    
    /// Load all configurations from disk
    /// Should be called once when SettingsWindow appears
    func loadAllConfigurations() async {
        guard !isLoading else { return }
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            // Load all configs in parallel
            async let system = configManager.loadSystemConfig()
            async let email = configManager.loadEmailConfig()
            async let files = configManager.loadFilesConfig()
            async let icloud = configManager.loadICloudDriveConfig()
            async let contacts = configManager.loadContactsConfig()
            async let imessage = configManager.loadIMessageConfig()
            async let reminders = configManager.loadRemindersConfig()
            async let schedules = configManager.loadSchedulesConfig()
            
            // Wait for all to complete
            systemConfig = try await system
            emailConfig = try await email
            filesConfig = try await files
            icloudDriveConfig = try await icloud
            contactsConfig = try await contacts
            imessageConfig = try await imessage
            remindersConfig = try await reminders
            schedulesConfig = try await schedules
            
            logger.info("All configurations loaded successfully")
        } catch {
            errorMessage = "Failed to load configuration: \(error.localizedDescription)"
            logger.error("Failed to load configurations", metadata: ["error": error.localizedDescription])
        }
    }
    
    // MARK: - Saving
    
    /// Save all modified configurations to disk
    /// Posts notification when complete to trigger HostAgentController reload
    func saveAllConfigurations() async {
        guard !isSaving else { return }
        
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        
        do {
            // Save all configs that are not nil
            if let systemConfig = systemConfig {
                try await configManager.saveSystemConfig(systemConfig)
            }
            if let emailConfig = emailConfig {
                try await configManager.saveEmailConfig(emailConfig)
            }
            if let filesConfig = filesConfig {
                try await configManager.saveFilesConfig(filesConfig)
            }
            if let icloudDriveConfig = icloudDriveConfig {
                try await configManager.saveICloudDriveConfig(icloudDriveConfig)
            }
            if let contactsConfig = contactsConfig {
                try await configManager.saveContactsConfig(contactsConfig)
            }
            if let imessageConfig = imessageConfig {
                try await configManager.saveIMessageConfig(imessageConfig)
            }
            if let remindersConfig = remindersConfig {
                try await configManager.saveRemindersConfig(remindersConfig)
            }
            if let schedulesConfig = schedulesConfig {
                try await configManager.saveSchedulesConfig(schedulesConfig)
            }
            
            // Clear cache and notify HostAgentController
            await configManager.clearCache()
            NotificationCenter.default.post(name: .settingsConfigSaved, object: nil)
            
            logger.info("All configurations saved successfully")
        } catch {
            errorMessage = "Failed to save configuration: \(error.localizedDescription)"
            logger.error("Failed to save configurations", metadata: ["error": error.localizedDescription])
        }
    }
    
    // MARK: - Individual Config Updates
    
    /// Update system config (creates new instance to trigger SwiftUI updates)
    func updateSystemConfig(_ updater: (inout SystemConfig) -> Void) {
        guard var config = systemConfig else { return }
        updater(&config)
        systemConfig = config
    }
    
    /// Update email config
    func updateEmailConfig(_ updater: (inout EmailInstancesConfig) -> Void) {
        guard var config = emailConfig else { return }
        updater(&config)
        emailConfig = config
    }
    
    /// Update files config
    func updateFilesConfig(_ updater: (inout FilesInstancesConfig) -> Void) {
        guard var config = filesConfig else { return }
        updater(&config)
        filesConfig = config
    }
    
    /// Update iCloud Drive config
    func updateICloudDriveConfig(_ updater: (inout ICloudDriveInstancesConfig) -> Void) {
        guard var config = icloudDriveConfig else { return }
        updater(&config)
        icloudDriveConfig = config
    }
    
    /// Update contacts config
    func updateContactsConfig(_ updater: (inout ContactsInstancesConfig) -> Void) {
        guard var config = contactsConfig else { return }
        updater(&config)
        contactsConfig = config
    }
    
    /// Update iMessage config
    func updateIMessageConfig(_ updater: (inout IMessageInstanceConfig) -> Void) {
        guard var config = imessageConfig else { return }
        updater(&config)
        imessageConfig = config
    }
    
    /// Update reminders config
    func updateRemindersConfig(_ updater: (inout RemindersInstanceConfig) -> Void) {
        guard var config = remindersConfig else { return }
        updater(&config)
        remindersConfig = config
    }
    
    /// Update schedules config
    func updateSchedulesConfig(_ updater: (inout CollectorSchedulesConfig) -> Void) {
        guard var config = schedulesConfig else { return }
        updater(&config)
        schedulesConfig = config
    }
}

