import Foundation
import Observation

/// The Ledger's views, listed in its filter column
enum LedgerPage: String, CaseIterable, Identifiable {
    case inbox, board, graph, streams
    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return String(localized: "Inbox")
        case .board: return String(localized: "Board")
        case .graph: return String(localized: "Graph")
        case .streams: return String(localized: "Streams")
        }
    }

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .board: return "list.bullet.rectangle"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .streams: return "arrow.triangle.2.circlepath"
        }
    }
}

/// A short note after an operation, with Undo while it can still be undone
struct LedgerToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let canUndo: Bool
}

/// One per app: the ledger as the screens show it. Reads `rev` every 2 seconds and the state only when it moved; a
/// person's operations go to the backend and come back through the same reads. Decoding, Inbox grouping, the Board's
/// filter and the graph's rows are worked out off the main thread. (Windows: entities/ledger/model/store.ts)
@MainActor @Observable
final class LedgerStore {
    static let shared = LedgerStore(client: LedgerClient(backend: LedgerStore.makeBackend()))

    /// The demo until the core is connected (wave 2); GITROCHI_LEDGER_DEMO=large or =empty picks another demo
    nonisolated static func makeBackend() -> LedgerBackend {
        DemoLedgerBackend(mode: DemoLedgerBackend.Mode(rawValue: ProcessInfo.processInfo.environment["GITROCHI_LEDGER_DEMO"] ?? "") ?? .standard)
    }

    nonisolated static func localNow() -> LedgerMs { LedgerMs((Date().timeIntervalSince1970 * 1000).rounded()) }

    let client: LedgerClient
    private let defaults: UserDefaults
    private let interval: Duration

    private(set) var state: LedgerState?
    private(set) var inbox = LedgerInbox()
    /// The Board's rows for the current filter
    private(set) var boardRows: [LedgerSession] = []
    private(set) var verdictCounts: [LedgerVerdict: Int] = [:]
    /// The selected session's whole record
    private(set) var detail: LedgerSessionDetail?
    private(set) var graph: LedgerGraph?
    private(set) var plot = LedgerGraphPlot()
    private(set) var loadError: String?
    var actionError: String?
    private(set) var toast: LedgerToast?
    /// Sessions, questions ("q…") and prompts ("p…") with an operation on the way
    private(set) var working: Set<String> = []
    /// The backend's clock minus this Mac's, so countdowns can tick between reads
    private(set) var clockSkew: LedgerMs = 0

    var page: LedgerPage = .inbox {
        didSet { if page == .graph, oldValue != .graph { Task { await loadGraph() } } }
    }
    /// The period of the graph and of finished work in the lists; remembered
    private(set) var range: LedgerRange
    /// The project shown; nil shows every project
    private(set) var project: String?
    /// Set when the person picked the project; until then the page follows the open repository
    private(set) var projectChosen = false
    private(set) var repositoryPath: String?
    /// The project the graph draws when every project is shown
    private(set) var graphProjectChoice: String?
    var selection: String? {
        didSet {
            guard selection != oldValue else { return }
            if detail?.session.id != selection { detail = nil }
            highlightedEvent = nil
            if let selection { Task { await loadDetail(selection) } }
        }
    }
    /// An event to bring into view in the inspector (a search result)
    var highlightedEvent: Int?
    var filter = LedgerSessionFilter() {
        didSet { if filter != oldValue { Task { await refilter() } } }
    }
    /// Sessions picked for a bulk operation on the Board
    var boardSelection: Set<String> = []
    /// Answers being written, per question; kept when saving fails
    var drafts: [Int: String] = [:]
    /// Older graph rows are drawn on request
    private(set) var graphLimit = 1_500

    private struct UndoEntry {
        let message: String
        let steps: [(session: String, actions: [LedgerHumanAction])]
    }
    private var undoStack: [UndoEntry] = []
    private var polling: Task<Void, Never>?
    private var lastRev = -1
    private var generation = 0

