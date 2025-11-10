//
//  SettingsWindow.swift
//  Haven
//
//  Main Settings window with sidebar navigation
//  Following HIG patterns for macOS settings
//

import SwiftUI
import AppKit
import Combine

/// Main Settings window with sidebar navigation
struct SettingsWindow: View {
    @StateObject private var configManagerWrapper = ConfigManagerWrapper()
    @State private var selectedSection: SettingsSection = .general
    @State private var systemConfig: SystemConfig?
    @State private var emailConfig: EmailInstancesConfig?
    @State private var filesConfig: FilesInstancesConfig?
    @State private var icloudDriveConfig: ICloudDriveInstancesConfig?
    @State private var contactsConfig: ContactsInstancesConfig?
    @State private var imessageConfig: IMessageInstanceConfig?
    @State private var remindersConfig: RemindersInstanceConfig?
    @State private var schedulesConfig: CollectorSchedulesConfig?
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case imessage = "iMessage"
        case reminders = "Reminders"
        case email = "Email"
        case files = "Files"
        case icloudDrive = "iCloud Drive"
        case contacts = "Contacts"
        case schedules = "Schedules"
        case enrichment = "Enrichment"
        case advanced = "Advanced"
        case dataManagement = "Data Management"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .imessage: return "message"
            case .reminders: return "checklist"
            case .email: return "envelope"
            case .files: return "folder"
            case .icloudDrive: return "icloud"
            case .contacts: return "person.crop.circle"
            case .schedules: return "calendar"
            case .enrichment: return "sparkles"
            case .advanced: return "slider.horizontal.3"
            case .dataManagement: return "externaldrive"
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            .navigationTitle("Settings")
            .frame(minWidth: 200)
        } detail: {
            // Detail view
            Group {
                switch selectedSection {
                case .general:
                    GeneralSettingsView(
                        config: $systemConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .imessage:
                    IMessageSettingsView(
                        config: $imessageConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .reminders:
                    RemindersSettingsView(
                        config: $remindersConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .email:
                    EmailSettingsView(
                        config: $emailConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .files:
                    FilesSettingsView(
                        config: $filesConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .icloudDrive:
                    ICloudDriveSettingsView(
                        config: $icloudDriveConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .contacts:
                    ContactsSettingsView(
                        config: $contactsConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .schedules:
                    SchedulesSettingsView(
                        config: $schedulesConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .enrichment:
                    EnrichmentSettingsView(errorMessage: $errorMessage)
                case .advanced:
                    AdvancedSettingsView(
                        systemConfig: $systemConfig,
                        configManager: configManagerWrapper.configManager,
                        errorMessage: $errorMessage
                    )
                case .dataManagement:
                    DataManagementSettingsView(errorMessage: $errorMessage)
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Save") {
                    saveAllConfigurations()
                }
                .disabled(isLoading)
            }
        }
        .task {
            await loadAllConfigurations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsToSection)) { notification in
            if let section = notification.object as? SettingsSection {
                selectedSection = section
            }
        }
    }
    
    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        let manager = configManagerWrapper.configManager
        switch section {
        case .general:
            GeneralSettingsView(
                config: $systemConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .imessage:
            IMessageSettingsView(
                config: $imessageConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .reminders:
            RemindersSettingsView(
                config: $remindersConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .email:
            EmailSettingsView(
                config: $emailConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .files:
            FilesSettingsView(
                config: $filesConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .icloudDrive:
            ICloudDriveSettingsView(
                config: $icloudDriveConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .contacts:
            ContactsSettingsView(
                config: $contactsConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .schedules:
            SchedulesSettingsView(
                config: $schedulesConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .enrichment:
            EnrichmentSettingsView(errorMessage: $errorMessage)
        case .advanced:
            AdvancedSettingsView(
                systemConfig: $systemConfig,
                configManager: manager,
                errorMessage: $errorMessage
            )
        case .dataManagement:
            DataManagementSettingsView(errorMessage: $errorMessage)
        }
    }
    
    private func loadAllConfigurations() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            systemConfig = try await configManagerWrapper.configManager.loadSystemConfig()
            emailConfig = try await configManagerWrapper.configManager.loadEmailConfig()
            filesConfig = try await configManagerWrapper.configManager.loadFilesConfig()
            icloudDriveConfig = try await configManagerWrapper.configManager.loadICloudDriveConfig()
            contactsConfig = try await configManagerWrapper.configManager.loadContactsConfig()
            imessageConfig = try await configManagerWrapper.configManager.loadIMessageConfig()
            remindersConfig = try await configManagerWrapper.configManager.loadRemindersConfig()
            schedulesConfig = try await configManagerWrapper.configManager.loadSchedulesConfig()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load configuration: \(error.localizedDescription)"
        }
    }
    
    private func saveAllConfigurations() {
        Task {
            isLoading = true
            defer { isLoading = false }
            
            do {
                if let systemConfig = systemConfig {
                    try await configManagerWrapper.configManager.saveSystemConfig(systemConfig)
                }
                if let emailConfig = emailConfig {
                    try await configManagerWrapper.configManager.saveEmailConfig(emailConfig)
                }
                if let filesConfig = filesConfig {
                    try await configManagerWrapper.configManager.saveFilesConfig(filesConfig)
                }
                if let icloudDriveConfig = icloudDriveConfig {
                    try await configManagerWrapper.configManager.saveICloudDriveConfig(icloudDriveConfig)
                }
                if let contactsConfig = contactsConfig {
                    try await configManagerWrapper.configManager.saveContactsConfig(contactsConfig)
                }
                if let imessageConfig = imessageConfig {
                    try await configManagerWrapper.configManager.saveIMessageConfig(imessageConfig)
                }
                if let remindersConfig = remindersConfig {
                    try await configManagerWrapper.configManager.saveRemindersConfig(remindersConfig)
                }
                if let schedulesConfig = schedulesConfig {
                    try await configManagerWrapper.configManager.saveSchedulesConfig(schedulesConfig)
                }
                errorMessage = nil
                
                // Post notification that config was saved so collectors view can refresh
                NotificationCenter.default.post(name: .settingsConfigSaved, object: nil)
            } catch {
                errorMessage = "Failed to save configuration: \(error.localizedDescription)"
            }
        }
    }
}

/// ObservableObject wrapper for ConfigManager actor
final class ConfigManagerWrapper: ObservableObject {
    nonisolated let configManager = ConfigManager()
}

#Preview {
    SettingsWindow()
}

