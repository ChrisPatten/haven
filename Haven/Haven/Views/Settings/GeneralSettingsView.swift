//
//  GeneralSettingsView.swift
//  Haven
//
//  General/system settings view
//  Service, gateway, logging, and module enablement configuration
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
    @State private var logErrorPath: String = "~/.haven/hostagent_error.log"
    @State private var logAccessPath: String = "~/.haven/hostagent_access.log"
    
    @State private var moduleIMessage: Bool = true
    @State private var moduleOCR: Bool = true
    @State private var moduleEntity: Bool = true
    @State private var moduleFace: Bool = false
    @State private var moduleFSWatch: Bool = false
    @State private var moduleLocalFS: Bool = false
    @State private var moduleContacts: Bool = false
    @State private var moduleMail: Bool = false
    
    var body: some View {
        ScrollView {
            mainContent
        }
        .onAppear {
            loadConfiguration()
        }
        .task(id: combinedState) {
            updateConfiguration()
        }
    }
    
    private var combinedState: String {
        "\(authHeader)|\(authSecret)|\(gatewayBaseUrl)|\(gatewayIngestPath)|\(gatewayIngestFilePath)|\(gatewayTimeoutMs)|\(logLevel)|\(logFormat)|\(logAppPath)|\(logErrorPath)|\(logAccessPath)|\(moduleIMessage)|\(moduleOCR)|\(moduleEntity)|\(moduleFace)|\(moduleFSWatch)|\(moduleLocalFS)|\(moduleContacts)|\(moduleMail)"
    }
    
    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            gatewayConfigurationSection
            loggingConfigurationSection
            moduleEnablementSection
            
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
                            TextField("", text: $logErrorPath)
                                .textFieldStyle(.roundedBorder)
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
    private var moduleEnablementSection: some View {
        GroupBox("Module Enablement") {
            HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 8) {
                    Text("Collectors")
                        .font(.headline)
                        .padding(.bottom, 4)
                        Toggle("iMessage", isOn: $moduleIMessage)
                    Toggle("Contacts", isOn: $moduleContacts)
                    Toggle("Local File System", isOn: $moduleLocalFS)
                    Toggle("Mail", isOn: $moduleMail)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Features")
                        .font(.headline)
                        .padding(.bottom, 4)
                        Toggle("Entity Extraction", isOn: $moduleEntity)
                        Toggle("Face Detection", isOn: $moduleFace)
                        Toggle("File System Watch", isOn: $moduleFSWatch)
                    Toggle("OCR", isOn: $moduleOCR)
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
        logErrorPath = config.logging.paths.error
        logAccessPath = config.logging.paths.access
        
        moduleIMessage = config.modules.imessage
        moduleOCR = config.modules.ocr
        moduleEntity = config.modules.entity
        moduleFace = config.modules.face
        moduleFSWatch = config.modules.fswatch
        moduleLocalFS = config.modules.localfs
        moduleContacts = config.modules.contacts
        moduleMail = config.modules.mail
    }
    
    private func updateConfiguration() {
        // Preserve existing advanced settings if available
        let advancedSettings = config?.advanced ?? AdvancedModuleSettings()
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
                imessage: moduleIMessage,
                ocr: moduleOCR,
                entity: moduleEntity,
                face: moduleFace,
                fswatch: moduleFSWatch,
                localfs: moduleLocalFS,
                contacts: moduleContacts,
                mail: moduleMail
            ),
            advanced: advancedSettings  // Preserve advanced settings
        )
    }
}

