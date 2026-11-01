import Foundation

// Pure rules for how the Ledger reads on screen. Windows has the same functions with the same shapes in
// entities/ledger/lib (verdict.ts, countdown.ts, filter.ts, inbox.ts, undo.ts).

extension LedgerVerdict {
    /// Most urgent first: the order of the verdict chips, the Board and the filter column
    /// (Windows: entities/ledger/lib/verdict.ts VERDICT_ORDER)
    static let displayOrder: [LedgerVerdict] = [.needsHuman, .pendingMerge, .confirm, .expirable, .stale, .active, .shelved, .archived]

    var rank: Int { Self.displayOrder.firstIndex(of: self) ?? Self.displayOrder.count }

    var title: String {
        switch self {
        case .needsHuman: return String(localized: "Needs you")
        case .pendingMerge: return String(localized: "To decide")
        case .confirm: return String(localized: "To confirm")
        case .expirable: return String(localized: "Ready to archive")
        case .stale: return String(localized: "Stale")
        case .active: return String(localized: "Active")
        case .shelved: return String(localized: "Shelved")
        case .archived: return String(localized: "Archived")
        }
    }

    var symbol: String {
        switch self {
        case .needsHuman: return "questionmark.bubble"
        case .pendingMerge: return "arrow.triangle.merge"
        case .confirm: return "checkmark.circle"
        case .expirable: return "archivebox"
        case .stale: return "clock.badge.exclamationmark"
        case .active: return "circle.dotted"
        case .shelved: return "books.vertical"
        case .archived: return "archivebox.fill"
        }
    }

    /// What a person does about it
    var advice: String {
        switch self {
        case .needsHuman: return String(localized: "Answer or dismiss the open questions; the session receives the answer with its next report.")
        case .pendingMerge: return String(localized: "Decide: mark it merged into a version, close it or drop it.")
        case .confirm: return String(localized: "Check the outcome and confirm it.")
        case .expirable: return String(localized: "Confirmed. Close the conversation, then archive the session.")
        case .stale: return String(localized: "No report for three days. Check the conversation: close it, or mark it Still active if it is still going.")
        case .active: return String(localized: "Work in progress. Nothing to do yet.")
        case .shelved: return String(localized: "Paused on purpose. Keep the conversation; it never turns stale.")
        case .archived: return String(localized: "Cleaned up. A new report brings it back.")
        }
    }
}

extension LedgerStatus {
    var title: String {
        switch self {
        case .active: return String(localized: "Active")
        case .done: return String(localized: "Done")
        case .merged: return String(localized: "Merged")
        case .closed: return String(localized: "Closed")
        case .dropped: return String(localized: "Dropped")
        case .shelved: return String(localized: "Shelved")
        }
    }
}

extension LedgerRole {
    var title: String {
        switch self {
        case .decision: return String(localized: "Decision")
        case .implementation: return String(localized: "Implementation")
        case .research: return String(localized: "Research")
        case .document: return String(localized: "Document")
        case .other: return String(localized: "Other")
        }
    }
}

extension LedgerBaseline.Source {
    var title: String {
        switch self {
        case .tag: return String(localized: "Tag")
        case .folder: return String(localized: "Folder")
        case .registered: return String(localized: "Registered")
        case .release: return String(localized: "Released by a session")
        case .inferred: return String(localized: "Inferred from a report")
        }
    }
}

extension LedgerRange {
    var title: String {
        switch self {
        case .week: return String(localized: "7 days")
        case .month: return String(localized: "30 days")
        case .all: return String(localized: "All")
        }
    }
}

extension LedgerSearchHit.Kind {
    var symbol: String {
        switch self {
        case .session: return "rectangle.stack"
        case .question: return "questionmark.bubble"
        case .event: return "text.bubble"
        case .baseline: return "tag"
        }
    }
}

