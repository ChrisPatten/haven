//
//  CollectorWizardView.swift
//  Haven
//
//  Created by Codex on 11/8/25.
//

import SwiftUI

struct CollectorWizardResult {
    let collectorId: String
}

struct CollectorWizardView: View {
    enum Step {
        case chooseType
        case configure
    }
    
    enum CollectorType: String, CaseIterable, Identifiable {
        case imap
        case files
        case contacts
        case icloudDrive
        
        var id: String { rawValue }
        
        var title: String {
            switch self {
            case .imap: return "Email (IMAP)"
            case .files: return "Local Files"
            case .contacts: return "Contacts"
            case .icloudDrive: return "iCloud Drive"
            }
        }
        
        var description: String {
            switch self {
            case .imap: return "Connect IMAP mailboxes for receipts, newsletters, or archives."
            case .files: return "Watch folders on disk for documents and knowledge."
            case .contacts: return "Sync macOS Contacts or VCF exports."
            case .icloudDrive: return "Ingest shared folders from iCloud Drive."
            }
        }
        
        var icon: String {
            switch self {
            case .imap: return "envelope.fill"
            case .files: return "folder.fill"
            case .contacts: return "person.2.fill"
            case .icloudDrive: return "icloud.fill"
            }
        }
    }
    
    let onComplete: (CollectorWizardResult) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .chooseType
    @State private var selectedType: CollectorType?
    @State private var isSaving = false
    
    // Form data
    @State private var imapData = ImapFormData()
    @State private var filesData = FilesFormData()
    @State private var contactsData = ContactsFormData()
    @State private var icloudData = ICloudFormData()
    
