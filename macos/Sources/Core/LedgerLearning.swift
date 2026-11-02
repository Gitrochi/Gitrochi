import Foundation
import Observation

/// Local tutorial progress; practice never calls the Ledger backend (Windows: entities/ledger/lib/learning.ts).
@MainActor @Observable
final class LedgerLearning {
    enum Step: Int, CaseIterable, Identifiable {
        case concepts, views, answer, delivery, connect
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .concepts: String(localized: "Sessions and baselines")
            case .views: String(localized: "Choose a view")
            case .answer: String(localized: "Try answering a question")
            case .delivery: String(localized: "Follow an answer to completion")
            case .connect: String(localized: "Connect your agent")
            }
        }
        var body: String {
            switch self {
            case .concepts: LedgerGuideTopic.concepts.body
            case .views: LedgerGuideTopic.views.body
            case .answer: LedgerGuideTopic.answers.body
            case .delivery: LedgerGuideTopic.delivery.body
            case .connect: String(localized: "Connect Claude Code or Codex through Connect agents. For ChatGPT web, use the browser extension to sync completed choice questions. Activity tracking alone is not an agent report.")
            }
        }
    }

    enum Delivery: String, Codable {
        case saved, delivered, confirmed, archived
        var caption: String {
            switch self {
            case .saved: String(localized: "Your answer is saved. Mark it delivered to simulate the agent reading it.")
            case .delivered: String(localized: "The agent has received the practice answer. Confirm the result next.")
            case .confirmed: String(localized: "The result is confirmed. Clean up to archive the conversation.")
            case .archived: String(localized: "Practice complete. The conversation is archived.")
            }
        }
    }

    struct Progress: Codable, Equatable {
        var version = 1
        var step = 0
        var completed = false
        var answerSent = false
        var deliveryState = Delivery.saved
    }

    private let defaults: UserDefaults
    private(set) var progress: Progress
    var answerDraft = ""
    var chosenView = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "ledgerLearning"),
           let saved = try? JSONDecoder().decode(Progress.self, from: data), saved.version == 1 {
            var restored = saved
            restored.step = min(max(saved.step, 0), Step.allCases.count - 1)
            if !restored.answerSent && restored.step >= Step.delivery.rawValue { restored.step = Step.answer.rawValue }
            if restored.step == Step.connect.rawValue && restored.deliveryState != .archived { restored.step = Step.delivery.rawValue }
            if !restored.answerSent || restored.deliveryState != .archived { restored.completed = false }
            progress = restored
        } else {
            progress = Progress()
        }
    }

    var step: Step { Step(rawValue: progress.step) ?? .concepts }
    var canAdvance: Bool {
        switch step {
        case .answer: progress.answerSent
        case .delivery: progress.deliveryState == .archived
        default: true
        }
    }

    /// The example question uses the production answer editor, with no real session ID.
    static var question: LedgerAnswerQuestion {
        .init(id: "tutorial", question: String(localized: "Which channel should this practice session use?"),
              options: [.init(label: String(localized: "Stable"), description: String(localized: "Use a verified release"), recommended: true),
                        .init(label: String(localized: "Nightly"), description: String(localized: "Try the newest changes"), recommended: false)],
              multiple: false, suggestion: String(localized: "Stable"))
    }

    @discardableResult func sendPracticeAnswer() -> Bool {
        guard step == .answer, !answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        progress.answerSent = true
        progress.deliveryState = .saved
        persist()
        return true
    }

    func deliver() {
        guard step == .delivery, progress.answerSent, progress.deliveryState == .saved else { return }
        progress.deliveryState = .delivered
        persist()
    }

    func confirm() {
        guard step == .delivery, progress.deliveryState == .delivered else { return }
        progress.deliveryState = .confirmed
        persist()
    }

    func archive() {
        guard step == .delivery, progress.deliveryState == .confirmed else { return }
        progress.deliveryState = .archived
        persist()
    }

    func next() {
        guard canAdvance else { return }
        if step == .connect { progress.completed = true }
        else { progress.step += 1 }
        persist()
    }

    func back() {
        progress.step = max(0, progress.step - 1)
        persist()
    }

    func restart() {
        progress = Progress()
        answerDraft = ""
        chosenView = 0
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: "ledgerLearning") }
    }
}

/// Searchable reference topics reuse the tutorial's explanations.
enum LedgerGuideTopic: String, CaseIterable, Identifiable {
    case setup, concepts, views, answers, delivery, cleanup, shortcuts, troubleshooting, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: String(localized: "Setup")
        case .concepts: String(localized: "Sessions and baselines")
        case .views: String(localized: "Choose a view")
        case .answers: String(localized: "Answer questions")
        case .delivery: String(localized: "Answer delivery")
        case .cleanup: String(localized: "Review and clean up")
        case .shortcuts: String(localized: "Keyboard shortcuts")
        case .troubleshooting: String(localized: "Troubleshooting")
        case .privacy: String(localized: "Privacy")
        }
    }
    var body: String {
        switch self {
        case .setup: String(localized: "Use Connect agents to copy setup instructions for Claude Code and Codex. Start a new conversation after setup, then ask the agent for a start report with its session ID.")
        case .concepts: String(localized: "A session is one unit of agent work. Its baseline is the version it started from. Later reports record progress, decisions and outcomes.")
        case .views: String(localized: "Inbox holds questions and decisions that need you. Board lists sessions, Graph shows their history, and Streams follows ongoing implementation.")
        case .answers: String(localized: "Choose an option, or focus the empty answer and press Tab to fill an explicit suggestion. Edit the draft, then send it. Choosing or filling never sends an answer.")
        case .delivery: String(localized: "Saving an answer and delivering it are separate. The agent receives a reported answer with its next report or read. Confirming accepts the outcome; cleaning up archives the conversation.")
        case .cleanup: String(localized: "Confirm a finished result after reviewing it. Clean up archives the conversation without stopping an agent or deleting a branch. A stale session needs review; use Still active when its work continues.")
        case .shortcuts: String(localized: "In Inbox, use ↑/↓ to move, Return to open, A to answer, C to confirm and E to clean up. Tab fills an empty answer only when an explicit suggestion exists. Return adds a line; use the form's send button when ready.")
        case .troubleshooting: String(localized: "If a session is missing, check the selected project and Unreported filter. If no reports appear, verify the agent connection and ask for a report. Held prompts must be answered in the agent's terminal.")
        case .privacy: String(localized: "Practice uses local example data. Ledger stores reports and saved answers. The browser extension reads only the ChatGPT conversation you connect and optional drafts accepted with Tab. It does not read other tabs or desktop predictions.")
        }
    }

    var detail: String? {
        switch self {
        case .answers: String(localized: "For multiple choices, select all that apply. You can edit the combined answer or write a different one.")
        case .delivery: String(localized: "Use Copy answer to paste a saved answer into a conversation that cannot read this Ledger.")
        default: nil
        }
    }

    static func matching(_ query: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return allCases.filter { topic in
            let text = topic.title + " " + topic.body + " " + (topic.detail ?? "")
            return words.allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }
}
