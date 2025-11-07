//
//  ContactsSettingsView.swift
//  Haven
//
//  Contacts collector instances management view
//

import SwiftUI
import AppKit
import Contacts

/// Contacts settings view for managing contact source instances
struct ContactsSettingsView: View {
    @Binding var config: ContactsInstancesConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var instances: [ContactsInstance] = []
    @State private var selectedInstance: ContactsInstance.ID?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    @State private var contactsPermissionGranted: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Add vcard Source") {
                    showingAddSheet = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("Remove") {
                    removeSelectedInstance()
                }
                .disabled(selectedInstance == nil || isMacOSContactsInstance(selectedInstance))
                
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Contacts permission banner
            if !contactsPermissionGranted {
                ContactsPermissionBanner(contactsPermissionGranted: $contactsPermissionGranted)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            
            // Table view
            if instances.isEmpty {
                VStack {
                    Text("No contact source instances configured")
                        .foregroundColor(.secondary)
                    Text("Click 'Add vcard Source' to configure a VCF directory source")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(instances, selection: $selectedInstance) {
                    TableColumn("Name") { instance in
                        Text(instance.name.isEmpty ? instance.id : instance.name)
                    }
                    TableColumn("Source Type") { instance in
                        Text(instance.sourceType == .macOSContacts ? "macOS Contacts" : "VCF Directory")
                    }
                    TableColumn("Path") { instance in
                        Text(instance.vcfDirectory ?? "")
                            .foregroundColor(.secondary)
                    }
                    TableColumn("Enabled") { instance in
                        Toggle("", isOn: Binding(
                            get: { instance.enabled },
                            set: { newValue in
                                if let index = instances.firstIndex(where: { $0.id == instance.id }) {
                                    instances[index].enabled = newValue
                                    updateConfiguration()
                                    
                                    // Check contacts permission when macOS Contacts instance is enabled
                                    if instance.sourceType == .macOSContacts && newValue {
                                        Task {
                                            await checkContactsPermission()
                                        }
                                    }
                                }
                            }
                        ))
                    }
                    TableColumn("") { instance in
                        Button(action: {
                            selectedInstance = instance.id
                            showingEditSheet = true
                        }) {
                            Image(systemName: "pencil")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .width(30)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ContactsInstanceEditSheet(
                instance: nil,
                onSave: { instance in
                    instances.append(instance)
                    updateConfiguration()
                }
            )
        }
        .sheet(isPresented: $showingEditSheet) {
            if let selectedId = selectedInstance,
               let instance = instances.first(where: { $0.id == selectedId }) {
                ContactsInstanceEditSheet(
                    instance: instance,
                    onSave: { updatedInstance in
                        if let index = instances.firstIndex(where: { $0.id == updatedInstance.id }) {
                            instances[index] = updatedInstance
                            updateConfiguration()
                            
                            // Check contacts permission when macOS Contacts instance is enabled
                            if updatedInstance.sourceType == .macOSContacts && updatedInstance.enabled {
                                Task {
                                    await checkContactsPermission()
                                }
                            }
                        }
                    }
                )
            }
        }
        .onAppear {
            loadConfiguration()
            // Check permission on appear if macOS Contacts instance is enabled
            if instances.contains(where: { $0.sourceType == .macOSContacts && $0.enabled }) {
                Task {
                    await checkContactsPermission()
                }
            }
        }
        .onChange(of: selectedInstance) { _, newValue in
            // Only auto-open edit sheet if selected from table row click, not from pencil button
            // The pencil button sets showingEditSheet directly
        }
    }
    
    private func checkContactsPermission() async {
        let hasPermission = ContactsPermissionChecker.checkContactsPermission()
        await MainActor.run {
            contactsPermissionGranted = hasPermission
        }
    }
    
    private func loadConfiguration() {
        if let config = config {
            instances = config.instances
        } else {
            instances = []
        }
        
        // Ensure macOS Contacts instance always exists
        if !instances.contains(where: { $0.sourceType == .macOSContacts }) {
            let macInstance = ContactsInstance(
                id: "macos-contacts-default",
                name: "macOS Contacts",
                enabled: false,
                sourceType: .macOSContacts
            )
            instances.insert(macInstance, at: 0) // Add at the beginning
            updateConfiguration()
        }
    }
    
    private func isMacOSContactsInstance(_ instanceId: ContactsInstance.ID?) -> Bool {
        guard let instanceId = instanceId,
              let instance = instances.first(where: { $0.id == instanceId }) else {
            return false
        }
        return instance.sourceType == .macOSContacts
    }
    
    private func updateConfiguration() {
        config = ContactsInstancesConfig(instances: instances)
    }
    
    private func removeSelectedInstance() {
        guard let selectedId = selectedInstance else { return }
        // Don't allow removing macOS Contacts instance
        if let instance = instances.first(where: { $0.id == selectedId }),
           instance.sourceType == .macOSContacts {
            return
        }
        instances.removeAll { $0.id == selectedId }
        selectedInstance = nil
        updateConfiguration()
    }
}

// MARK: - Contacts Permission Banner

struct ContactsPermissionBanner: View {
    @Binding var contactsPermissionGranted: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Contacts Permission Required")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Text("Haven needs access to your contacts to sync them. Click the button below to request access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                Task { @MainActor in
                    await requestContactsPermission()
                }
            }) {
                Label("Request Access", systemImage: "hand.raised.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Color.orange.opacity(0.1)
        }
    }
    
    @MainActor
    private func requestContactsPermission() async {
        // Check current status
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        
        // Handle different authorization states
        switch authStatus {
        case .authorized:
            // Already authorized
            contactsPermissionGranted = true
            return
            
        case .notDetermined:
            // Request permission - this will show the native dialog
            let store = CNContactStore()
            do {
                let granted = try await store.requestAccess(for: .contacts)
                contactsPermissionGranted = granted
                
                // Re-check status after request to ensure it's updated
                let newStatus = CNContactStore.authorizationStatus(for: .contacts)
                contactsPermissionGranted = (newStatus == .authorized)
            } catch {
                // If request fails, check if we need to open System Settings
                let currentStatus = CNContactStore.authorizationStatus(for: .contacts)
                if currentStatus == .denied || currentStatus == .restricted {
                    openSystemSettings()
                }
                contactsPermissionGranted = false
            }
            
        case .denied, .restricted:
            // Permission was previously denied or restricted - must go to System Settings
            openSystemSettings()
            
        @unknown default:
            contactsPermissionGranted = false
        }
    }
    
    private func openSystemSettings() {
        // Deep link to Contacts privacy settings pane
        // This URL scheme works for both System Preferences (macOS Monterey and earlier)
        // and System Settings (macOS Ventura+)
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        
        guard let url = URL(string: urlString) else {
            // Fallback: try to open System Settings app directly
            if let settingsURL = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(settingsURL)
            }
            return
        }
        
        // Open the deep link to Contacts privacy settings
        NSWorkspace.shared.open(url)
    }
}

/// Sheet for editing a contacts instance
struct ContactsInstanceEditSheet: View {
    let instance: ContactsInstance?
    let onSave: (ContactsInstance) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var id: String = ""
    @State private var name: String = ""
    @State private var enabled: Bool = true
    @State private var sourceType: ContactsSourceType = .macOSContacts
    @State private var vcfDirectory: String = ""
    @State private var fswatchEnabled: Bool = false
    @State private var fswatchDelaySeconds: Int = 60
    
