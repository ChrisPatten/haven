//
//  IMessageSettingsView.swift
//  Haven
//
//  iMessage collector configuration view
//

import SwiftUI

/// iMessage settings view
struct IMessageSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("iMessage Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable OCR on attachments", isOn: ocrEnabledBinding)
                        Toggle("Ingest non-image attachments", isOn: ingestNonImageAttachmentsBinding)
                        
                        Toggle("Trigger via File System Watch", isOn: fswatchEnabledBinding)
                        
                        if viewModel.imessageConfig?.fswatchEnabled == true {
                            HStack {
                                Text("Delay/Cooldown (seconds):")
                                    .frame(width: 200, alignment: .trailing)
                                TextField("", value: fswatchDelaySecondsBinding, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                Stepper("", value: fswatchDelaySecondsBinding, in: 1...3600)
                                    .labelsHidden()
                            }
                            .padding(.leading, 20)
                        }
                        
                        HStack {
                            Text("Chat DB Path:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("(empty = system default)", text: chatDbPathBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Attachments Path:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("(empty = system default)", text: attachmentsPathBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding()
                }
                
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
    }
    
    // MARK: - Bindings
    
    private var ocrEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.imessageConfig?.ocrEnabled ?? true },
            set: { newValue in
                viewModel.updateIMessageConfig { config in
                    config.ocrEnabled = newValue
                }
            }
        )
    }
    
    private var ingestNonImageAttachmentsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.imessageConfig?.ingestNonImageAttachments ?? false },
            set: { newValue in
                viewModel.updateIMessageConfig { config in
                    config.ingestNonImageAttachments = newValue
                }
            }
        )
    }
    
    private var fswatchEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.imessageConfig?.fswatchEnabled ?? false },
            set: { newValue in
                viewModel.updateIMessageConfig { config in
                    config.fswatchEnabled = newValue
                }
            }
        )
    }
    
    private var fswatchDelaySecondsBinding: Binding<Int> {
        Binding(
            get: { viewModel.imessageConfig?.fswatchDelaySeconds ?? 60 },
            set: { newValue in
                viewModel.updateIMessageConfig { config in
                    config.fswatchDelaySeconds = newValue
                }
            }
        )
    }
    
    private var chatDbPathBinding: Binding<String> {
        Binding(
            get: { viewModel.imessageConfig?.chatDbPath ?? "" },
            set: { newValue in
                viewModel.updateIMessageConfig { config in
                    config.chatDbPath = newValue
                }
            }
        )
    }
    
    private var attachmentsPathBinding: Binding<String> {
        Binding(
            get: { viewModel.imessageConfig?.attachmentsPath ?? "" },
            set: { newValue in
                viewModel.updateIMessageConfig { config in
                    config.attachmentsPath = newValue
                }
            }
        )
    }
}

#Preview {
    IMessageSettingsView(viewModel: SettingsViewModel(configManager: ConfigManager()))
}