    init(client: LedgerClient, defaults: UserDefaults = .standard, interval: Duration = .seconds(2)) {
        self.client = client
        self.defaults = defaults
        self.interval = interval
        range = defaults.string(forKey: "ledgerRange").flatMap(LedgerRange.init(rawValue:)) ?? .week
    }

    var canUndo: Bool { !undoStack.isEmpty }
    /// What needs a person, as the core counts it: the Inbox's count and the sidebar badge
    var attentionTotal: Int { state?.attention.total ?? 0 }
    var graphProject: String? { project ?? graphProjectChoice ?? state?.projects.first?.key }
    /// Sessions the Board leaves out because they are streams
    var streamCount: Int { state?.sessions.filter { $0.stream != nil }.count ?? 0 }
    var isEmpty: Bool { state.map { $0.sessions.isEmpty && $0.pendingPrompts.isEmpty } ?? false }

    func session(_ id: String?) -> LedgerSession? {
        guard let id else { return nil }
        if let s = state?.sessions.first(where: { $0.id == id }) { return s }
        return detail?.session.id == id ? detail?.session : nil
    }

    // MARK: - Reading

    /// Starts reading every 2 seconds; every view that shows ledger data may call it
    func activate() {
        guard polling == nil else { return }
        let interval = interval
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Reads `rev`, and the rest only when it moved
    func poll() async {
        do {
            let rev = try await client.rev()
            if rev != lastRev || state == nil { await reload() }
        } catch {
            setIfChanged(\.loadError, error.localizedDescription)
        }
    }

    /// Reads the state now, then the open session and the graph
    func reload() async { await load(following: true) }

    private func load(following: Bool) async {
        generation += 1
        let mine = generation
        do {
            let next = try await client.state(project: project, range: range)
            guard mine == generation else { return }
            // the open repository may turn out to be another project: read that one instead (once)
            if following, !projectChosen {
                let key = LedgerProjects.key(forRepository: repositoryPath, sessions: next.sessions, projects: next.projects)
                if key != project {
                    project = key
                    boardSelection = []
                    await load(following: false)
                    return
                }
            }
            let filter = filter
            let (inbox, rows, counts) = await Task.detached(priority: .userInitiated) {
                (LedgerInbox.build(next), filter.apply(next.sessions), LedgerSessionFilter.counts(next.sessions))
            }.value
            guard mine == generation else { return }
            lastRev = next.rev
            setIfChanged(\.state, next)
            setIfChanged(\.inbox, inbox)
            setIfChanged(\.boardRows, rows)
            setIfChanged(\.verdictCounts, counts)
            setIfChanged(\.clockSkew, next.now - Self.localNow())
            setIfChanged(\.loadError, nil)
            let visible = Set(rows.map(\.id))
            if !boardSelection.isSubset(of: visible) { boardSelection.formIntersection(visible) }
            if let selection { await loadDetail(selection) }
            if page == .graph { await loadGraph() }
        } catch {
            guard mine == generation else { return }
            setIfChanged(\.loadError, error.localizedDescription)
        }
    }

    private func refilter() async {
        guard let state else { return }
        let filter = filter
        let rows = await Task.detached(priority: .userInitiated) { filter.apply(state.sessions) }.value
        guard filter == self.filter else { return }
        setIfChanged(\.boardRows, rows)
        let visible = Set(rows.map(\.id))
        if !boardSelection.isSubset(of: visible) { boardSelection.formIntersection(visible) }
    }

    private func loadDetail(_ id: String) async {
        do {
            let next = try await client.session(id)
            guard selection == id else { return }
            setIfChanged(\.detail, next)
        } catch {
            if selection == id { detail = nil }
        }
    }

    func loadGraph() async {
        guard let key = graphProject else {
            setIfChanged(\.graph, nil)
            setIfChanged(\.plot, LedgerGraphPlot())
            return
        }
        do {
            let range = range
            let next = try await client.graph(project: key, range: range)
            guard key == graphProject, range == self.range else { return }
            let open = Set((state?.sessions ?? []).filter { !$0.status.isFinished && $0.status != .shelved && $0.archivedAt == nil }.map(\.id))
            let limit = graphLimit
            let plot = await Task.detached(priority: .userInitiated) { LedgerGraphPlot.plot(next, openSessions: open, limit: limit) }.value
            guard key == graphProject else { return }
            setIfChanged(\.graph, next)
            setIfChanged(\.plot, plot)
        } catch {
            setIfChanged(\.loadError, error.localizedDescription)
        }
    }

    /// Draws older graph rows: the next 1,500, or the next wider period when this one is all drawn
    func showMoreGraph() async {
        if plot.hiddenRows > 0 {
            graphLimit += 1_500
            await loadGraph()
        } else if let wider = range.wider {
            await setRange(wider)
        }
    }

    func setRange(_ value: LedgerRange) async {
        guard value != range else { return }
        range = value
        defaults.set(value.rawValue, forKey: "ledgerRange")
        graphLimit = 1_500
        await reload()
    }

    func chooseGraphProject(_ key: String?) async {
        guard key != graphProjectChoice else { return }
        graphProjectChoice = key
        graphLimit = 1_500
        await loadGraph()
    }

    // MARK: - Project

    /// The page shows the open repository's project, unless the person picked another one
    func follow(repository path: String?) async {
        if path != repositoryPath {
            repositoryPath = path
            projectChosen = false
        }
        if !projectChosen, state != nil { await reload() }
    }

    func choose(project key: String?) async {
        projectChosen = true
        guard key != project else { return }
        project = key
        boardSelection = []
        await reload()
    }

    /// Back to showing the open repository's project
    func resumeFollowing() async {
        projectChosen = false
        await reload()
    }

    /// The repository's project, when the ledger knows one
    var repositoryProject: String? {
        guard let state else { return nil }
        return LedgerProjects.key(forRepository: repositoryPath, sessions: state.sessions, projects: state.projects)
    }

    // MARK: - A person's operations

    /// Sends one operation for each session; confirming, archiving, status changes and snoozing can be undone
    func perform(_ action: LedgerHumanAction, on ids: [String], message: String) async {
        guard !ids.isEmpty else { return }
        let before = Dictionary(ids.compactMap { id in session(id).map { (id, $0) } }) { first, _ in first }
        let now = Self.localNow() + clockSkew
        working.formUnion(ids)
        defer { working.subtract(ids) }
        var steps: [(session: String, actions: [LedgerHumanAction])] = []
        var undoable = true
        for id in ids {
            do {
                _ = try await client.human(action, sessionId: id)
                if let s = before[id], let inverse = LedgerUndo.inverse(of: action, before: s, now: now) {
                    steps.append((id, inverse))
                } else {
                    undoable = false
                }
            } catch {
                actionError = error.localizedDescription
                break
            }
        }
        if undoable, !steps.isEmpty {
            undoStack.append(UndoEntry(message: message, steps: steps))
            if undoStack.count > 30 { undoStack.removeFirst() }
        }
        if !steps.isEmpty || !undoable { toast = LedgerToast(message: message, canUndo: undoable && !steps.isEmpty) }
        await reload()
    }

    /// Undoes the last operation that can be undone
    func undo() async {
        guard let entry = undoStack.popLast() else { return }
        working.formUnion(entry.steps.map(\.session))
        defer { working.subtract(entry.steps.map(\.session)) }
        do {
            for step in entry.steps {
                for action in step.actions { _ = try await client.human(action, sessionId: step.session) }
            }
            toast = LedgerToast(message: String(localized: "Undone: \(entry.message)"), canUndo: false)
        } catch {
            actionError = error.localizedDescription
        }
        await reload()
    }

    func dismissToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }

