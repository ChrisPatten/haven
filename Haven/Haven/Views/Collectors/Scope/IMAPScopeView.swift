//
//  IMAPScopeView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct IMAPScopeView: View {
    let collector: CollectorInfo
    @Binding var scopeData: [String: AnyCodable]
    let hostAgentController: HostAgentController?
    
    @State private var accountInfo: IMAPAccountInfo?
    @State private var selectedFolders: Set<String> = []
    @State private var availableFolders: [String] = []
    @State private var isLoadingFolders = false
    @State private var folderError: String?
    @State private var testConnectionError: String?
    @State private var isTestingConnection = false
    @State private var hasAccountsConfigured = false
    @State private var isLoadingAccountCheck = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Show Add Account button if no accounts configured
            if !hasAccountsConfigured && !isLoadingAccountCheck {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    
                    Text("No IMAP Accounts Configured")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text("Configure an IMAP account to start collecting email")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(action: openEmailSettings) {
                        Label("Add Account", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else if isLoadingAccountCheck {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Checking account configuration...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                // Account Info
                if let accountId = collector.imapAccountId {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Account")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        if let account = accountInfo {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Account ID: \(account.id)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                if let host = account.host {
                                    Text("Host: \(host)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                if let username = account.username {
                                    Text("Username: \(username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Account ID: \(accountId)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            
            Divider()
            
            // Folder Selection
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Folders")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button(action: loadFolders) {
                        if isLoadingFolders {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh folders")
                    .disabled(isLoadingFolders)
                }
                
                if let error = folderError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                if availableFolders.isEmpty && !isLoadingFolders {
                    Text("No folders available. Click refresh to load folders from the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(availableFolders, id: \.self) { folder in
                                HStack {
                                    Button(action: {
                                        if selectedFolders.contains(folder) {
                                            selectedFolders.remove(folder)
                                        } else {
                                            selectedFolders.insert(folder)
                                        }
                                        updateScope()
                                    }) {
                                        Image(systemName: selectedFolders.contains(folder) ? "checkmark.square" : "square")
                                            .foregroundStyle(selectedFolders.contains(folder) ? .blue : .secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    
                                    Text(folder)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            
            Divider()
            
            // Test Connection
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection Test")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                if let error = testConnectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Button(action: testConnection) {
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
                .buttonStyle(.bordered)
                .disabled(isTestingConnection)
            }
            }
        }
        .onAppear {
            checkAccountConfiguration()
            loadAccountInfo()
            loadSelectedFolders()
        }
    }
    
    private func checkAccountConfiguration() {
        guard let controller = hostAgentController else {
            // If no controller provided, assume accounts are configured
            hasAccountsConfigured = true
            return
        }
        
        isLoadingAccountCheck = true
        Task {
            let hasAccounts = await controller.hasImapSourcesConfigured()
            await MainActor.run {
                hasAccountsConfigured = hasAccounts
                isLoadingAccountCheck = false
            }
        }
    }
    
    private func openEmailSettings() {
        // Post notification to open settings to Email section
        // HavenApp will listen for this and open the settings window
        NotificationCenter.default.post(
            name: .openSettingsToSection,
            object: SettingsWindow.SettingsSection.email
        )
    }
    
    private func loadAccountInfo() {
        // TODO: Load account info from config
        // For now, placeholder implementation
    }
    
    private func loadFolders() {
        isLoadingFolders = true
        folderError = nil
        
        // TODO: Fetch folders from IMAP server
        // For now, placeholder
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            availableFolders = ["Inbox", "Sent Messages", "Drafts"]
            isLoadingFolders = false
        }
    }
    
    private func loadSelectedFolders() {
        // Load selected folders from scopeData
        if let foldersValue = scopeData["folders"] {
            // TODO: Parse folders array from scopeData
        }
    }
    
    private func updateScope() {
        var foldersArray: [String] = Array(selectedFolders)
        // TODO: Update scopeData with selected folders
        // For now, store as string array
        // scopeData["folders"] = .array(foldersArray)
    }
    
    private func testConnection() {
        isTestingConnection = true
        testConnectionError = nil
        
        // TODO: Test IMAP connection
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isTestingConnection = false
            // testConnectionError = "Connection failed" // Example error
        }
    }
}

struct IMAPAccountInfo {
    let id: String
    let username: String?
    let host: String?
    let enabled: Bool
    let folders: [String]?
}

