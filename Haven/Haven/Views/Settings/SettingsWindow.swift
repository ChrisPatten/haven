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
    @StateObject private var viewModel = SettingsViewModel(configManager: ConfigManager())
    @State private var selectedSection: SettingsSection = .general
    
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
                    GeneralSettingsView(viewModel: viewModel)
                case .imessage:
                    IMessageSettingsView(viewModel: viewModel)
                case .reminders:
                    RemindersSettingsView(viewModel: viewModel)
                case .email:
                    EmailSettingsView(viewModel: viewModel)
                case .files:
                    FilesSettingsView(viewModel: viewModel)
                case .icloudDrive:
                    ICloudDriveSettingsView(viewModel: viewModel)
                case .contacts:
                    ContactsSettingsView(viewModel: viewModel)
                case .schedules:
                    SchedulesSettingsView(viewModel: viewModel)
                case .enrichment:
                    EnrichmentSettingsView(errorMessage: .constant(viewModel.errorMessage))
                case .advanced:
                    AdvancedSettingsView(viewModel: viewModel)
                case .dataManagement:
                    DataManagementSettingsView(errorMessage: .constant(viewModel.errorMessage))
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    if viewModel.isLoading || viewModel.isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Button("Save") {
                        Task {
                            await viewModel.saveAllConfigurations()
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.isSaving)
                }
            }
        }
        .task {
            await viewModel.loadAllConfigurations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsToSection)) { notification in
            if let section = notification.object as? SettingsSection {
                selectedSection = section
            }
        }
    }
}

#Preview {
    SettingsWindow()
}
