import SwiftUI
import Foundation

/// View for editing/adding IMAP accounts
struct IMAPAccountEditorView: View {
    let account: IMAPAccountConfig?
    let onSave: (IMAPAccountConfig) -> Void
    let onCancel: () -> Void
    
    @State private var accountId: String = ""
    @State private var host: String = ""
    @State private var port: String = "993"
    @State private var tls: Bool = true
    @State private var username: String = ""
    @State private var secretRef: String = ""
    @State private var authKind: String = "app_password"
    @State private var folders: [String] = []
    @State private var enabled: Bool = true
    
    @State private var newFolder: String = ""
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account == nil ? "Add IMAP Account" : "Edit IMAP Account")
                        .font(.headline)
                    Text("Configure IMAP connection settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Cancel")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.controlBackgroundColor))
            
            Divider()
            
            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection Settings")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Account ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g., personal-icloud", text: $accountId)
                                .textFieldStyle(.roundedBorder)
                            Text("Unique identifier for this account")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Host")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("imap.example.com", text: $host)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Port")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("993", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("TLS")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle("", isOn: $tls)
                                    .labelsHidden()
                                    .frame(width: 50)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Username")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("user@example.com", text: $username)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    Divider()
                    
                    // Authentication
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Authentication")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Auth Kind")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $authKind) {
                                Text("App Password").tag("app_password")
                                Text("OAuth2").tag("xoauth2")
                            }
                            .pickerStyle(.menu)
                            .frame(width: 200)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Secret Reference (Keychain)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("keychain://haven/account-id", text: $secretRef)
                                .textFieldStyle(.roundedBorder)
                            Text("Keychain reference (e.g., keychain://haven/account-id)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    // Folders
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Folders")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Folders to monitor (one per line)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 8) {
                                TextField("INBOX", text: $newFolder)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        addFolder()
                                    }
                                
                                Button("Add") {
                                    addFolder()
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            if !folders.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(folders, id: \.self) { folder in
                                        HStack {
                                            Text(folder)
                                                .font(.caption)
                                            Spacer()
                                            Button(action: {
                                                removeFolder(folder)
                                            }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                                .padding(8)
                                .background(Color(.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Enabled toggle
                    Toggle("Enabled", isOn: $enabled)
                    
                    // Error message
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Save") {
                    saveAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.controlBackgroundColor))
        }
        .frame(minWidth: 600, minHeight: 600)
        .background(Color(.controlBackgroundColor))
        .onAppear {
            loadAccount()
        }
    }
    
    private var isValid: Bool {
        !accountId.isEmpty && !host.isEmpty && !username.isEmpty
    }
    
    private func loadAccount() {
        if let account = account {
            accountId = account.id
            host = account.host
            port = String(account.port)
            tls = account.tls
            username = account.username
            secretRef = account.secretRef
            authKind = account.authKind
            folders = account.folders
            enabled = account.enabled
        }
    }
    
    private func addFolder() {
        let trimmed = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !folders.contains(trimmed) {
            folders.append(trimmed)
            newFolder = ""
        }
    }
    
    private func removeFolder(_ folder: String) {
        folders.removeAll { $0 == folder }
    }
    
    private func saveAccount() {
        guard !accountId.isEmpty else {
            errorMessage = "Account ID is required"
            return
        }
        
        guard !host.isEmpty else {
            errorMessage = "Host is required"
            return
        }
        
        guard !username.isEmpty else {
            errorMessage = "Username is required"
            return
        }
        
        guard let portInt = Int(port), portInt > 0 && portInt <= 65535 else {
            errorMessage = "Port must be a valid number (1-65535)"
            return
        }
        
        errorMessage = nil
        
        let config = IMAPAccountConfig(
            id: accountId,
            host: host,
            port: portInt,
            tls: tls,
            username: username,
            secretRef: secretRef,
            authKind: authKind,
            folders: folders,
            enabled: enabled
        )
        
        onSave(config)
    }
}

