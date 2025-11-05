//
//  ContactsSettingsView.swift
//  Haven
//
//  Contacts collector instances management view
//

import SwiftUI
import AppKit

/// Contacts settings view for managing contact source instances
struct ContactsSettingsView: View {
    @Binding var config: ContactsInstancesConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var instances: [ContactsInstance] = []
    @State private var selectedInstance: ContactsInstance.ID?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Validate Contacts Access") {
                    validateContactsAccess()
                }
                .buttonStyle(.bordered)
                .disabled(true) // TODO: Backend endpoint not yet implemented
                
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
            
            // Info banner for disabled validation
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Contacts access validation not yet available. Backend endpoint implementation pending.")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
            
            Divider()
            
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
                        }
                    }
                )
            }
        }
        .onAppear {
            loadConfiguration()
        }
        .onChange(of: selectedInstance) { _, newValue in
            // Only auto-open edit sheet if selected from table row click, not from pencil button
            // The pencil button sets showingEditSheet directly
        }
    }
    
    private func validateContactsAccess() {
        // TODO: Implement actual Contacts access validation
        // Backend endpoint: GET /v1/contacts/validate-access
        // This function is disabled until backend implementation is complete
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

