import Foundation

/// The lossless authoring contract of gitch-flow design inspect/render.
struct FlowDesignDiagnostic: Decodable, Identifiable {
    struct Group: Identifiable {
        let code: String
        let message: String
        var diagnostics: [FlowDesignDiagnostic]
        var id: String { "\(code.count):" + code + message }
        var severity: String {
            if diagnostics.contains(where: { $0.severity == "error" }) { return "error" }
            return diagnostics.contains(where: { $0.severity == "warning" }) ? "warning" : "info"
        }
        var paths: [String] { Array(Set(diagnostics.compactMap(\.path))).sorted() }
    }

    let severity: String
    let code: String
    let message: String
    let path: String?
    let line: Int?
    var id: String { code + message + (path ?? "") }

    /// Repeated provider warnings share one presentation row while all original diagnostics remain available.
    static func grouped(_ diagnostics: [Self]) -> [Group] {
        var groups: [Group] = []
        var indexes: [String: Int] = [:]
        for diagnostic in diagnostics {
            let key = "\(diagnostic.code.count):" + diagnostic.code + diagnostic.message
            if let index = indexes[key] { groups[index].diagnostics.append(diagnostic) }
            else {
                indexes[key] = groups.count
                groups.append(Group(code: diagnostic.code, message: diagnostic.message, diagnostics: [diagnostic]))
            }
        }
        return groups
    }
}

struct FlowDesignInspection: Decodable {
    struct Proposal: Decodable {
        let document: FlowJSON
        let yaml: String
    }
    let document: FlowJSON?
    let yaml: String
    let format: String
    let diagnostics: [FlowDesignDiagnostic]
    let editable: Bool
    let proposal: Proposal?
}

struct FlowDesignRendered: Decodable {
    let yaml: String
    let diagnostics: [FlowDesignDiagnostic]
    let formattingChanged: Bool
}

struct FlowBlockCatalog: Decodable {
    struct Block: Decodable, Identifiable {
        let id: String
        let title: String
        let category: String
        let capabilities: [String]
        let destructive: Bool
        let outward: Bool
        let inputs: FlowJSON
        let outputs: FlowJSON?
    }
    let blocks: [Block]
}

extension FlowJSON {
    var object: [String: FlowJSON] { if case .object(let value) = self { return value }; return [:] }
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }
    var jsonText: String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
    var fieldText: String { string ?? (self == .null ? "" : jsonText) }

    /// Replaces one field while retaining every sibling, including unknown future settings.
    func setting(_ path: [String], to value: FlowJSON?) -> FlowJSON {
        guard let key = path.first else { return value ?? .null }
        var map = object
        if path.count == 1 { map[key] = value }
        else { map[key] = (map[key] ?? .object([:])).setting(Array(path.dropFirst()), to: value) }
        return .object(map)
    }

    var dependencyIDs: [String] {
        if let string { return [string] }
        return array.compactMap(\.string)
    }
}
