//
//  RunConfigurationView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct RunConfigurationView: View {
    @ObservedObject var viewModel: CollectorRunRequestBuilderViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Basic Parameters
                basicParametersSection
                
                // Time Filter
                timeFilterSection
                
                // Advanced Options
                advancedOptionsSection
                
                // Collector-Specific Scope
                collectorScopeSection
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var basicParametersSection: some View {
        GroupBox("Basic Parameters") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.mode) {
                            Text("Simulate").tag(RunMode.simulate)
                            Text("Real").tag(RunMode.real)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Order")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.order) {
                            Text("Ascending").tag(RunOrder.asc)
                            Text("Descending").tag(RunOrder.desc)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Limit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField("1000", text: $viewModel.limit)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: Binding(
                                get: { Int(viewModel.limit) ?? 1000 },
                                set: { viewModel.limit = String($0) }
                            ), in: 1...100000, step: 100)
                            .labelsHidden()
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Concurrency (1-12)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField("4", text: $viewModel.concurrency)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Stepper("", value: Binding(
                                get: { Int(viewModel.concurrency) ?? 4 },
                                set: { viewModel.concurrency = String(max(1, min(12, $0))) }
                            ), in: 1...12, step: 1)
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var timeFilterSection: some View {
        GroupBox("Time Filter") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Date Range", isOn: Binding(
                    get: { viewModel.useDateRange },
                    set: { newValue in
                        viewModel.useDateRange = newValue
                        if newValue {
                            viewModel.useTimeWindow = false
                            if viewModel.sinceDate == nil {
                                viewModel.sinceDate = Date()
                            }
                        }
                    }
                ))
                
                if viewModel.useDateRange {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Since")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let sinceDate = viewModel.sinceDate {
                                DatePicker("", selection: Binding(
                                    get: { sinceDate },
                                    set: { viewModel.sinceDate = $0 }
                                ), displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                            } else {
                                Button("Set Date") {
                                    viewModel.sinceDate = Date()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Until")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let untilDate = viewModel.untilDate {
                                DatePicker("", selection: Binding(
                                    get: { untilDate },
                                    set: { viewModel.untilDate = $0 }
                                ), displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                            } else {
                                Button("Set Date") {
                                    viewModel.untilDate = Date()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                
                Toggle("Time Window (ISO-8601)", isOn: Binding(
                    get: { viewModel.useTimeWindow },
                    set: { newValue in
                        viewModel.useTimeWindow = newValue
                        if newValue {
                            viewModel.useDateRange = false
                        }
                    }
                ))
                
                if viewModel.useTimeWindow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duration (e.g., PT24H)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("PT24H", text: $viewModel.timeWindow)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var advancedOptionsSection: some View {
        GroupBox {
            DisclosureGroup("Advanced Options", isExpanded: $viewModel.showFilters) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Combination Mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.filterCombinationMode) {
                            Text("All").tag("all")
                            Text("Any").tag("any")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    
                    HStack {
                        Text("Default Action")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.filterDefaultAction) {
                            Text("Include").tag("include")
                            Text("Exclude").tag("exclude")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inline Filters (JSON)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $viewModel.filterInline)
                            .frame(height: 80)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    Toggle("Batch Mode", isOn: $viewModel.batch)
                    
                    if viewModel.batch {
                        HStack {
                            Text("Batch Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("100", text: $viewModel.batchSize)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }
                    
                    Toggle("Wait for Completion", isOn: $viewModel.waitForCompletion)
                    
                    if !viewModel.waitForCompletion {
                        HStack {
                            Text("Timeout (ms)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("2000", text: $viewModel.timeoutMs)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            Text("Advanced Options")
        }
    }
    
    @ViewBuilder
    private var collectorScopeSection: some View {
        GroupBox("Collector-Specific Scope") {
            ScopePanelView(
                collector: viewModel.collector,
                scopeData: $viewModel.scopeData,
                modulesResponse: viewModel.modulesResponse,
                hostAgentController: viewModel.hostAgentController
            )
            .padding()
        }
    }
}

// MARK: - RunMode and RunOrder Enums

enum RunMode: String, Codable {
    case simulate
    case real
}

enum RunOrder: String, Codable {
    case asc
    case desc
}

