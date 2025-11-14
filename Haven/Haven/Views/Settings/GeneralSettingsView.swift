//
//  GeneralSettingsView.swift
//  Haven
//
//  General/system settings view
//  Service, gateway, and logging configuration
//

import SwiftUI

/// General settings view for system-level configuration
struct GeneralSettingsView: View {
    @Binding var config: SystemConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var authHeader: String = "X-Haven-Key"
    @State private var authSecret: String = "changeme"
    @State private var showAuthSecret: Bool = false
    
    @State private var gatewayBaseUrl: String = "http://localhost:8085"
    @State private var gatewayIngestPath: String = "/v1/ingest"
    @State private var gatewayIngestFilePath: String = "/v1/ingest/file"
    @State private var gatewayTimeoutMs: Int = 30000
    
    @State private var logLevel: String = "info"
    @State private var logFormat: String = "json"
    @State private var logAppPath: String = "~/.haven/hostagent.log"
    @State private var logErrorPath: String? = nil  // Deprecated: kept for backward compatibility
    @State private var logAccessPath: String = "~/.haven/hostagent_access.log"
    
    @State private var selfIdentifier: String = ""
    
    var body: some View {
        ScrollView {
            mainContent
        }
        .onAppear {
            // Load configuration when view appears
            loadConfiguration()
        }
        .onChange(of: config) { newConfig in
            // Reload configuration when parent updates the binding
            loadConfiguration()
        }
        .task(id: combinedState) {
            updateConfiguration()
        }
    }
    
    private var combinedState: String {
        "\(authHeader)|\(authSecret)|\(gatewayBaseUrl)|\(gatewayIngestPath)|\(gatewayIngestFilePath)|\(gatewayTimeoutMs)|\(logLevel)|\(logFormat)|\(logAppPath)|\(logErrorPath ?? "")|\(logAccessPath)|\(selfIdentifier)"
    }
    
    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            gatewayConfigurationSection
            loggingConfigurationSection
            selfIdentifierSection
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .padding()
    }
    
    @ViewBuilder
    private var gatewayConfigurationSection: some View {
        GroupBox("Gateway Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Base URL:")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", text: $gatewayBaseUrl)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Ingest Path:")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", text: $gatewayIngestPath)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Ingest File Path:")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", text: $gatewayIngestFilePath)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Auth Header:")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", text: $authHeader)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Auth Secret:")
                                .frame(width: 120, alignment: .trailing)
                            if showAuthSecret {
                                TextField("", text: $authSecret)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("", text: $authSecret)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(action: { showAuthSecret.toggle() }) {
                                Image(systemName: showAuthSecret ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                        }
                        
                        HStack {
                            Text("Timeout (ms):")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", value: $gatewayTimeoutMs, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: $gatewayTimeoutMs, in: 1000...300000, step: 1000)
                                .labelsHidden()
                        }
                    }
                    .padding()
        }
    }
    
    @ViewBuilder
    private var loggingConfigurationSection: some View {
        GroupBox("Logging Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Log Level:")
                                .frame(width: 120, alignment: .trailing)
                            Picker("", selection: $logLevel) {
                                Text("trace").tag("trace")
                                Text("debug").tag("debug")
                                Text("info").tag("info")
                                Text("warning").tag("warning")
                                Text("error").tag("error")
                            }
                            .frame(width: 150)
                        }
                        
                        HStack {
                            Text("Format:")
                                .frame(width: 120, alignment: .trailing)
                            Picker("", selection: $logFormat) {
                                Text("JSON").tag("json")
                                Text("Text").tag("text")
                            }
                            .frame(width: 150)
                        }
                        
                        HStack {
                            Text("App Log Path:")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", text: $logAppPath)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Error Log Path:")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", text: Binding(
                                get: { logErrorPath ?? "" },
                                set: { logErrorPath = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)  // Deprecated: error log is no longer used
                        }
                        
                        HStack {
                            Text("Access Log Path:")
                                .frame(width: 120, alignment: .trailing)
                            TextField("", text: $logAccessPath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding()
        }
    }
    
    @ViewBuilder
    private var selfIdentifierSection: some View {
        GroupBox("Self Identification") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter your phone number or email address. This will be matched against contacts during ingestion to set your self person ID.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)
                
                HStack {
                    Text("Phone/Email:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("e.g., +15551234567 or email@example.com", text: $selfIdentifier)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding()
        }
    }
    
    private func loadConfiguration() {
        guard let config = config else {
            // Use defaults
            return
        }
        
        authHeader = config.service.auth.header
        authSecret = config.service.auth.secret
        
        gatewayBaseUrl = config.gateway.baseUrl
        gatewayIngestPath = config.gateway.ingestPath
        gatewayIngestFilePath = config.gateway.ingestFilePath
        gatewayTimeoutMs = config.gateway.timeoutMs
        
        logLevel = config.logging.level
        logFormat = config.logging.format
        logAppPath = config.logging.paths.app
        logErrorPath = config.logging.paths.error  // Optional, deprecated
        logAccessPath = config.logging.paths.access
        
        // Treat empty string as nil for display purposes
        selfIdentifier = (config.selfIdentifier?.isEmpty == false) ? config.selfIdentifier! : ""
    }
    
    private func updateConfiguration() {
        // Preserve existing advanced settings if available (including debug settings)
        let existingAdvanced = config?.advanced ?? AdvancedModuleSettings()
        let existingPort = config?.service.port ?? 7090
        
        config = SystemConfig(
            service: SystemServiceConfig(
                port: existingPort,
                auth: SystemAuthConfig(
                    header: authHeader,
                    secret: authSecret
                )
            ),
            api: SystemApiConfig(
                responseTimeoutMs: 2000,
                statusTtlMinutes: 1440
            ),
            gateway: SystemGatewayConfig(
                baseUrl: gatewayBaseUrl,
                ingestPath: gatewayIngestPath,
                ingestFilePath: gatewayIngestFilePath,
                timeoutMs: gatewayTimeoutMs
            ),
            logging: SystemLoggingConfig(
                level: logLevel,
                format: logFormat,
                paths: SystemLoggingPathsConfig(
                    app: logAppPath,
                    error: logErrorPath,
                    access: logAccessPath
                )
            ),
            modules: ModulesEnablementConfig(
                imessage: true,
                ocr: true,
                entity: true,
                face: true,
                fswatch: true,
                localfs: true,
                contacts: true,
                mail: true
            ),
            advanced: existingAdvanced,  // Preserve advanced settings (including debug)
            selfIdentifier: selfIdentifier.isEmpty ? "" : selfIdentifier
        )
    }
}

