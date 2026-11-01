import Foundation

/// A new flow draft mirrors Windows entities/flow/model/creation.ts without running its commands.
struct FlowCreationDraft {
    struct Step: Identifiable, Equatable {
        var id = UUID()
        var title = ""
        var command = ""
    }

    enum Execution: String, CaseIterable { case inOrder, inParallel }
    enum Problem: Equatable {
        case missingName, invalidName, duplicateName, missingSteps, missingCommand

        var message: String {
            switch self {
            case .missingName: return String(localized: "Enter a flow name.")
            case .invalidName: return String(localized: "Use 1–64 lowercase letters, numbers, hyphens or underscores, starting with a letter.")
            case .duplicateName: return String(localized: "A flow with this name already exists.")
            case .missingSteps: return String(localized: "Add at least one step.")
            case .missingCommand: return String(localized: "Enter a command for every step.")
            }
        }
    }

    var name = ""
    var description = ""
    var steps = [Step()]
    var execution = Execution.inOrder
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var file: String { ".gitch/flows/\(trimmedName).yml" }
    var hasChanges: Bool {
        !name.isEmpty || !description.isEmpty || steps.count != 1 || execution != .inOrder ||
        steps.contains { !$0.title.isEmpty || !$0.command.isEmpty }
    }

    func problem(existingNames: [String]) -> Problem? {
        if trimmedName.isEmpty { return .missingName }
        if trimmedName.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) == nil { return .invalidName }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }) { return .duplicateName }
        if steps.isEmpty { return .missingSteps }
        if steps.contains(where: { $0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return .missingCommand }
        return nil
    }

    /// Commands keep their original whitespace; dependencies follow the visible draft order.
    func document() -> FlowJSON {
        var nodes: [String: FlowJSON] = [:]
        for (index, step) in steps.enumerated() {
            var node: [String: FlowJSON] = ["run": .string(step.command)]
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { node["description"] = .string(title) }
            if execution == .inOrder, index > 0 { node["needs"] = .array([.string("step-\(index)")]) }
            nodes["step-\(index + 1)"] = .object(node)
        }
        var flow: [String: FlowJSON] = ["trigger": .array([.string("manual")]), "nodes": .object(nodes)]
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { flow["description"] = .string(description) }
        return .object(["version": .number(1), "flows": .object([trimmedName: .object(flow)])])
    }
}
