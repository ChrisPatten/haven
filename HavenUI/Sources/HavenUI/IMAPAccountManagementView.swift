import SwiftUI
import Foundation
import Yams

/// View for managing IMAP account instances
/// Allows creating, editing, and deleting IMAP accounts in the config file
struct IMAPAccountManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [IMAPAccountConfig] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingAddAccount = false
    @State private var editingAccount: IMAPAccountConfig?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IMAP Account Management")
                        .font(.headline)
                    Text("Configure IMAP email accounts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.controlBackgroundColor))
            
            Divider()
            
            // Content
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading accounts...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if accounts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No IMAP accounts configured")
                        .font(.headline)
                    Text("Add an account to get started")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Account") {
                        showingAddAccount = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Table header
                        HStack(spacing: 0) {
                            Text("Account")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                            
                            Text("Host")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 150, alignment: .leading)
                            
                            Text("Username")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 150, alignment: .leading)
                            
                            Text("Enabled")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 60, alignment: .center)
                            
                            Text("Actions")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 100, alignment: .center)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color(.controlBackgroundColor))
                        
                        Divider()
                        
                        // Account rows
                        ForEach(accounts) { account in
                            IMAPAccountRowView(
                                account: account,
                                onEdit: { editingAccount = account },
                                onDelete: { deleteAccount(account) },
                                onToggleEnabled: { toggleAccount(account) }
                            )
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            
            Divider()
            
            // Footer actions
            HStack {
                Button("Add Account") {
                    showingAddAccount = true
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.controlBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(.controlBackgroundColor))
        .onAppear {
            loadAccounts()
        }
        .sheet(isPresented: $showingAddAccount) {
            if editingAccount == nil {
                IMAPAccountEditorView(
                    account: nil,
                    onSave: { account in
                        addAccount(account)
                        showingAddAccount = false
                    },
                    onCancel: {
                        showingAddAccount = false
                    }
                )
            }
        }
        .sheet(item: $editingAccount) { account in
            IMAPAccountEditorView(
                account: account,
                onSave: { updatedAccount in
                    updateAccount(updatedAccount)
                    editingAccount = nil
                },
                onCancel: {
                    editingAccount = nil
                }
            )
        }
        
        // Error banner
        if let error = errorMessage {
            VStack {
                Spacer()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button(action: { errorMessage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
                .padding(12)
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadAccounts() {
        isLoading = true
        errorMessage = nil
        
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".haven/hostagent.yaml")
            .path
        
        guard FileManager.default.fileExists(atPath: configPath) else {
            accounts = []
            isLoading = false
            return
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let decoder = YAMLDecoder()
            
            struct FullConfig: Codable {
                struct Modules: Codable {
                    struct MailModule: Codable {
                        struct MailSource: Codable {
                            let id: String
                            let type: String?
                            let username: String?
                            let host: String?
                            let port: Int?
                            let tls: Bool?
                            let enabled: Bool?
                            let folders: [String]?
                            let auth: MailSourceAuth?
                            
                            struct MailSourceAuth: Codable {
                                let kind: String?
                                let secret_ref: String?
                            }
                        }
                        let sources: [MailSource]?
                    }
                    let mail: MailModule?
                }
                let modules: Modules?
            }
            
            let config = try decoder.decode(FullConfig.self, from: data)
            
            guard let sources = config.modules?.mail?.sources else {
                accounts = []
                isLoading = false
                return
            }
            
            accounts = sources
                .filter { $0.type == "imap" }
                .map { source in
                    IMAPAccountConfig(
                        id: source.id,
                        host: source.host ?? "",
                        port: source.port ?? 993,
                        tls: source.tls ?? true,
                        username: source.username ?? "",
                        secretRef: source.auth?.secret_ref ?? "",
                        authKind: source.auth?.kind ?? "app_password",
                        folders: source.folders ?? [],
                        enabled: source.enabled ?? true
                    )
                }
            
            isLoading = false
        } catch {
            errorMessage = "Failed to load accounts: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    // MARK: - Account Operations
    
    private func addAccount(_ account: IMAPAccountConfig) {
        accounts.append(account)
        saveAccounts()
    }
    
    private func updateAccount(_ account: IMAPAccountConfig) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            saveAccounts()
        }
    }
    
    private func deleteAccount(_ account: IMAPAccountConfig) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
    }
    
    private func toggleAccount(_ account: IMAPAccountConfig) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index].enabled.toggle()
            saveAccounts()
        }
    }
    
    // MARK: - Config File Writing
    
    private func saveAccounts() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".haven/hostagent.yaml")
            .path
        
        // Ensure directory exists
        let configDir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        
        do {
            // Load existing config
            var configData: Data
            var configDict: [String: Any] = [:]
            
            if FileManager.default.fileExists(atPath: configPath) {
                configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
                
                // Decode to dictionary structure
                struct ConfigWrapper: Codable {
                    var modules: [String: AnyCodable]?
                }
                
                // Use a more flexible approach - decode as generic structure
                if let yamlString = String(data: configData, encoding: .utf8) {
                    // Parse YAML to dictionary
                    if let yamlDict = try Yams.load(yaml: yamlString) as? [String: Any] {
                        configDict = yamlDict
                    }
                }
            }
            
            // Ensure modules structure exists
            if configDict["modules"] == nil {
                configDict["modules"] = [:]
            }
            
            var modules = configDict["modules"] as? [String: Any] ?? [:]
            
            // Ensure mail module exists
            if modules["mail"] == nil {
                modules["mail"] = ["enabled": false, "sources": []]
            }
            
            var mailModule = modules["mail"] as? [String: Any] ?? [:]
            
            // Get existing sources (non-IMAP)
            var sources: [[String: Any]] = []
            if let existingSources = mailModule["sources"] as? [[String: Any]] {
                sources = existingSources.filter { ($0["type"] as? String) != "imap" }
            }
            
            // Add IMAP accounts as sources
            for account in accounts {
                var source: [String: Any] = [
                    "id": account.id,
                    "type": "imap",
                    "enabled": account.enabled,
                    "host": account.host,
                    "port": account.port,
                    "tls": account.tls,
                    "username": account.username
                ]
                
                if !account.secretRef.isEmpty {
                    source["auth"] = [
                        "kind": account.authKind,
                        "secret_ref": account.secretRef
                    ]
                }
                
                if !account.folders.isEmpty {
                    source["folders"] = account.folders
                }
                
                sources.append(source)
            }
            
            mailModule["sources"] = sources
            modules["mail"] = mailModule
            configDict["modules"] = modules
            
            // Write back to file using Yams.dump
            let yamlString = try Yams.dump(object: configDict)
            try yamlString.write(toFile: configPath, atomically: true, encoding: .utf8)
            
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save accounts: \(error.localizedDescription)"
        }
    }
}

