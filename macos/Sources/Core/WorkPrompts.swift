import Foundation

struct WorkPrompt: Identifiable {
    let id: String
    let title: String
    let template: String
}

enum WorkPrompts {
    static let all = [
        WorkPrompt(id: "structure", title: "Understand this area", template: "Explain the responsibilities and dependencies of the selected area. Cite files and distinguish verified relationships from inferred ones."),
        WorkPrompt(id: "impact", title: "Assess change impact", template: "Trace the selected changes to their direct and indirect dependents. Explain the evidence, missing coverage and likely review priorities."),
        WorkPrompt(id: "review", title: "Review selected changes", template: "Review the selected changes for concrete correctness risks. Give a reproducible trigger and file evidence for each finding; distinguish facts from hypotheses."),
        WorkPrompt(id: "tests", title: "Plan relevant tests", template: "Identify relevant existing tests for this selection and explain each match. Separate suggested tests from executed results and do not invent commands."),
        WorkPrompt(id: "performance", title: "Investigate performance", template: "Find plausible performance bottlenecks in this selection and propose a bounded measurement. Cite the code and separate measured facts from untested hypotheses.")
    ]

    private static func selectionText(_ context: WorkContext) -> String {
        let paths = context.selectedPaths.isEmpty ? String(localized: "No files selected") : context.selectedPaths.joined(separator: ", ")
        return "\n\n" + String(localized: "Screen") + ": " + context.screenID + "\n" + String(localized: "Scope") + ": " + context.scope + "\n" + String(localized: "Selected paths") + ": " + paths
    }

    static func render(id: String, context: WorkContext, template: String? = nil) -> String {
        guard let prompt = all.first(where: { $0.id == id }) else { return "" }
        return (template ?? String(localized: String.LocalizationValue(prompt.template))) + selectionText(context)
    }

    static func editableTemplate(_ question: String, context: WorkContext) -> String {
        let suffix = selectionText(context)
        return (question.hasSuffix(suffix) ? String(question.dropLast(suffix.count)) : question).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
