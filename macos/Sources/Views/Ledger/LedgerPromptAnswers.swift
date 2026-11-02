import Foundation

/// One editable answer, shared by hook prompts and questions reported through MCP.
struct LedgerAnswerQuestion: Identifiable, Hashable {
    var id: String
    var question: String
    var header: String?
    var options: [LedgerPromptText.Option]
    var multiple: Bool
    var suggestion: String?
    var browserDraft = false
}

/// Answer drafts remain separate from sending (Windows: entities/ledger/lib/answers.ts).
enum LedgerPromptAnswers {
    static func options(_ value: LedgerJSON) -> [LedgerPromptText.Option] {
        value.array.compactMap { raw in
            if let label = nonempty(raw.string) {
                return .init(label: label, recommended: markedRecommended(label))
            }
            guard let label = nonempty(raw["label"].string) else { return nil }
            return .init(label: label, description: raw["description"].string,
                         recommended: raw["recommended"].bool ?? (markedRecommended(label) || markedRecommended(raw["description"].string ?? "")))
        }
    }

    static func questions(_ prompt: LedgerPendingPrompt) -> [LedgerAnswerQuestion] {
        if prompt.kind == .stopQuestion {
            let choices = options(prompt.payload["options"] ?? .null)
            return [.init(id: "stop", question: LedgerPromptText.summary(prompt), options: choices, multiple: false,
                          suggestion: nonempty(prompt.payload["suggestedAnswer"]?.string)
                            ?? nonempty(prompt.payload["proposed"]?["text"].string)
                            ?? recommended(choices, multiple: false))]
        }
        return (prompt.payload["questions"]?.array ?? []).enumerated().compactMap { index, raw in
            guard let question = nonempty(raw["question"].string) else { return nil }
            let choices = options(raw["options"])
            let multiple = raw["multiSelect"].bool ?? false
            return .init(id: String(index), question: question, header: nonempty(raw["header"].string), options: choices,
                         multiple: multiple, suggestion: nonempty(raw["suggestedAnswer"].string)
                            ?? nonempty(prompt.payload["proposed"]?["answers"][question].string)
                            ?? recommended(choices, multiple: multiple))
        }
    }

    static func question(_ question: LedgerQuestion) -> LedgerAnswerQuestion {
        let choices: [LedgerPromptText.Option] = (question.options ?? []).map {
            .init(label: $0.label, description: $0.description, recommended: $0.recommended ?? markedRecommended($0.label))
        }
        let multiple = question.multiSelect ?? false
        return .init(id: String(question.id), question: question.text, options: choices, multiple: multiple,
                     suggestion: nonempty(question.browserDraft) ?? nonempty(question.suggestedAnswer) ?? recommended(choices, multiple: multiple),
                     browserDraft: nonempty(question.browserDraft) != nil)
    }

    /// Every question needs a draft before the form can send a single reply.
    static func answers(_ questions: [LedgerAnswerQuestion], drafts: [String: String]) -> [String: String]? {
        guard !questions.isEmpty else { return nil }
        var answer: [String: String] = [:]
        for question in questions {
            guard let text = nonempty(drafts[question.id]) else { return nil }
            answer[question.question] = text
        }
        return answer
    }

    static func selectedText(_ selected: Set<String>, options: [LedgerPromptText.Option]) -> String {
        options.filter { selected.contains($0.label) }.map(\.label).joined(separator: ", ")
    }

    /// Suggestions mark complete matching choices; an exact label may itself contain commas.
    static func selectedOptions(text: String, options: [LedgerPromptText.Option], multiple: Bool) -> Set<String> {
        let exact = Set(options.filter { $0.label == text }.map(\.label))
        if !exact.isEmpty || !multiple { return exact }
        let parts = Set(text.components(separatedBy: ", "))
        let selected = Set(options.filter { parts.contains($0.label) }.map(\.label))
        return selectedText(selected, options: options) == text ? selected : []
    }

    /// Tab fills an untouched editor; text, reverse navigation and composition are never replaced.
    static func canFill(text: String, suggestion: String?, shifted: Bool = false, composing: Bool = false) -> Bool {
        text.isEmpty && nonempty(suggestion) != nil && !shifted && !composing
    }

    private static func markedRecommended(_ label: String) -> Bool {
        label.range(of: "(?i)\\(recommended\\)\\s*$", options: .regularExpression) != nil
    }

    private static func recommended(_ options: [LedgerPromptText.Option], multiple: Bool) -> String? {
        let choices = options.filter(\.recommended)
        return multiple ? nonempty(choices.map(\.label).joined(separator: ", ")) : choices.first?.label
    }

    private static func nonempty(_ text: String?) -> String? {
        text.flatMap { let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines); return clean.isEmpty ? nil : clean }
    }
}