// MARK: - IMAP Account Config Model

struct IMAPAccountConfig: Identifiable, Codable {
    var id: String
    var host: String
    var port: Int
    var tls: Bool
    var username: String
    var secretRef: String  // Keychain reference (e.g., keychain://haven/account-id)
    var authKind: String    // "app_password" or "xoauth2"
    var folders: [String]
    var enabled: Bool
}

// MARK: - Account Row View

struct IMAPAccountRowView: View {
    let account: IMAPAccountConfig
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // Account ID
            VStack(alignment: .leading, spacing: 2) {
                Text(account.id)
                    .font(.callout)
                    .fontWeight(.medium)
                if !account.folders.isEmpty {
                    Text("\(account.folders.count) folder\(account.folders.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            
            // Host
            Text(account.host)
                .font(.caption)
                .frame(width: 150, alignment: .leading)
            
            // Username
            Text(account.username)
                .font(.caption)
                .frame(width: 150, alignment: .leading)
            
            // Enabled toggle
            Toggle("", isOn: Binding(
                get: { account.enabled },
                set: { _ in onToggleEnabled() }
            ))
            .labelsHidden()
            .frame(width: 60, alignment: .center)
            
            // Actions
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Edit account")
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete account")
            }
            .frame(width: 100, alignment: .center)
        }
        .padding(.vertical, 6)
    }
}


