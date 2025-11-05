//
//  IMessageSettingsView.swift
//  Haven
//
//  iMessage collector configuration view
//

import SwiftUI

/// iMessage settings view
struct IMessageSettingsView: View {
    @Binding var config: IMessageInstanceConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var ocrEnabled: Bool = true
    @State private var chatDbPath: String = ""
    @State private var attachmentsPath: String = ""
    @State private var ingestNonImageAttachments: Bool = false
    @State private var fswatchEnabled: Bool = false
    @State private var fswatchDelaySeconds: Int = 60
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("iMessage Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable OCR on attachments", isOn: $ocrEnabled)
                        Toggle("Ingest non-image attachments", isOn: $ingestNonImageAttachments)
                        
                        Toggle("Trigger via File System Watch", isOn: $fswatchEnabled)
                        
                        if fswatchEnabled {
                            HStack {
                                Text("Delay/Cooldown (seconds):")
                                    .frame(width: 200, alignment: .trailing)
                                TextField("", value: $fswatchDelaySeconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                Stepper("", value: $fswatchDelaySeconds, in: 1...3600)
                                    .labelsHidden()
                            }
                            .padding(.leading, 20)
                        }
                        
                        HStack {
                            Text("Chat DB Path:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("(empty = system default)", text: $chatDbPath)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Attachments Path:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("(empty = system default)", text: $attachmentsPath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding()
                }
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
        .onAppear {
            loadConfiguration()
        }
        .onChange(of: ocrEnabled) { _, _ in updateConfiguration() }
        .onChange(of: ingestNonImageAttachments) { _, _ in updateConfiguration() }
        .onChange(of: fswatchEnabled) { _, _ in updateConfiguration() }
        .onChange(of: fswatchDelaySeconds) { _, _ in updateConfiguration() }
        .onChange(of: chatDbPath) { _, _ in updateConfiguration() }
        .onChange(of: attachmentsPath) { _, _ in updateConfiguration() }
    }
    
    private func loadConfiguration() {
        guard let config = config else {
            // Use defaults
            return
        }
        
        ocrEnabled = config.ocrEnabled
        chatDbPath = config.chatDbPath
        attachmentsPath = config.attachmentsPath
        ingestNonImageAttachments = config.ingestNonImageAttachments
        fswatchEnabled = config.fswatchEnabled
        fswatchDelaySeconds = config.fswatchDelaySeconds
    }
    
    private func updateConfiguration() {
        config = IMessageInstanceConfig(
            ocrEnabled: ocrEnabled,
            chatDbPath: chatDbPath,
            attachmentsPath: attachmentsPath,
            ingestNonImageAttachments: ingestNonImageAttachments,
            fswatchEnabled: fswatchEnabled,
            fswatchDelaySeconds: fswatchDelaySeconds
        )
    }
}

