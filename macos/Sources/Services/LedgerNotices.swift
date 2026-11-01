import Foundation

/// What the ledger has that a person should hear about (DESIGN.md §10.11), as keys, so the next read can tell what is
/// new. Nothing is announced for what the first read finds. (Windows: entities/ledger/lib/notices.ts)
struct LedgerSeen: Equatable {
    var questions: Set<Int> = []
    var tidy: Set<String> = []
    var applied: Set<String> = []
    var prompts: Set<Int> = []
    var autoReplies: Set<Int> = []

    init() {}

    init(_ state: LedgerState) {
        questions = Set(state.questions.filter { $0.state == .open }.map(\.id))
        tidy = Set(state.sessions.filter { $0.stream == nil && ($0.verdict == .confirm || $0.verdict == .expirable) }.map(\.id))
        applied = Set(state.streams.compactMap { c in c.appliedAt.map { _ in c.sessionId + "@" + c.version } })
        prompts = Set(state.pendingPrompts.filter { $0.state == .waiting }.map(\.id))
        autoReplies = Set(LedgerNotices.automatic(state).map(\.id))
    }
}

/// One notification: the text, and where clicking it opens the Ledger
struct LedgerNotice: Equatable {
    enum Kind: String {
        /// new questions, sessions to clean up and applied reports of one read, grouped
        case news
        /// an agent waiting for an answer: the question and the time left, or why it waits for the person
        case prompt
        /// what auto-continue sent
        case autoReply
    }
    var kind: Kind
    /// Unique per notification, so a newer one does not replace it
    var id: String
    var title: String
    var body: String
    /// The session the Ledger opens at
    var sessionId: String?
}

enum LedgerNotices {
    /// Automatic answers a person has not reviewed (the core's `autoReview`, or the older shape among the prompts)
    static func automatic(_ state: LedgerState) -> [LedgerPendingPrompt] {
        var auto = state.autoReview ?? []
        auto += state.pendingPrompts.filter { p in p.state == .auto && !auto.contains { $0.id == p.id } }
        return auto
    }

    /// What `state` has that `before` did not: the news of one read in one notification, each waiting prompt and each
    /// automatic answer in one of its own
    static func notices(_ state: LedgerState, since before: LedgerSeen, now: LedgerMs) -> [LedgerNotice] {
        let sessions = Dictionary(state.sessions.map { ($0.id, $0) }) { first, _ in first }
        func label(_ id: String?) -> String { id.map { sessions[$0].map { s in s.id + " " + s.title } ?? $0 } ?? "" }
        var notices: [LedgerNotice] = []

        let questions = state.questions.filter { $0.state == .open && !before.questions.contains($0.id) }.sorted { $0.id < $1.id }
        let tidy = state.sessions.filter { $0.stream == nil && ($0.verdict == .confirm || $0.verdict == .expirable) && !before.tidy.contains($0.id) }
            .sorted { $0.id < $1.id }
        let applied = state.streams.filter { c in c.appliedAt != nil && !before.applied.contains(c.sessionId + "@" + c.version) }
            .sorted { ($0.appliedAt ?? 0) < ($1.appliedAt ?? 0) }
        let count = questions.count + tidy.count + applied.count
        if count == 1 {
            if let q = questions.first {
                notices.append(.init(kind: .news, id: "q\(q.id)", title: String(localized: "\(label(q.sessionId)) asks"), body: q.text, sessionId: q.sessionId))
            } else if let s = tidy.first {
                notices.append(.init(kind: .news, id: "t:\(s.id):\(s.verdict.rawValue)", title: String(localized: "Ready to clean up"),
                                     body: label(s.id) + " · " + s.verdict.title, sessionId: s.id))
            } else if let c = applied.first {
                notices.append(.init(kind: .news, id: "a:\(c.sessionId)@\(c.version)", title: String(localized: "\(c.sessionId) applied \(c.version)"),
                                     body: c.appliedSummary ?? label(c.sessionId), sessionId: c.sessionId))
            }
        } else if count > 1 {
            var parts: [String] = []
            if !questions.isEmpty { parts.append(String(localized: "New questions: \(questions.count)")) }
            if !tidy.isEmpty { parts.append(String(localized: "To clean up: \(tidy.count)")) }
            if !applied.isEmpty { parts.append(String(localized: "Applied: \(applied.count)")) }
            let first = questions.first?.sessionId ?? tidy.first?.id ?? applied.first?.sessionId
            notices.append(.init(kind: .news, id: "n\(state.rev)", title: String(localized: "The Ledger has news"),
                                 body: parts.joined(separator: " · "), sessionId: first))
        }

        for p in state.pendingPrompts where p.state == .waiting && !before.prompts.contains(p.id) {
            let waits = LedgerCountdown.isCounting(p)
                ? String(localized: "Continues automatically in \(LedgerCountdown.text(deadline: p.deadline, now: now))")
                : LedgerPromptText.heldText(p)
            notices.append(.init(kind: .prompt, id: "p\(p.id)", title: String(localized: "\(label(p.sessionId)) is waiting"),
                                 body: LedgerPromptText.summary(p) + "\n" + waits, sessionId: p.sessionId))
        }
        for p in automatic(state) where !before.autoReplies.contains(p.id) {
            let sent = LedgerPromptText.sent(p.answer ?? [:])
            notices.append(.init(kind: .autoReply, id: "r\(p.id)", title: String(localized: "Auto-continue answered \(label(p.sessionId))"),
                                 body: LedgerPromptText.summary(p) + (sent.isEmpty ? "" : "\n“" + sent + "”"), sessionId: p.sessionId))
        }
        return notices
    }
}
