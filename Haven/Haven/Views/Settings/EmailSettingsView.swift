//
//  EmailSettingsView.swift
//  Haven
//
//  Email collector instances management view
//

import SwiftUI
import HavenCore
import CollectorHandlers
import IMAP

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
                },
                configManager: configManager
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
                    },
                    configManager: configManager
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
    var configManager: ConfigManager
    
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
    
    // Connection test state
    @State private var isTestingConnection = false
    @State private var connectionTestError: String?
    @State private var availableFolders: [ImapFolder] = []
    @State private var showFolderTree = false
    
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
                        Button(action: {
                            Task {
                                await testConnection()
                            }
                        }) {
                            HStack {
                                if isTestingConnection {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Testing...")
                                } else {
                                    Image(systemName: "network")
                                    Text("Test Connection")
                                }
                            }
                        }
                        .disabled(isTestingConnection || host.isEmpty || username.isEmpty || secretRef.isEmpty)
                        
                        Spacer()
                    }
                    
                    if let error = connectionTestError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        .padding(.top, 4)
                    } else if showFolderTree && !availableFolders.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Connection successful! Select folders below.")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                } header: {
                    Text("Connection Test")
                } footer: {
                    if !showFolderTree {
                        Text("Click 'Test Connection' to verify settings and load available folders from the server.")
                    }
                }
                
                if showFolderTree && !availableFolders.isEmpty {
                    Section {
                        IMAPFolderTreeView(
                            selectedFolders: $folders,
                            folders: availableFolders
                        )
                    } header: {
                        Text("Select Folders")
                    } footer: {
                        Text("Select the folders you want to sync. Selected folders: \(folders.count)")
                    }
                } else {
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
                            .help("Enter folder names separated by commas, or use 'Test Connection' to select from server")
                    } header: {
                        Text("Folders")
                    } footer: {
                        Text("Enter folder names manually, or use 'Test Connection' to browse and select folders from the server.")
                    }
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
                // If folders exist, try to load them in the tree view
                // User can click "Test Connection" again to refresh
            } else {
                id = UUID().uuidString
            }
        }
    }
    
    private func testConnection() async {
        isTestingConnection = true
        connectionTestError = nil
        showFolderTree = false
        availableFolders = []
        
        // Validate required fields
        guard !host.isEmpty, !username.isEmpty, !secretRef.isEmpty else {
            connectionTestError = "Please fill in all required fields (Host, Username, Secret Reference)"
            isTestingConnection = false
            return
        }
        
        do {
            // Load config and create EmailController
            let systemConfig = try await configManager.loadSystemConfig()
            let emailConfig = try await configManager.loadEmailConfig()
            let filesConfig = try await configManager.loadFilesConfig()
            let contactsConfig = try await configManager.loadContactsConfig()
            let imessageConfig = try await configManager.loadIMessageConfig()
            
            let havenConfig = ConfigConverter.toHavenConfig(
                systemConfig: systemConfig,
                emailConfig: emailConfig,
                filesConfig: filesConfig,
                contactsConfig: contactsConfig,
                imessageConfig: imessageConfig
            )
            
            let serviceController = ServiceController(configManager: configManager)
            let emailController = try await EmailController(config: havenConfig, serviceController: serviceController)
            
            // Call direct Swift API
            let result = await emailController.testConnection(
                host: host,
                port: port,
                tls: tls,
                username: username,
                authKind: "app_password",
                secretRef: secretRef
            )
            
            if result.success, let folders = result.folders {
                // Convert IMAP.ImapFolder to Haven.ImapFolder
                availableFolders = folders.map { folder in
                    Haven.ImapFolder(
                        path: folder.path,
                        delimiter: folder.delimiter,
                        flags: folder.flags
                    )
                }
                showFolderTree = true
                connectionTestError = nil
            } else {
                connectionTestError = result.error ?? "Connection test failed"
                showFolderTree = false
            }
        } catch {
            connectionTestError = "Failed to test connection: \(error.localizedDescription)"
            showFolderTree = false
        }
        
        isTestingConnection = false
    }
}

