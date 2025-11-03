import SwiftUI

struct ConfiguratorView: View {
    let schema: CollectorSchema
    @Binding var fieldValues: [String: AnyCodable]
    let onSave: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            // Header
            VStack(alignment: .leading, spacing: 5) {
                Text("Configure \(schema.displayName)")
                    .font(.headline)
                Text("Customize collection parameters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Form fields
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(schema.fields) { field in
                        FieldView(field: field, value: binding(for: field.id))
                    }
                }
                .padding(.vertical, 8)
            }
            
            Divider()
            
            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Save & Run") {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    private func binding(for fieldId: String) -> Binding<AnyCodable?> {
        Binding(
            get: { fieldValues[fieldId] },
            set: { newValue in
                if let value = newValue {
                    fieldValues[fieldId] = value
                } else {
                    fieldValues.removeValue(forKey: fieldId)
                }
            }
        )
    }
}

// MARK: - Field View Component

struct FieldView: View {
    let field: SchemaField
    @Binding var value: AnyCodable?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label)
                    .font(.callout)
                    .fontWeight(.semibold)
                
                if field.required {
                    Text("*")
                        .foregroundStyle(.red)
                }
                
                Spacer()
            }
            
            if let description = field.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            switch field.fieldType {
            case .string(let placeholder):
                StringFieldView(value: $value, placeholder: placeholder)
                
            case .integer(let min, let max):
                IntegerFieldView(value: $value, min: min, max: max)
                
            case .double(let min, let max):
                DoubleFieldView(value: $value, min: min, max: max)
                
            case .boolean:
                BooleanFieldView(value: $value)
                
            case .stringArray(let placeholder):
                StringArrayFieldView(value: $value, placeholder: placeholder)
                
            case .enumeration(let values):
                EnumerationFieldView(value: $value, options: values)
                
            case .dateTime:
                DateTimeFieldView(value: $value)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}

// MARK: - Field Type Components

struct StringFieldView: View {
    @Binding var value: AnyCodable?
    let placeholder: String?
    
    var stringValue: String {
        if case .string(let s) = value {
            return s
        }
        return ""
    }
    
    var body: some View {
        TextField("", text: Binding(
            get: { stringValue },
            set: { newValue in
                value = newValue.isEmpty ? nil : .string(newValue)
            }
        ))
        .textFieldStyle(.roundedBorder)
        .placeholder(when: stringValue.isEmpty) {
            Text(placeholder ?? "Enter value")
                .foregroundStyle(.secondary)
        }
    }
}

struct IntegerFieldView: View {
    @Binding var value: AnyCodable?
    let min: Int?
    let max: Int?
    
    var intValue: String {
        if case .int(let i) = value {
            return String(i)
        }
        return ""
    }
    
    var body: some View {
        HStack {
            TextField("", text: Binding(
                get: { intValue },
                set: { newValue in
                    if let intVal = Int(newValue), newValue != "" {
                        // Validate bounds
                        if let minVal = min, intVal < minVal { return }
                        if let maxVal = max, intVal > maxVal { return }
                        value = .int(intVal)
                    } else if newValue.isEmpty {
                        value = nil
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            
            if let minVal = min, let maxVal = max {
                Text("\(minVal)–\(maxVal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let minVal = min {
                Text("min: \(minVal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let maxVal = max {
                Text("max: \(maxVal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DoubleFieldView: View {
    @Binding var value: AnyCodable?
    let min: Double?
    let max: Double?
    
    var doubleValue: String {
        if case .double(let d) = value {
            return String(d)
        }
        return ""
    }
    
    var body: some View {
        HStack {
            TextField("", text: Binding(
                get: { doubleValue },
                set: { newValue in
                    if let doubleVal = Double(newValue), newValue != "" {
                        if let minVal = min, doubleVal < minVal { return }
                        if let maxVal = max, doubleVal > maxVal { return }
                        value = .double(doubleVal)
                    } else if newValue.isEmpty {
                        value = nil
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            
            if let minVal = min, let maxVal = max {
                Text(String(format: "%.1f–%.1f", minVal, maxVal))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct BooleanFieldView: View {
    @Binding var value: AnyCodable?
    
    var boolValue: Bool {
        if case .bool(let b) = value {
            return b
        }
        return false
    }
    
    var body: some View {
        Toggle("", isOn: Binding(
            get: { boolValue },
            set: { newValue in
                value = .bool(newValue)
            }
        ))
        .labelsHidden()
    }
}

struct EnumerationFieldView: View {
    @Binding var value: AnyCodable?
    let options: [String]
    
    var selectedValue: String {
        if case .string(let s) = value {
            return s
        }
        return options.first ?? ""
    }
    
    var body: some View {
        Picker("", selection: Binding(
            get: { selectedValue },
            set: { newValue in
                value = .string(newValue)
            }
        )) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .pickerStyle(.menu)
        .frame(height: 28)
    }
}

struct StringArrayFieldView: View {
    @Binding var value: AnyCodable?
    let placeholder: String?
    @State private var newItem = ""
    
    var arrayValue: [String] {
        if case .string(let s) = value {
            // Handle single string value
            return s.isEmpty ? [] : [s]
        }
        return [] // TODO: Support proper array encoding
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Input field
            HStack {
                TextField("Add item", text: $newItem)
                    .textFieldStyle(.roundedBorder)
                
                Button(action: addItem) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green)
                }
                .disabled(newItem.isEmpty)
            }
            
            // Items list
            if !arrayValue.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(arrayValue, id: \.self) { item in
                        HStack {
                            Text(item)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.controlBackgroundColor))
                                .cornerRadius(4)
                            
                            Spacer()
                            
                            Button(action: { removeItem(item) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
        }
    }
    
    private func addItem() {
        var items = arrayValue
        items.append(newItem)
        newItem = ""
        // TODO: Update value with proper array encoding
    }
    
    private func removeItem(_ item: String) {
        var items = arrayValue
        items.removeAll { $0 == item }
        // TODO: Update value with proper array encoding
    }
}

struct DateTimeFieldView: View {
    @Binding var value: AnyCodable?
    @State private var selectedDate = Date()
    
    var body: some View {
        DatePicker("", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.graphical)
            .onChange(of: selectedDate) { newDate in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                value = .string(formatter.string(from: newDate))
            }
    }
}

// MARK: - Helper Extension for Placeholder

extension View {
    func placeholder<Content: View>(when shouldShow: Bool, alignment: Alignment = .leading, @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
