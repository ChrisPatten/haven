//
//  EmailSettingsView.swift
//  Haven
//
//  Email collector instances management view
//

import SwiftUI

/// Email settings view for managing IMAP account instances
struct EmailSettingsView: View {
    @Binding var config: EmailInstancesConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var instances: [EmailInstance] = []
    @State private var selectedInstance: EmailInstance.ID?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Add Account") {
                    showingAddSheet = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("Remove") {
                    removeSelectedInstance()
                }
                .disabled(selectedInstance == nil)
                
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Table view
            if instances.isEmpty {
                VStack {
                    Text("No email accounts configured")
                        .foregroundColor(.secondary)
                    Text("Click 'Add Account' to configure an IMAP account")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(instances, selection: $selectedInstance) {
                    TableColumn("Name") { instance in
                        Text(instance.displayName ?? instance.id)
                    }
                    TableColumn("Host") { instance in
                        Text(instance.host ?? "")
                    }
                    TableColumn("Username") { instance in
                        Text(instance.username ?? "")
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
            EmailInstanceEditSheet(
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
                EmailInstanceEditSheet(
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
    
    private func loadConfiguration() {
        guard let config = config else {
            instances = []
            return
        }
        
        instances = config.instances
    }
    
    private func updateConfiguration() {
        config = EmailInstancesConfig(
            instances: instances,
            moduleRedactPii: config?.moduleRedactPii
        )
    }
    
    private func removeSelectedInstance() {
        guard let selectedId = selectedInstance else { return }
        instances.removeAll { $0.id == selectedId }
        selectedInstance = nil
        updateConfiguration()
    }
}

/// Sheet for editing an email instance
struct EmailInstanceEditSheet: View {
    let instance: EmailInstance?
    let onSave: (EmailInstance) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var id: String = ""
    @State private var displayName: String = ""
    @State private var enabled: Bool = true
    @State private var host: String = ""
    @State private var port: Int = 993
    @State private var tls: Bool = true
    @State private var username: String = ""
    @State private var secretRef: String = ""
    @State private var folders: [String] = []
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display Name", text: $displayName, prompt: Text("e.g., personal-icloud"))
                        .help("A friendly name for this account")
                    
                    Toggle("Enabled", isOn: $enabled)
                }
                
                Section("Server Settings") {
                    TextField("Host", text: $host, prompt: Text("imap.example.com"))
                    
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", value: $port, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $port, in: 1...65535)
                            .labelsHidden()
                    }
                    
                    Toggle("TLS/SSL", isOn: $tls)
                }
                
                Section("Authentication") {
                    TextField("Username", text: $username, prompt: Text("your-email@example.com"))
                    
                    TextField("Secret Reference", text: $secretRef, prompt: Text("keychain://..."))
                        .help("Keychain reference for the password (e.g., keychain://item-name)")
                }
                
                Section {
                    HStack {
                        Button("Test Connection") {
                            testConnection()
                        }
                        .disabled(true) // TODO: Backend endpoint not yet implemented
                        
                        Spacer()
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Connection testing not yet available. Backend endpoint implementation pending.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.top, 4)
                } header: {
                    Text("Connection Test")
                } footer: {
                    Text("Manual folder entry is supported. Enter folder names separated by commas (e.g., INBOX, Sent, Drafts)")
                }
                
                Section {
                    TextField("Folders (comma-separated)", text: Binding(
                        get: {
                            folders.joined(separator: ", ")
                        },
                        set: { newValue in
                            // Parse comma-separated string back to folders array
                            folders = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                    ), prompt: Text("INBOX, Sent, Drafts"))
                        .help("Enter folder names separated by commas")
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Enter the IMAP folders to sync from this account (e.g., INBOX, Sent, Drafts). Connection testing will be available in a future update.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(instance == nil ? "Add Email Account" : "Edit Email Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let instance = EmailInstance(
                            id: instance?.id ?? UUID().uuidString,
                            displayName: displayName.isEmpty ? nil : displayName,
                            type: "imap",
                            enabled: enabled,
                            host: host.isEmpty ? nil : host,
                            port: port,
                            tls: tls,
                            username: username.isEmpty ? nil : username,
                            auth: EmailAuthConfig(
                                kind: "app_password",
                                secretRef: secretRef
                            ),
                            folders: folders.isEmpty ? nil : folders
                        )
                        onSave(instance)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 600, height: 550)
        .onAppear {
            if let instance = instance {
                id = instance.id
                displayName = instance.displayName ?? ""
                enabled = instance.enabled
                host = instance.host ?? ""
                port = instance.port ?? 993
                tls = instance.tls ?? true
                username = instance.username ?? ""
                secretRef = instance.auth?.secretRef ?? ""
                if let existingFolders = instance.folders {
                    folders = existingFolders
                }
            } else {
                id = UUID().uuidString
            }
        }
    }
    
    private func testConnection() {
        // TODO: Implement actual IMAP connection test
        // Backend endpoint: POST /v1/email/test-connection
        // This function is disabled until backend implementation is complete
    }
}