/// Timeline wording for event types; unknown types show as they are (Windows: entities/ledger/lib/verdict.ts eventTitle)
enum LedgerEventText {
    static func title(_ type: String) -> String {
        switch type {
        case "start": return String(localized: "Started")
        case "progress": return String(localized: "Progress")
        case "artifact": return String(localized: "Artifact")
        case "question": return String(localized: "Question")
        case "decision": return String(localized: "Decision")
        case "sync": return String(localized: "Synced")
        case "done": return String(localized: "Done")
        case "merged": return String(localized: "Merged")
        case "closed": return String(localized: "Closed")
        case "dropped": return String(localized: "Dropped")
        case "shelved", "shelve": return String(localized: "Shelved")
        case "release": return String(localized: "Released")
        case "applied": return String(localized: "Applied")
        case "note": return String(localized: "Note")
        case "auto_reply": return String(localized: "Auto-continued")
        case "prompt_answer": return String(localized: "Answered the prompt")
        case "ack": return String(localized: "Confirmed")
        case "unack": return String(localized: "Unconfirmed")
        case "archive": return String(localized: "Archived")
        case "unarchive": return String(localized: "Unarchived")
        case "set_status": return String(localized: "Changed the status")
        case "answer": return String(localized: "Answered")
        case "dismiss": return String(localized: "Dismissed")
        case "snooze": return String(localized: "Snoozed")
        case "link": return String(localized: "Linked")
        case "message": return String(localized: "Message")
        case "review": return String(localized: "Reviewed")
        default: return type
        }
    }

    /// The milestones that end or hand over a session, drawn stronger in the timeline
    static func isMilestone(_ type: String) -> Bool {
        ["start", "done", "merged", "closed", "dropped", "release", "applied", "sync", "shelved"].contains(type)
    }
}

/// The time left before auto-continue answers a prompt (Windows: entities/ledger/lib/countdown.ts)
enum LedgerCountdown {
    /// "0:42", "4:05", "1:02:03"; rounds up, so "0:00" means the time is up
    static func text(deadline: LedgerMs, now: LedgerMs) -> String {
        let left = max(0, (deadline - now + 999) / 1000)
        let hours = left / 3600, minutes = (left % 3600) / 60, seconds = left % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// How much of the wait is left, from 1 to 0, for the bar under the countdown
    static func fraction(created: LedgerMs, deadline: LedgerMs, now: LedgerMs) -> Double {
        guard deadline > created else { return 0 }
        return min(1, max(0, Double(deadline - now) / Double(deadline - created)))
    }

    /// Whether auto-continue will answer it: a held prompt (deadline 0) waits for a person
    static func isCounting(_ prompt: LedgerPendingPrompt) -> Bool { prompt.state == .waiting && prompt.deadline > 0 }

    /// The same time for VoiceOver ("42 seconds")
    static func spoken(deadline: LedgerMs, now: LedgerMs) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: TimeInterval(max(0, (deadline - now + 999) / 1000))) ?? text(deadline: deadline, now: now)
    }
}

extension LedgerPendingPrompt.Kind {
    var title: String {
        switch self {
        case .stopQuestion: return String(localized: "Asks a question")
        case .askUserQuestion: return String(localized: "Asks you to choose")
        case .exitPlanMode: return String(localized: "Plan to approve")
        case .permission: return String(localized: "Asks for permission")
        }
    }

    var symbol: String {
        switch self {
        case .stopQuestion: return "questionmark.bubble"
        case .askUserQuestion: return "list.bullet.circle"
        case .exitPlanMode: return "list.clipboard"
        case .permission: return "lock.shield"
        }
    }
}

/// Auto-continue's waits: the core keeps them between 10 s and 5 minutes (gitrochi-autocontinue's policy)
enum LedgerWait {
    static func clamped(_ seconds: Int) -> Int { min(max(seconds, 10), 300) }

    /// The waits a picker offers, with the session's own among them
    static func choices(including seconds: Int) -> [Int] {
        Array(Set([10, 15, 20, 30, 45, 60, 90, 120, 180, 300, clamped(seconds)])).sorted()
    }
}

