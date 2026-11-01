import SwiftUI

/// A schema-driven input keeps unedited object members intact, including advanced provider settings.
struct FlowSchemaField: View {
    let name: String
    let schema: FlowJSON
    @Binding var value: FlowJSON
    var required = false
    var depth = 0
    var showLabel = true
    let onError: (String?) -> Void
    @ViewState private var jsonDraft = ""
    @ViewState private var childErrors: [String: String] = [:]
    @FocusState private var editingJSON: Bool

    private var kind: String { schema["type"].string ?? (schema["properties"] != .null ? "object" : "string") }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showLabel { HStack(spacing: 4) {
                Text(caption).font(.system(size: 11, weight: .medium))
                if required { Text("*").foregroundStyle(.orange) }
                Spacer()
                if value != .null {
                    Button { value = .null; jsonDraft = ""; onError(nil) } label: { Image(systemName: "xmark.circle").font(.system(size: 10)) }
                        .buttonStyle(.borderless).help("Clear input")
                }
            } }
            input
            if let description = schema["description"].string {
                Text(description).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var caption: String {
        switch name {
        case "run": return String(localized: "Command")
        case "undo": return String(localized: "Undo command")
        case "connection": return String(localized: "Connection")
        case "workflow": return String(localized: "Workflow")
        case "job": return String(localized: "Job")
        case "repo": return String(localized: "Repository")
        case "ref": return String(localized: "Branch or tag")
        case "report": return String(localized: "Report file")
        case "image": return String(localized: "Container image")
        case "file": return String(localized: "Configuration file")
        case "timeout": return String(localized: "Timeout")
        case "poll": return String(localized: "Poll interval")
        case "trigger": return String(localized: "Trigger request")
        case "status": return String(localized: "Status request")
        case "logs": return String(localized: "Log request")
        case "cancel": return String(localized: "Cancel request")
        case "pointer": return String(localized: "Status field path")
        case "description": return String(localized: "Description")
        case "cwd": return String(localized: "Working directory")
        case "if": return String(localized: "Condition")
        case "headers": return String(localized: "Headers")
        case "body": return String(localized: "Request body")
        case "method": return String(localized: "HTTP method")
        case "url": return String(localized: "URL")
        case "parameters": return String(localized: "Build parameters")
        case "inputs": return String(localized: "Workflow inputs")
        case "variables": return String(localized: "Variables")
        case "project": return String(localized: "Project")
        case "service": return String(localized: "Service")
        default: return name
        }
    }

    @ViewBuilder private var input: some View {
        if !schema["oneOf"].array.isEmpty {
            let choices = schema["oneOf"].array.filter { $0["type"].string != nil }
            let inferred = FlowValueType.name(value)
            let selected = choices.first { $0["type"].string == inferred } ?? choices.first ?? .object(["type": .string("string")])
            Picker("Value type", selection: Binding(get: { selected["type"].string ?? "string" }, set: { value = FlowValueType.empty($0); onError(nil) })) {
                ForEach(choices.compactMap { $0["type"].string }, id: \.self) { Text(FlowValueType.title($0)).tag($0) }
            }.labelsHidden().pickerStyle(.segmented)
            AnyView(FlowSchemaField(name: name, schema: selected, value: $value, required: required, depth: depth + 1, showLabel: false, onError: onError))
        } else if !schema["enum"].array.isEmpty {
            Picker(name, selection: Binding(get: { value.string ?? "" }, set: { value = .string($0); onError(nil) })) {
                Text("Choose…").tag("")
                ForEach(schema["enum"].array.compactMap(\.string), id: \.self) { Text($0).tag($0) }
            }.labelsHidden()
        } else if kind == "boolean" {
            Toggle(name, isOn: Binding(get: { value.bool ?? schema["default"].bool ?? false }, set: { value = .bool($0); onError(nil) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        } else if kind == "object", !schema["properties"].object.isEmpty, depth < 3 {
            DisclosureGroup("Fields") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(schema["properties"].object.keys.sorted(), id: \.self) { key in
                        AnyView(FlowSchemaField(name: key, schema: schema["properties"][key], value: Binding(
                            get: { value[key] }, set: { value = value.setting([key], to: $0 == .null ? nil : $0) }),
                            required: schema["required"].array.compactMap(\.string).contains(key), depth: depth + 1, onError: { error in
                                childErrors[key] = error; onError(childErrors.values.first)
                            }))
                    }
                }.padding(.leading, 8).padding(.top, 8)
            }
        } else if kind == "object", depth < 4 {
            FlowObjectFields(value: $value, depth: depth + 1, onError: onError)
        } else if kind == "array", depth < 4 {
            FlowArrayFields(value: $value, schema: schema["items"], depth: depth + 1, onError: onError)
        } else if kind == "object" || kind == "array" || schema["oneOf"] != .null || schema["type"] == .null {
            jsonInput
        } else if kind == "integer" || kind == "number" {
            TextField(name, text: Binding(get: { value == .null ? "" : value.fieldText }, set: { text in
                if text.isEmpty { value = .null; onError(nil) }
                else if let number = Double(text), kind != "integer" || number.rounded() == number { value = .number(number); onError(nil) }
                else { onError(String(localized: "Enter a valid number.")) }
            })).textFieldStyle(.roundedBorder)
        } else if name == "run" || name == "undo" || name == "script" {
            TextEditor(text: Binding(get: { value.string ?? "" }, set: { value = .string($0); onError(nil) }))
                .font(.system(size: 11, design: .monospaced)).frame(minHeight: 100)
                .padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        } else {
            TextField(name, text: Binding(get: { value.string ?? "" }, set: { value = .string($0); onError(nil) }), prompt: Text(schema["default"].fieldText))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var jsonInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $jsonDraft).font(.system(size: 11, design: .monospaced)).frame(minHeight: 70)
                .focused($editingJSON).padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
                .onAppear { jsonDraft = value == .null ? "" : value.jsonText }
                .onChange(of: value) { _, value in if !editingJSON { jsonDraft = value == .null ? "" : value.jsonText } }
                .onChange(of: jsonDraft) { _, text in
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { if value != .null { value = .null }; onError(nil); return }
                    do {
                        let parsed = try JSONDecoder().decode(FlowJSON.self, from: Data(text.utf8))
                        if parsed != value { value = parsed }
                        onError(nil)
                    }
                    catch { onError(String(localized: "Enter valid JSON for this input.")) }
                }
            Text("JSON value; other fields are preserved.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Free-form provider maps use key/value controls before offering raw JSON.
private struct FlowObjectFields: View {
    @Binding var value: FlowJSON
    let depth: Int
    let onError: (String?) -> Void
    @ViewState private var key = ""
    @ViewState private var kind = "string"
    @ViewState private var childErrors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(value.object.keys.sorted(), id: \.self) { name in
                AnyView(FlowSchemaField(name: name, schema: inferred(value[name]), value: Binding(get: { value[name] }, set: {
                    value = value.setting([name], to: $0 == .null ? nil : $0)
                }), depth: depth, onError: { error in childErrors[name] = error; onError(childErrors.values.first) }))
            }
            HStack(spacing: 6) {
                TextField("Field name", text: $key).textFieldStyle(.roundedBorder)
                Picker("Type", selection: $kind) {
                    Text("Text").tag("string")
                    Text("Number").tag("number")
                    Text("Boolean").tag("boolean")
                    Text("Object").tag("object")
                    Text("List").tag("array")
                }.labelsHidden().frame(width: 95)
                Button {
                    let newValue: FlowJSON = kind == "object" ? .object([:]) : kind == "array" ? .array([]) : kind == "boolean" ? .bool(false) : kind == "number" ? .number(0) : .string("")
                    value = value.setting([key], to: newValue); key = ""; onError(nil)
                } label: { Image(systemName: "plus") }
                .disabled(key.isEmpty || value.object[key] != nil).help("Add field")
            }
        }.padding(10).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func inferred(_ value: FlowJSON) -> FlowJSON {
        let type: String
        switch value {
        case .bool: type = "boolean"
        case .number: type = "number"
        case .object: type = "object"
        case .array: type = "array"
        default: type = "string"
        }
        return .object(["type": .string(type)])
    }
}