    var body: some View {
        NavigationStack {
            Form {
                if sourceType == .macOSContacts {
                    Section {
                        Toggle("Enabled", isOn: $enabled)
                    } footer: {
                        Text("Sync contacts from the macOS Contacts app")
                    }
                } else {
                    // VCF source options
                    Section {
                        TextField("Display Name", text: $name, prompt: Text("e.g., Work Contacts"))
                            .help("A friendly name for this contact source")
                        
                    Toggle("Enabled", isOn: $enabled)
                }
                
                    Section {
                        HStack {
                            TextField("Path to VCF directory", text: $vcfDirectory, prompt: Text("/path/to/vcf/directory"))
                            Button("Browse...") {
                                selectVCFDirectory()
                            }
                        }
                    } header: {
                        Text("VCF Directory")
                    } footer: {
                        Text("Directory containing VCF (.vcf) contact files")
                    }
                    
                    Section {
                        Toggle("Trigger via File System Watch", isOn: $fswatchEnabled)
                        
                        if fswatchEnabled {
                            HStack {
                                Text("Delay/Cooldown")
                                Spacer()
                                TextField("", value: $fswatchDelaySeconds, format: .number)
                                    .frame(width: 80)
                                    .multilineTextAlignment(.trailing)
                                Text("seconds")
                                    .foregroundColor(.secondary)
                                Stepper("", value: $fswatchDelaySeconds, in: 1...3600)
                                    .labelsHidden()
                            }
                        }
                    } header: {
                        Text("File System Watch")
                    } footer: {
                        if fswatchEnabled {
                            Text("Wait this many seconds after file changes before processing")
                    }
                }
            }
            }
            .formStyle(.grouped)
            .navigationTitle(instance == nil ? "Add Contact Source" : "Edit Contact Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let instance = ContactsInstance(
                            id: instance?.id ?? UUID().uuidString,
                            name: sourceType == .macOSContacts ? "macOS Contacts" : name,
                            enabled: enabled,
                            sourceType: sourceType,
                            vcfDirectory: sourceType == .vcf ? (vcfDirectory.isEmpty ? nil : vcfDirectory) : nil,
                            fswatchEnabled: sourceType == .vcf ? fswatchEnabled : nil,
                            fswatchDelaySeconds: sourceType == .vcf && fswatchEnabled ? fswatchDelaySeconds : nil
                        )
                        onSave(instance)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 600, height: 400)
        .onAppear {
            if let instance = instance {
                id = instance.id
                name = instance.name
                enabled = instance.enabled
                sourceType = instance.sourceType
                vcfDirectory = instance.vcfDirectory ?? ""
                fswatchEnabled = instance.fswatchEnabled ?? false
                fswatchDelaySeconds = instance.fswatchDelaySeconds ?? 60
            } else {
                id = UUID().uuidString
                sourceType = .vcf  // Default to VCF for new instances
            }
        }
    }
    
    private func selectVCFDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                vcfDirectory = url.path
            }
        }
    }
}