/// What a waiting prompt asks and what auto-continue sends, read from the hook handler's payload (gitrochi-autocontinue's
/// PromptPayload: question, text, options, questions, tool, delaySec, proposed) and from the answer (its AutoReply with
/// `sent`, or what a person sent). (Windows: entities/ledger/lib/prompt.ts)
enum LedgerPromptText {
    struct Option: Hashable {
        var label: String
        var description: String?
        var recommended: Bool
    }

    /// One line: the question, the first question asked, the plan's title or the tool call
    static func summary(_ p: LedgerPendingPrompt) -> String {
        if let question = p.payload["question"]?.string, !question.isEmpty { return question }
        if let question = p.payload["questions"]?.array.first?["question"].string, !question.isEmpty { return question }
        if let tool = tool(p) { return tool.summary.isEmpty ? tool.name : tool.name + ": " + tool.summary }
        if let text = body(p) { return firstLine(text) }
        return p.kind.title
    }

    /// The paragraphs that ask (a question at the end of a turn) or the plan (Markdown)
    static func body(_ p: LedgerPendingPrompt) -> String? {
        p.payload["text"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// The tool a permission request is about, and its call in one line
    static func tool(_ p: LedgerPendingPrompt) -> (name: String, summary: String)? {
        let tool = p.payload["tool"] ?? .null
        guard let name = tool["name"].string, !name.isEmpty else { return nil }
        return (name, tool["summary"].string ?? "")
    }

    /// Choices listed with a question, or of one AskUserQuestion question
    static func options(_ value: LedgerJSON) -> [Option] {
        value.array.compactMap { o in
            o["label"].string.map { Option(label: $0, description: o["description"].string, recommended: o["recommended"].bool ?? false) }
        }
    }

    /// What goes out when nobody answers in time, in one line
    static func proposed(_ p: LedgerPendingPrompt) -> String? { p.payload["proposed"].flatMap(describe(sent:)) }

    /// What was sent: auto-continue's `sent`, else a person's text, choices or decision
    static func sent(_ answer: [String: LedgerJSON]) -> String {
        if let sent = answer["sent"], let text = describe(sent: sent) { return text }
        if let text = answer["text"]?.string { return firstLine(text) }
        if let decision = answer["decision"]?.string { return decision == "allow" ? String(localized: "Allowed") : String(localized: "Denied") }
        if let answers = answer["answers"]?.object { return answers.keys.sorted().compactMap { answers[$0]?.string }.joined(separator: ", ") }
        return ""
    }

    /// An automatic permission answer whose effect is open: the terminal showed its own dialog during the wait, and the
    /// person may have answered there (#171)
    static func outcome(_ answer: [String: LedgerJSON]?) -> String? {
        switch answer?["outcome"]?.string {
        case "unconfirmed": return String(localized: "Not confirmed yet: the terminal showed its own dialog too")
        case "unknown": return String(localized: "Unknown whether it applied: the terminal showed its own dialog too")
        default: return nil
        }
    }

    private static func describe(sent: LedgerJSON) -> String? {
        switch sent["type"].string {
        case "reply": return sent["text"].string.map(firstLine)
        case "answers":
            guard let answers = sent["answers"].object else { return nil }
            return answers.keys.sorted().compactMap { answers[$0]?.string }.joined(separator: ", ")
        case "approve_plan": return String(localized: "Approve the plan")
        case "allow": return String(localized: "Allow once")
        default: return nil
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
    }
}

/// The Board's filter: verdict chips, text and archived sessions (Windows: entities/ledger/lib/filter.ts)
struct LedgerSessionFilter: Equatable {
    /// Empty: every verdict
    var verdicts: Set<LedgerVerdict> = []
    var text = ""
    var showArchived = false

    /// Every word has to appear in the ID, title, kind, branch or a touch (case and accents ignored)
    func matches(_ s: LedgerSession) -> Bool {
        if s.stream != nil { return false }
        if !verdicts.isEmpty, !verdicts.contains(s.verdict) { return false }
        if s.verdict == .archived, !showArchived, !verdicts.contains(.archived) { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([s.id, s.title, s.kind, s.links.branch ?? ""] + s.touches).joined(separator: " ")
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }

    /// The Board's rows: streams left out, the most urgent first, then the latest activity
    func apply(_ sessions: [LedgerSession]) -> [LedgerSession] {
        sessions.filter(matches).sorted { a, b in
            a.verdict.rank != b.verdict.rank ? a.verdict.rank < b.verdict.rank : a.lastAt != b.lastAt ? a.lastAt > b.lastAt : a.id < b.id
        }
    }

    /// Sessions per verdict for the chips; streams are counted apart
    static func counts(_ sessions: [LedgerSession]) -> [LedgerVerdict: Int] {
        var counts: [LedgerVerdict: Int] = [:]
        for s in sessions where s.stream == nil { counts[s.verdict, default: 0] += 1 }
        return counts
    }
}

/// The Inbox: only what needs a person, in the order it is worked through (Windows: entities/ledger/lib/inbox.ts)
struct LedgerInbox: Equatable {
    enum Group: String, CaseIterable, Hashable {
        case questions, autoReview, tidy, decide

        var title: String {
            switch self {
            case .questions: return String(localized: "Questions")
            case .autoReview: return String(localized: "Auto-continued — review")
            case .tidy: return String(localized: "To clean up")
            case .decide: return String(localized: "To decide")
            }
        }
    }

    struct Item: Identifiable, Hashable {
        enum Content: Hashable {
            case question(LedgerQuestion)
            case autoReply(LedgerPendingPrompt)
            case session
        }
        let id: String
        let group: Group
        let sessionId: String?
        let content: Content
    }

    /// Prompts an agent is waiting on: the ones counting down first, soonest deadline first
    var prompts: [LedgerPendingPrompt] = []
    /// Everything else, in keyboard order: questions, auto-continued, to clean up, to decide
    var items: [Item] = []

    func items(in group: Group) -> [Item] { items.filter { $0.group == group } }
    var count: Int { items.count }

    static func build(_ state: LedgerState) -> LedgerInbox {
        let sessions = Dictionary(state.sessions.map { ($0.id, $0) }) { first, _ in first }
        var inbox = LedgerInbox()
        inbox.prompts = state.pendingPrompts.filter { $0.state == .waiting }.sorted { a, b in
            let (ca, cb) = (LedgerCountdown.isCounting(a), LedgerCountdown.isCounting(b))
            if ca != cb { return ca }
            return ca && a.deadline != b.deadline ? a.deadline < b.deadline : a.id < b.id
        }
        // questions stay together per session; the session asked most recently comes first
        let open = state.questions.filter { q in q.state == .open && sessions[q.sessionId].map { $0.verdict != .archived } == true }
        let newest = Dictionary(grouping: open, by: \.sessionId).mapValues { $0.map(\.createdAt).max() ?? 0 }
        let questions = open.sorted { a, b in
            let (na, nb) = (newest[a.sessionId] ?? 0, newest[b.sessionId] ?? 0)
            if na != nb { return na > nb }
            if a.sessionId != b.sessionId { return a.sessionId < b.sessionId }
            return a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
        }
        inbox.items += questions.map { Item(id: "q\($0.id)", group: .questions, sessionId: $0.sessionId, content: .question($0)) }
        // the core lists them in `autoReview`; an older shape kept them among the pending prompts
        var auto = state.autoReview ?? []
        auto += state.pendingPrompts.filter { p in p.state == .auto && !auto.contains { $0.id == p.id } }
        auto.sort { ($0.answeredAt ?? $0.deadline) > ($1.answeredAt ?? $1.deadline) }
        inbox.items += auto.map { Item(id: "p\($0.id)", group: .autoReview, sessionId: $0.sessionId, content: .autoReply($0)) }
        func byUrgency(_ verdicts: [LedgerVerdict]) -> [LedgerSession] {
            state.sessions.filter { $0.stream == nil && verdicts.contains($0.verdict) }.sorted { a, b in
                let (ra, rb) = (verdicts.firstIndex(of: a.verdict) ?? 0, verdicts.firstIndex(of: b.verdict) ?? 0)
                return ra != rb ? ra < rb : a.lastAt != b.lastAt ? a.lastAt > b.lastAt : a.id < b.id
            }
        }
        inbox.items += byUrgency([.confirm, .expirable]).map { Item(id: "t:" + $0.id, group: .tidy, sessionId: $0.id, content: .session) }
        inbox.items += byUrgency([.pendingMerge, .stale]).map { Item(id: "d:" + $0.id, group: .decide, sessionId: $0.id, content: .session) }
        return inbox
    }
}

/// What undoes a person's operation, worked out from the session as it was before (Windows: entities/ledger/lib/undo.ts)
enum LedgerUndo {
    /// nil when the operation cannot be undone: answers, dismissals, messages and links are delivered as they are.
    /// The core only snoozes into the future, so Still active is undone only by putting back a snooze that still runs
    /// at `now`; without one there is nothing to restore.
    static func inverse(of action: LedgerHumanAction, before s: LedgerSession, now: LedgerMs) -> [LedgerHumanAction]? {
        switch action {
        case .ack: return s.ackAt == nil ? [.unack] : []
        case .unack: return s.ackAt != nil ? [.ack] : []
        case .archive: return s.archivedAt == nil ? [.unarchive] : []
        case .unarchive: return s.archivedAt != nil ? [.archive] : []
        case .stillActive, .snooze:
            guard let until = s.snoozeUntil, until > now else { return nil }
            return [.snooze(until: until)]
        case .setStatus, .shelve:
            // the status first (it may confirm or clear), then confirmation and archive as they were
            var steps: [LedgerHumanAction] = [.setStatus(s.status, version: s.status == .merged ? s.mergedInto : nil)]
            steps.append(s.ackAt == nil ? .unack : .ack)
            if s.archivedAt != nil { steps.append(.archive) }
            return steps
        case .autoContinue: return [.autoContinue(s.autoContinue)]
        case .answer, .dismiss, .link, .message: return nil
        }
    }
}

/// Which project the open repository is (Windows: entities/ledger/lib/filter.ts projectForRepository)
enum LedgerProjects {
    /// The project its sessions are linked to, else a project named like the repository's folder
    static func key(forRepository path: String?, sessions: [LedgerSession], projects: [LedgerProject]) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let target = normalized(path)
        if let linked = sessions.first(where: { $0.links.repoPath.map(normalized) == target }) { return linked.project }
        let folder = (target as NSString).lastPathComponent
        return projects.first { $0.key.caseInsensitiveCompare(folder) == .orderedSame || $0.name.caseInsensitiveCompare(folder) == .orderedSame }?.key
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// How many of the project's baselines are newer than where the session is now
    static func behind(_ s: LedgerSession, baselines: [LedgerBaseline]) -> Int {
        if let behind = s.behind { return behind }
        guard let current = s.baseCurrent ?? s.baseVersion else { return 0 }
        let key = versionKey(current)
        return baselines.filter { $0.project == s.project && key.lexicographicallyPrecedes(versionKey($0.version)) }.count
    }

    /// The newest baseline of a project: the default for "Mark merged"
    static func head(_ project: String, baselines: [LedgerBaseline]) -> String? {
        baselines.filter { $0.project == project }.max { versionKey($0.version).lexicographicallyPrecedes(versionKey($1.version)) }?.version
    }

    /// Versions compare as numbers: v1.10.0 is newer than v1.9.2
    static func versionKey(_ version: String) -> [Int] { version.split { !$0.isNumber }.compactMap { Int($0) } }
}
