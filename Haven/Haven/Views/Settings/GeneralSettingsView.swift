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
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showAuthSecret: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                gatewayConfigurationSection
                loggingConfigurationSection
                enrichmentSettingsSection
                selfIdentifierSection
                
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var gatewayConfigurationSection: some View {
        GroupBox("Gateway Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Base URL:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: gatewayBaseUrlBinding)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Ingest Path:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: gatewayIngestPathBinding)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Ingest File Path:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: gatewayIngestFilePathBinding)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Timeout (ms):")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", value: gatewayTimeoutMsBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                
                HStack {
                    Text("Batch Size:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", value: gatewayBatchSizeBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                
                HStack {
                    Text("Auth Header:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: authHeaderBinding)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Auth Secret:")
                        .frame(width: 120, alignment: .trailing)
                    if showAuthSecret {
                        TextField("", text: authSecretBinding)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("", text: authSecretBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(showAuthSecret ? "Hide" : "Show") {
                        showAuthSecret.toggle()
                    }
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
                    Text("Level:")
                        .frame(width: 120, alignment: .trailing)
                    Picker("", selection: logLevelBinding) {
                        Text("debug").tag("debug")
                        Text("info").tag("info")
                        Text("warning").tag("warning")
                        Text("error").tag("error")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                HStack {
                    Text("Format:")
                        .frame(width: 120, alignment: .trailing)
                    Picker("", selection: logFormatBinding) {
                        Text("json").tag("json")
                        Text("text").tag("text")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                HStack {
                    Text("App Log Path:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: logAppPathBinding)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Access Log Path:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: logAccessPathBinding)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var enrichmentSettingsSection: some View {
        GroupBox("Enrichment Workers") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Controls how many documents can be enriched in parallel across all collectors. Higher values speed up processing but use more CPU/GPU resources.")
                    .foregroundColor(.secondary)
                    .font(.caption)

                HStack {
                    Text("Max Concurrent:")
                        .frame(width: 120, alignment: .trailing)
                    Stepper(value: maxConcurrentEnrichmentsBinding, in: 1...16) {
                        Text("\(viewModel.systemConfig?.maxConcurrentEnrichments ?? 1)")
                            .frame(alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var selfIdentifierSection: some View {
        GroupBox("Self Identification") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Phone number or email address to identify yourself in messages")
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                HStack {
                    Text("Identifier:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("e.g., +15551234567 or email@example.com", text: selfIdentifierBinding)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding()
        }
    }
    
    // MARK: - Bindings
    
    private var gatewayBaseUrlBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.gateway.baseUrl ?? "http://localhost:8085" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.gateway.baseUrl = newValue
                }
            }
        )
    }
    
    private var gatewayIngestPathBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.gateway.ingestPath ?? "/v1/ingest" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.gateway.ingestPath = newValue
                }
            }
        )
    }
    
    private var gatewayIngestFilePathBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.gateway.ingestFilePath ?? "/v1/ingest/file" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.gateway.ingestFilePath = newValue
                }
            }
        )
    }
    
    private var gatewayTimeoutMsBinding: Binding<Int> {
        Binding(
            get: { viewModel.systemConfig?.gateway.timeoutMs ?? 30000 },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.gateway.timeoutMs = newValue
                }
            }
        )
    }
    
    private var gatewayBatchSizeBinding: Binding<Int> {
        Binding(
            get: { viewModel.systemConfig?.gateway.batchSize ?? 200 },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.gateway.batchSize = max(1, newValue)
                }
            }
        )
    }

    private var maxConcurrentEnrichmentsBinding: Binding<Int> {
        Binding(
            get: { viewModel.systemConfig?.maxConcurrentEnrichments ?? 1 },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.maxConcurrentEnrichments = max(1, min(newValue, 16))
                }
            }
        )
    }
    
    private var authHeaderBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.service.auth.header ?? "X-Haven-Key" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.service.auth.header = newValue
                }
            }
        )
    }
    
    private var authSecretBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.service.auth.secret ?? "changeme" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.service.auth.secret = newValue
                }
            }
        )
    }
    
    private var logLevelBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.logging.level ?? "info" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.logging.level = newValue
                }
            }
        )
    }
    
    private var logFormatBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.logging.format ?? "json" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.logging.format = newValue
                }
            }
        )
    }
    
    private var logAppPathBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.logging.paths.app ?? "~/.haven/hostagent.log" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.logging.paths.app = newValue
                }
            }
        )
    }
    
    private var logAccessPathBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.logging.paths.access ?? "~/.haven/hostagent_access.log" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.logging.paths.access = newValue
                }
            }
        )
    }
    
    private var selfIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.selfIdentifier ?? "" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.selfIdentifier = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }
}

#Preview {
    GeneralSettingsView(viewModel: SettingsViewModel(configManager: ConfigManager()))
}
