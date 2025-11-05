//
//  AdvancedSettingsView.swift
//  Haven
//
//  Advanced module settings view
//  OCR, entity, face, FSWatch, LocalFS settings
//

import SwiftUI

/// Advanced settings view for module-specific settings
struct AdvancedSettingsView: View {
    @Binding var systemConfig: SystemConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    // OCR settings
    @State private var ocrLanguages: [String] = ["en"]
    @State private var ocrTimeoutMs: Int = 15000
    @State private var ocrRecognitionLevel: String = "accurate"
    @State private var ocrIncludeLayout: Bool = false
    
    // Entity settings
    @State private var entityTypes: [String] = ["person", "organization", "place"]
    @State private var entityMinConfidence: Float = 0.6
    
    // Face settings
    @State private var faceMinSize: Double = 0.01
    @State private var faceMinConfidence: Double = 0.7
    @State private var faceIncludeLandmarks: Bool = false
    
    // FSWatch settings
    @State private var fswatchEventQueueSize: Int = 1024
    @State private var fswatchDebounceMs: Int = 500
    
    // LocalFS settings
    @State private var localfsMaxFileBytes: Int = 104857600  // 100MB
    
    private let entityCommonTypes = ["person", "organization", "place", "date", "money", "email", "phone", "url"]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // OCR Settings
                GroupBox("OCR Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Languages:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("Comma-separated", text: Binding(
                                get: { ocrLanguages.joined(separator: ", ") },
                                set: { ocrLanguages = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Timeout (ms):")
                                .frame(width: 150, alignment: .trailing)
                            TextField("", value: $ocrTimeoutMs, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: $ocrTimeoutMs, in: 1000...60000, step: 1000)
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Recognition Level:")
                                .frame(width: 150, alignment: .trailing)
                            Picker("", selection: $ocrRecognitionLevel) {
                                Text("Fast").tag("fast")
                                Text("Accurate").tag("accurate")
                            }
                            .frame(width: 150)
                        }
                        
                        Toggle("Include Layout", isOn: $ocrIncludeLayout)
                    }
                    .padding()
                }
                
                // Entity Settings
                GroupBox("Entity Extraction Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Entity Types:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entityCommonTypes, id: \.self) { type in
                                Toggle(type, isOn: Binding(
                                    get: { entityTypes.contains(type) },
                                    set: { isSelected in
                                        if isSelected {
                                            if !entityTypes.contains(type) {
                                                entityTypes.append(type)
                                            }
                                        } else {
                                            entityTypes.removeAll { $0 == type }
                                        }
                                        updateConfiguration()
                                    }
                                ))
                            }
                        }
                        
                        // Custom types input
                        HStack {
                            Text("Custom Types:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("Comma-separated (e.g., product, event)", text: Binding(
                                get: { 
                                    let customTypes = entityTypes.filter { !entityCommonTypes.contains($0) }
                                    return customTypes.joined(separator: ", ")
                                },
                                set: { newValue in
                                    let customTypes = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                    let selectedCommonTypes = entityTypes.filter { entityCommonTypes.contains($0) }
                                    entityTypes = selectedCommonTypes + customTypes
                                    updateConfiguration()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Min Confidence:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("", value: $entityMinConfidence, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: $entityMinConfidence, in: 0.0...1.0, step: 0.1)
                                .labelsHidden()
                        }
                    }
                    .padding()
                }
                
                // Face Settings
                GroupBox("Face Detection Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Min Face Size:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("", value: $faceMinSize, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: $faceMinSize, in: 0.001...0.1, step: 0.001)
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Min Confidence:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("", value: $faceMinConfidence, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: $faceMinConfidence, in: 0.0...1.0, step: 0.1)
                                .labelsHidden()
                        }
                        
                        Toggle("Include Landmarks", isOn: $faceIncludeLandmarks)
                    }
                    .padding()
                }
                
                // FSWatch Settings
                GroupBox("File System Watch Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Event Queue Size:")
                                .frame(width: 150, alignment: .trailing)
                            TextField("", value: $fswatchEventQueueSize, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: $fswatchEventQueueSize, in: 64...16384, step: 64)
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Debounce (ms):")
                                .frame(width: 150, alignment: .trailing)
                            TextField("", value: $fswatchDebounceMs, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: $fswatchDebounceMs, in: 100...5000, step: 100)
                                .labelsHidden()
                        }
                    }
                    .padding()
                }
                
                // LocalFS Settings
                GroupBox("Local File System Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Max File Size (bytes):")
                                .frame(width: 150, alignment: .trailing)
                            TextField("", value: $localfsMaxFileBytes, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Stepper("", value: $localfsMaxFileBytes, in: 1024...1073741824, step: 1048576)
                                .labelsHidden()
                        }
                        
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(localfsMaxFileBytes), countStyle: .binary))")
                            .foregroundColor(.secondary)
                            .font(.caption)
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
        .onChange(of: ocrLanguages) { _, _ in updateConfiguration() }
        .onChange(of: ocrTimeoutMs) { _, _ in updateConfiguration() }
        .onChange(of: ocrRecognitionLevel) { _, _ in updateConfiguration() }
        .onChange(of: ocrIncludeLayout) { _, _ in updateConfiguration() }
        .onChange(of: entityTypes) { _, _ in updateConfiguration() }
        .onChange(of: entityMinConfidence) { _, _ in updateConfiguration() }
        .onChange(of: faceMinSize) { _, _ in updateConfiguration() }
        .onChange(of: faceMinConfidence) { _, _ in updateConfiguration() }
        .onChange(of: faceIncludeLandmarks) { _, _ in updateConfiguration() }
        .onChange(of: fswatchEventQueueSize) { _, _ in updateConfiguration() }
        .onChange(of: fswatchDebounceMs) { _, _ in updateConfiguration() }
        .onChange(of: localfsMaxFileBytes) { _, _ in updateConfiguration() }
    }
    
    private func loadConfiguration() {
        guard let config = systemConfig else {
            // Use defaults
            return
        }
        
        ocrLanguages = config.advanced.ocr.languages
        ocrTimeoutMs = config.advanced.ocr.timeoutMs
        ocrRecognitionLevel = config.advanced.ocr.recognitionLevel
        ocrIncludeLayout = config.advanced.ocr.includeLayout
        
        entityTypes = config.advanced.entity.types
        entityMinConfidence = config.advanced.entity.minConfidence
        
        faceMinSize = config.advanced.face.minFaceSize
        faceMinConfidence = config.advanced.face.minConfidence
        faceIncludeLandmarks = config.advanced.face.includeLandmarks
        
        fswatchEventQueueSize = config.advanced.fswatch.eventQueueSize
        fswatchDebounceMs = config.advanced.fswatch.debounceMs
        
        localfsMaxFileBytes = config.advanced.localfs.maxFileBytes
    }
    
    private func updateConfiguration() {
        guard var config = systemConfig else { return }
        
        config.advanced = AdvancedModuleSettings(
            ocr: OCRModuleSettings(
                languages: ocrLanguages,
                timeoutMs: ocrTimeoutMs,
                recognitionLevel: ocrRecognitionLevel,
                includeLayout: ocrIncludeLayout
            ),
            entity: EntityModuleSettings(
                types: entityTypes,
                minConfidence: entityMinConfidence
            ),
            face: FaceModuleSettings(
                minFaceSize: faceMinSize,
                minConfidence: faceMinConfidence,
                includeLandmarks: faceIncludeLandmarks
            ),
            fswatch: FSWatchModuleSettings(
                eventQueueSize: fswatchEventQueueSize,
                debounceMs: fswatchDebounceMs
            ),
            localfs: LocalFSModuleSettings(
                maxFileBytes: localfsMaxFileBytes
            )
        )
        
        systemConfig = config
    }
}