    private let coordinator = CollectorWizardCoordinator()
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .chooseType:
                    chooseTypeView
                case .configure:
                    if let selectedType {
                        configurationView(for: selectedType)
                    }
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Add Collector")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == .chooseType ? "Continue" : "Save") {
                        if step == .chooseType {
                            step = .configure
                        } else {
                            save()
                        }
                    }
                    .disabled(!canProceed)
                }
            }
        }
    }
    
    private var chooseTypeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select collector type")
                .font(.headline)
            Text("Bring new sources into Haven. You can configure IMAP mailboxes, folder watchers, contacts, or cloud storage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(CollectorType.allCases) { type in
                    Button {
                        withAnimation {
                            selectedType = type
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: type.icon)
                                .font(.title2)
                                .foregroundStyle(HavenColors.textPrimary)
                            
                            Text(type.title)
                                .font(.headline)
                                .foregroundStyle(HavenColors.textPrimary)
                            Text(type.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(selectedType == type ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(selectedType == type ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    @ViewBuilder
    private func configurationView(for type: CollectorType) -> some View {
        switch type {
        case .imap:
            ImapConfigurationView(data: $imapData)
        case .files:
            FilesConfigurationView(data: $filesData)
        case .contacts:
            ContactsConfigurationView(data: $contactsData)
        case .icloudDrive:
            ICloudConfigurationView(data: $icloudData)
        }
    }
    
    private var canProceed: Bool {
        switch step {
        case .chooseType:
            return selectedType != nil
        case .configure:
            guard let selectedType else { return false }
            switch selectedType {
            case .imap:
                return imapData.isValid && !isSaving
            case .files:
                return filesData.isValid && !isSaving
            case .contacts:
                return contactsData.isValid && !isSaving
            case .icloudDrive:
                return icloudData.isValid && !isSaving
            }
        }
    }
    
    private func save() {
        guard let selectedType else { return }
        isSaving = true
        
        Task {
            do {
                let collectorId: String
                switch selectedType {
                case .imap:
                    collectorId = try await coordinator.createImapCollector(data: imapData)
                case .files:
                    collectorId = try await coordinator.createFilesCollector(data: filesData)
                case .contacts:
                    collectorId = try await coordinator.createContactsCollector(data: contactsData)
                case .icloudDrive:
                    collectorId = try await coordinator.createICloudCollector(data: icloudData)
                }
                
                await MainActor.run {
                    isSaving = false
                    NotificationCenter.default.post(name: .settingsConfigSaved, object: nil)
                    dismiss()
                    onComplete(CollectorWizardResult(collectorId: collectorId))
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    onError(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Form Data Models

struct ImapFormData {
    var displayName: String = ""
    var emailAddress: String = ""
    var host: String = ""
    var port: Int = 993
    var useTLS: Bool = true
    var username: String = ""
    var secretRef: String = ""
    var folders: String = "INBOX"
    
    var isValid: Bool {
        !displayName.isEmpty && !emailAddress.isEmpty && !host.isEmpty && !username.isEmpty && !secretRef.isEmpty
    }
}

struct FilesFormData {
    var name: String = ""
    var path: String = ""
    var includeGlobs: String = "*.pdf, *.md, *.txt"
    var excludeGlobs: String = ""
    
    var isValid: Bool {
        !name.isEmpty && !path.isEmpty
    }
}

struct ContactsFormData {
    var name: String = ""
    var sourceType: ContactsSourceType = .macOSContacts
    var vcfDirectory: String = ""
    
    var isValid: Bool {
        if sourceType == .vcf {
            return !name.isEmpty && !vcfDirectory.isEmpty
        } else {
            return !name.isEmpty
        }
    }
}

struct ICloudFormData {
    var name: String = ""
    var path: String = ""
    
    var isValid: Bool {
        !name.isEmpty
    }
}

// MARK: - Configuration Forms

private struct ImapConfigurationView: View {
    @Binding var data: ImapFormData
    
    var body: some View {
        Form {
            Section("Account") {
                TextField("Display Name", text: $data.displayName)
                TextField("Email Address", text: $data.emailAddress)
                TextField("Username", text: $data.username)
                SecureField("Secret Reference", text: $data.secretRef)
            }
            
            Section("Server") {
                TextField("Host", text: $data.host)
                Stepper(value: $data.port, in: 1...65535) {
                    Text("Port: \(data.port)")
                }
                Toggle("Use TLS", isOn: $data.useTLS)
                TextField("Folders (comma separated)", text: $data.folders)
            }
        }
    }
}

private struct FilesConfigurationView: View {
    @Binding var data: FilesFormData
    
    var body: some View {
        Form {
            Section("Source") {
                TextField("Display Name", text: $data.name)
                TextField("Folder", text: $data.path)
            }
            
            Section("Filters") {
                TextField("Include patterns", text: $data.includeGlobs)
                TextField("Exclude patterns", text: $data.excludeGlobs)
            }
        }
    }
}

private struct ContactsConfigurationView: View {
    @Binding var data: ContactsFormData
    
    var body: some View {
        Form {
            Section("Source") {
                TextField("Display Name", text: $data.name)
                Picker("Source Type", selection: $data.sourceType) {
                    Text("macOS Contacts").tag(ContactsSourceType.macOSContacts)
                    Text("VCF Folder").tag(ContactsSourceType.vcf)
                }
                if data.sourceType == .vcf {
                    TextField("VCF Directory", text: $data.vcfDirectory)
                }
            }
        }
    }
}

private struct ICloudConfigurationView: View {
    @Binding var data: ICloudFormData
    
    var body: some View {
        Form {
            Section("Source") {
                TextField("Display Name", text: $data.name)
                TextField("Path (optional)", text: $data.path)
            }
        }
    }
}

// MARK: - Coordinator

@MainActor
final class CollectorWizardCoordinator {
    private let configManager = ConfigManager()
    
    func createImapCollector(data: ImapFormData) async throws -> String {
        var config = try await configManager.loadEmailConfig()
        let instance = EmailInstance(
            id: sanitizedId(from: data.emailAddress),
            displayName: data.displayName,
            type: "imap",
            enabled: true,
            host: data.host,
            port: data.port,
            tls: data.useTLS,
            username: data.username,
            auth: EmailAuthConfig(kind: "app_password", secretRef: data.secretRef),
            folders: data.folders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
        config.instances.append(instance)
        try await configManager.saveEmailConfig(config)
        return "email_imap:\(instance.id)"
    }
    
    func createFilesCollector(data: FilesFormData) async throws -> String {
        var config = try await configManager.loadFilesConfig()
        let instance = FilesInstance(
            name: data.name,
            paths: [data.path],
            includeGlobs: data.includeGlobs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            excludeGlobs: data.excludeGlobs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        config.instances.append(instance)
        try await configManager.saveFilesConfig(config)
        return "localfs:\(instance.id)"
    }
    
    func createContactsCollector(data: ContactsFormData) async throws -> String {
        var config = try await configManager.loadContactsConfig()
        let instance = ContactsInstance(
            name: data.name,
            enabled: true,
            sourceType: data.sourceType,
            vcfDirectory: data.sourceType == .vcf ? data.vcfDirectory : nil
        )
        config.instances.append(instance)
        try await configManager.saveContactsConfig(config)
        return "contacts:\(instance.id)"
    }
    
    func createICloudCollector(data: ICloudFormData) async throws -> String {
        var config = try await configManager.loadICloudDriveConfig()
        let instance = ICloudDriveInstance(
            name: data.name,
            enabled: true,
            path: data.path.isEmpty ? nil : data.path
        )
        config.instances.append(instance)
        try await configManager.saveICloudDriveConfig(config)
        return "icloud_drive:\(instance.id)"
    }
    
    private func sanitizedId(from value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(filtered).lowercased()
    }
}
