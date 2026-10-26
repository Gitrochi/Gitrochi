import Foundation

/// 대화는 새로 선택한 변경 대신 처음 확인한 미리보기만 계속 참조한다.
struct ChangeQuestionSnapshot: Equatable {
    static let diffLimit = 100_000
    static let questionLimit = 6_000
    static let answerLimit = 24_000
    static let historyLimit = 64_000
    let repository: String
    let head: String
    let scope: String
    let path: String?
    let diff: String
    let omitted: Int
    let limitations: [String]
    let impact: String?

    init(repository: String, head: String, scope: String, path: String?, diff: String,
         limitations: [String] = [], impact: String? = nil) {
        self.repository = repository
        self.head = head
        self.scope = scope
        self.path = path
        self.diff = String(diff.prefix(Self.diffLimit))
        omitted = max(0, diff.count - Self.diffLimit)
        self.limitations = limitations
        self.impact = impact.map { String($0.prefix(12_000)) }
    }

    var context: String {
        "Repository: \(repository)\nHEAD at capture: \(head)\nScope: \(scope)\nFile: \(path ?? "(all files in scope)")\n"
        + "Limitations: \((limitations + (omitted > 0 ? ["Diff truncated; \(omitted) characters omitted."] : [])).joined(separator: " "))\n"
        + (impact.map { "\nEstimated staged impact / test candidates (tests were NOT run):\n\($0)\n" } ?? "")
        + "\n<change_data>\n\(diff)\n</change_data>"
    }

    func prompt(question: String, messages: [ChangeQuestionMessage]) -> String {
        var history = ""
        for message in messages.reversed() {
            let entry = "\n\(message.isUser ? "User" : "Assistant"):\n\(message.text)\n"
            guard history.count + entry.count <= Self.historyLimit else { break }
            history = entry + history
        }
        return context + "\n\nPrevious conversation:\n" + history + "\nCurrent question:\n" + question
    }

    static func boundedAnswer(_ answer: String) -> String { String(answer.prefix(answerLimit)) }
}

struct ChangeQuestionMessage: Identifiable, Equatable {
    let id = UUID()
    let isUser: Bool
    let text: String
}