    /// A note without Undo, after something that is not an operation on a session
    func showNotice(_ message: String) {
        toast = LedgerToast(message: message, canUndo: false)
    }

    /// Saves the written answer; the session receives it with its next report. The draft stays when saving fails.
    @discardableResult
    func answer(_ question: LedgerQuestion) async -> Bool {
        let text = (drafts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working.contains("q\(question.id)") else { return false }
        working.insert("q\(question.id)")
        defer { working.remove("q\(question.id)") }
        do {
            _ = try await client.human(.answer(questionId: question.id, text: text), sessionId: question.sessionId)
            drafts[question.id] = nil
            toast = LedgerToast(message: String(localized: "Answer saved. The session receives it with its next report."), canUndo: false)
            await reload()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func dismiss(_ question: LedgerQuestion) async {
        working.insert("q\(question.id)")
        defer { working.remove("q\(question.id)") }
        do {
            _ = try await client.human(.dismiss(questionId: question.id), sessionId: question.sessionId)
            drafts[question.id] = nil
            toast = LedgerToast(message: String(localized: "Question dismissed"), canUndo: false)
        } catch {
            actionError = error.localizedDescription
        }
        await reload()
    }

    /// A person's answer to a prompt an agent is waiting on
    func reply(_ prompt: LedgerPendingPrompt, _ reply: LedgerPromptReply) async {
        let key = "p\(prompt.id)"
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        do {
            guard try await client.answerPrompt(prompt.id, reply).ok else {
                actionError = String(localized: "The agent stopped waiting: the prompt was answered or released elsewhere.")
                await reload()
                return
            }
            let message: String
            switch reply {
            case .answerInTerminal: message = String(localized: "Left to the terminal")
            case .holdAuto: message = String(localized: "Auto-continue is off for this prompt")
            case .allow: message = String(localized: "Allowed")
            case .deny: message = String(localized: "Denied")
            case .text, .choices: message = String(localized: "Answer sent to the agent")
            }
            toast = LedgerToast(message: message, canUndo: false)
        } catch {
            actionError = error.localizedDescription
        }
        await reload()
    }

    /// Marks what auto-continue sent as seen; a correction goes to the session as a message first
    func review(_ prompt: LedgerPendingPrompt, correction: String? = nil) async {
        let key = "p\(prompt.id)"
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        let text = correction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if !text.isEmpty {
                guard let session = prompt.sessionId else { return }
                _ = try await client.human(.message(text: text), sessionId: session)
            }
            _ = try await client.reviewPrompt(prompt.id)
            toast = LedgerToast(message: text.isEmpty ? String(localized: "Reviewed")
                                                      : String(localized: "Correction sent. The session receives it with its next report."), canUndo: false)
        } catch {
            actionError = error.localizedDescription
        }
        await reload()
    }

    // MARK: - Search, import, connection

    /// Sessions, questions, reports and versions for quick navigation
    func search(_ query: String, limit: Int = 20) async -> [LedgerSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        return (try? await client.search(trimmed, project: nil, limit: limit)) ?? []
    }

    /// Opens a search result: its session, and the event or question in the inspector
    func open(_ hit: LedgerSearchHit) {
        if let id = hit.sessionId { selection = id }
        if hit.kind == .event, let event = Int(hit.id.dropFirst()) { highlightedEvent = event }
        if hit.kind == .question { page = .inbox } else if page == .inbox, hit.kind == .session { page = .board }
    }

    func importReports(_ text: String) async throws -> [LedgerImportResult.Block] {
        let results = try await client.importReports(text, project: project)
        await reload()
        return results
    }

    func info() async throws -> LedgerInfo { try await client.info() }
    func backup() async throws -> String { try await client.backup() }

    /// Writes only a changed value, so views that read it do not draw again for nothing
    private func setIfChanged<Value: Equatable>(_ path: ReferenceWritableKeyPath<LedgerStore, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}
