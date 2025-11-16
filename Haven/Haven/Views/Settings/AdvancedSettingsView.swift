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
    @ObservedObject var viewModel: SettingsViewModel
    
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
    
    // Caption settings
    @State private var captionEnabled: Bool = false
    @State private var captionMethod: String = "ollama"
    @State private var captionTimeoutMs: Int = 10000
    @State private var captionModel: String = ""
    @State private var captionOpenaiApiKey: String = ""
    @State private var captionOpenaiModel: String = "gpt-4o"
    
    // FSWatch settings
    @State private var fswatchEventQueueSize: Int = 1024
    @State private var fswatchDebounceMs: Int = 500
    
    // LocalFS settings
    @State private var localfsMaxFileBytes: Int = 104857600  // 100MB
    
    // Enrichment settings
    @State private var enrichmentConcurrency: Int = 4
    
    // Debug settings
    @State private var debugEnabled: Bool = false
    @State private var debugOutputPath: String = "~/.haven/debug_documents.jsonl"
    
    private let entityCommonTypes = ["person", "organization", "place", "date", "money", "email", "phone", "url"]
    
    var body: some View {
        finalView
    }
    
    private var finalView: some View {
        applyDebugModifiers(to: withLocalFSModifiers)
    }
    
    private var withLocalFSModifiers: some View {
        applyLocalFSModifiers(to: withFSWatchModifiers)
    }
    
    private var withFSWatchModifiers: some View {
        applyFSWatchModifiers(to: withCaptionModifiers)
    }
    
    private var withCaptionModifiers: some View {
        applyCaptionModifiers(to: withFaceModifiers)
    }
    
    private var withFaceModifiers: some View {
        applyFaceModifiers(to: withEntityModifiers)
    }
    
    private var withEntityModifiers: some View {
        applyEntityModifiers(to: withOCRModifiers)
    }
    
    private var withOCRModifiers: some View {
        applyOCRModifiers(to: baseView)
    }
    
    private var baseView: some View {
        contentView
            .onAppear(perform: loadConfiguration)
            .onChange(of: viewModel.systemConfig) { newConfig in
                loadConfiguration()
            }
    }
    
    @ViewBuilder
    private func applyOCRModifiers<V: View>(to view: V) -> some View {
        view
            .onChange(of: ocrLanguages) { _, _ in updateConfiguration() }
            .onChange(of: ocrTimeoutMs) { _, _ in updateConfiguration() }
            .onChange(of: ocrRecognitionLevel) { _, _ in updateConfiguration() }
            .onChange(of: ocrIncludeLayout) { _, _ in updateConfiguration() }
    }
    
    @ViewBuilder
    private func applyEntityModifiers<V: View>(to view: V) -> some View {
        view
            .onChange(of: entityTypes) { _, _ in updateConfiguration() }
            .onChange(of: entityMinConfidence) { _, _ in updateConfiguration() }
    }
    
    @ViewBuilder
    private func applyFaceModifiers<V: View>(to view: V) -> some View {
        view
            .onChange(of: faceMinSize) { _, _ in updateConfiguration() }
            .onChange(of: faceMinConfidence) { _, _ in updateConfiguration() }
            .onChange(of: faceIncludeLandmarks) { _, _ in updateConfiguration() }
    }
    
    @ViewBuilder
    private func applyCaptionModifiers<V: View>(to view: V) -> some View {
        view
            .onChange(of: captionEnabled) { _, _ in updateConfiguration() }
            .onChange(of: captionMethod) { _, _ in updateConfiguration() }
            .onChange(of: captionTimeoutMs) { _, _ in updateConfiguration() }
            .onChange(of: captionModel) { _, _ in updateConfiguration() }
            .onChange(of: captionOpenaiApiKey) { _, _ in updateConfiguration() }
            .onChange(of: captionOpenaiModel) { _, _ in updateConfiguration() }
    }
    
    @ViewBuilder
    private func applyFSWatchModifiers<V: View>(to view: V) -> some View {
        view
            .onChange(of: fswatchEventQueueSize) { _, _ in updateConfiguration() }
            .onChange(of: fswatchDebounceMs) { _, _ in updateConfiguration() }
    }
    
    @ViewBuilder
    private func applyLocalFSModifiers<V: View>(to view: V) -> some View {
        view
            .onChange(of: localfsMaxFileBytes) { _, _ in updateConfiguration() }
    }
    
    @ViewBuilder
    private func applyDebugModifiers<V: View>(to view: V) -> some View {
        view
            .onChange(of: enrichmentConcurrency) { _, _ in updateConfiguration() }
            .onChange(of: debugEnabled) { _, _ in updateConfiguration() }
            .onChange(of: debugOutputPath) { _, _ in updateConfiguration() }
    }
    
    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                enrichmentSettingsView
                ocrSettingsView
                entitySettingsView
                faceSettingsView
                captionSettingsView
                fswatchSettingsView
                localfsSettingsView
                debugSettingsView
                
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
    }
    
    private var enrichmentSettingsView: some View {
        GroupBox("Enrichment Pipeline Settings") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Concurrency:")
                        .frame(width: 150, alignment: .trailing)
                    TextField("", value: $enrichmentConcurrency, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Stepper("", value: $enrichmentConcurrency, in: 1...16, step: 1)
                        .labelsHidden()
                    Text("(1-16)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                
                Text("Number of images processed concurrently during enrichment. Higher values may improve throughput but increase resource usage.")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.top, 4)
            }
            .padding()
        }
    }
    
    private var ocrSettingsView: some View {
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
    }
    
    private var entitySettingsView: some View {
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
    }
    
    private var faceSettingsView: some View {
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
    }
    
    private var captionSettingsView: some View {
        GroupBox("Caption Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Captioning", isOn: $captionEnabled)
                            .help("When enabled, images will be captioned using the selected method")
                        
                        if captionEnabled {
                            HStack {
                                Text("Method:")
                                    .frame(width: 150, alignment: .trailing)
                                Picker("", selection: $captionMethod) {
                                    Text("Apple Foundation").tag("apple")
                                    Text("Ollama").tag("ollama")
                                    Text("OpenAI").tag("openai")
                                }
                                .frame(width: 150)
                            }
                            
                            HStack {
                                Text("Timeout (ms):")
                                    .frame(width: 150, alignment: .trailing)
                                TextField("", value: $captionTimeoutMs, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                Stepper("", value: $captionTimeoutMs, in: 1000...60000, step: 1000)
                                    .labelsHidden()
                            }
                            
                            // Model field only shown for Ollama (not needed for Apple Foundation)
                            if captionMethod == "ollama" {
                                HStack {
                                    Text("Model (optional):")
                                        .frame(width: 150, alignment: .trailing)
                                    TextField("e.g., llava:7b", text: $captionModel)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            
                            // OpenAI settings only shown for OpenAI
                            if captionMethod == "openai" {
                                HStack {
                                    Text("API Key:")
                                        .frame(width: 150, alignment: .trailing)
                                    SecureField("sk-...", text: $captionOpenaiApiKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                HStack {
                                    Text("Model:")
                                        .frame(width: 150, alignment: .trailing)
                                    TextField("e.g., gpt-4o", text: $captionOpenaiModel)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            
                            // Web server settings only shown for OpenAI
                            if captionMethod == "openai" {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding()
        }
    }
    
    private var fswatchSettingsView: some View {
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
    }
    
    private var localfsSettingsView: some View {
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
    }
    
    private var debugSettingsView: some View {
        GroupBox("Debug Mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Debug Mode", isOn: $debugEnabled)
                            .help("When enabled, documents are written to a JSON file instead of being submitted to the gateway")
                        
                        if debugEnabled {
                            HStack {
                                Text("Output Path:")
                                    .frame(width: 150, alignment: .trailing)
                                TextField("", text: $debugOutputPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            Text("Documents will be written as JSON lines (JSONL format) to the specified file")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .padding()
        }
    }
    
    private func loadConfiguration() {
        guard let config = viewModel.systemConfig else {
            // Use defaults
            return
        }
        
        enrichmentConcurrency = config.advanced.enrichmentConcurrency
        
        ocrLanguages = config.advanced.ocr.languages
        ocrTimeoutMs = config.advanced.ocr.timeoutMs
        ocrRecognitionLevel = config.advanced.ocr.recognitionLevel
        ocrIncludeLayout = config.advanced.ocr.includeLayout
        
        entityTypes = config.advanced.entity.types
        entityMinConfidence = config.advanced.entity.minConfidence
        
        faceMinSize = config.advanced.face.minFaceSize
        faceMinConfidence = config.advanced.face.minConfidence
        faceIncludeLandmarks = config.advanced.face.includeLandmarks
        
        captionEnabled = config.advanced.caption.enabled
        captionMethod = config.advanced.caption.method
        captionTimeoutMs = config.advanced.caption.timeoutMs
        captionModel = config.advanced.caption.model ?? ""
        captionOpenaiApiKey = config.advanced.caption.openaiApiKey ?? ""
        captionOpenaiModel = config.advanced.caption.openaiModel ?? "gpt-4o"
        
        fswatchEventQueueSize = config.advanced.fswatch.eventQueueSize
        fswatchDebounceMs = config.advanced.fswatch.debounceMs
        
        localfsMaxFileBytes = config.advanced.localfs.maxFileBytes
        
        debugEnabled = config.advanced.debug.enabled
        debugOutputPath = config.advanced.debug.outputPath
    }
    
    private func updateConfiguration() {
        viewModel.updateSystemConfig { systemConfig in
            systemConfig.advanced = AdvancedModuleSettings(
                enrichmentConcurrency: enrichmentConcurrency,
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
                caption: CaptionModuleSettings(
                    enabled: captionEnabled,
                    method: captionMethod,
                    timeoutMs: captionTimeoutMs,
                    model: captionModel.isEmpty ? nil : captionModel,
                    openaiApiKey: captionOpenaiApiKey.isEmpty ? nil : captionOpenaiApiKey,
                    openaiModel: captionOpenaiModel.isEmpty ? nil : captionOpenaiModel
                ),
                fswatch: FSWatchModuleSettings(
                    eventQueueSize: fswatchEventQueueSize,
                    debounceMs: fswatchDebounceMs
                ),
                localfs: LocalFSModuleSettings(
                    maxFileBytes: localfsMaxFileBytes
                ),
                debug: DebugSettings(
                    enabled: debugEnabled,
                    outputPath: debugOutputPath
                )
            )
        }
    }
}

