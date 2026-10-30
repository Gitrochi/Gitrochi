import SwiftUI

enum FlowValueType {
    static func name(_ value: FlowJSON) -> String {
        switch value {
        case .bool: return "boolean"
        case .number: return "number"
        case .object: return "object"
        case .array: return "array"
        default: return "string"
        }
    }
    static func empty(_ type: String) -> FlowJSON {
        switch type {
        case "object": return .object([:])
        case "array": return .array([])
        case "boolean": return .bool(false)
        case "integer", "number": return .number(0)
        default: return .string("")
        }
    }
    static func title(_ type: String) -> String {
        switch type {
        case "object": return String(localized: "Object")
        case "array": return String(localized: "List")
        case "boolean": return String(localized: "Boolean")
        case "integer", "number": return String(localized: "Number")
        default: return String(localized: "Text")
        }
    }
}

/// Lists keep individual values intact, including command arguments containing commas.
struct FlowArrayFields: View {
    @Binding var value: FlowJSON
    let schema: FlowJSON
    let depth: Int
    let onError: (String?) -> Void
    @ViewState private var errors: [Int: String] = [:]
    @ViewState private var type = "string"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(value.array.indices), id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    AnyView(FlowSchemaField(name: "\(index + 1)", schema: schema != .null ? schema : .object(["type": .string(FlowValueType.name(value.array.indices.contains(index) ? value.array[index] : .null))]), value: Binding(
                        get: { value.array.indices.contains(index) ? value.array[index] : .null },
                        set: { newValue in var items = value.array; if items.indices.contains(index) { items[index] = newValue; value = .array(items) } }),
                        depth: depth, showLabel: false, onError: { error in errors[index] = error; onError(errors.values.first) }))
                    Button {
                        var items = value.array; guard items.indices.contains(index) else { return }; items.remove(at: index); value = .array(items); errors = [:]; onError(nil)
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove item")
                }
            }
            HStack {
                if schema["type"] == .null {
                    Picker("Type", selection: $type) {
                        ForEach(["string", "number", "boolean", "object", "array"], id: \.self) { Text(FlowValueType.title($0)).tag($0) }
                    }.labelsHidden().frame(maxWidth: 120)
                }
                Button { value = .array(value.array + [FlowValueType.empty(schema["type"].string ?? type)]) } label: { Label("Add item", systemImage: "plus") }
                    .controlSize(.small)
            }
        }.padding(9).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
