import Foundation

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum AppLanguage { static let englishName = "English" }
enum AIError: LocalizedError {
    case notConfigured(String)
    var errorDescription: String? { if case .notConfigured(let text) = self { return text }; return nil }
}
enum AIProvider: String { case test, compatible }
enum AIFeature { case commit, explain }
enum InstructionKey { case global, commit, explain }

@MainActor final class AIStore {
    static let shared = AIStore()
    var selected = AIProvider.test
    var selectedModel = "fixture-model"
    var baseURL = "http://localhost:1234/v1"
    var issue: String?
    var response = "Draft summary\n\nDraft body"
    var writes: [(AIFeature, String, String)] = []
    var onWrite: (() async -> Void)?
    func provider(for feature: AIFeature) -> AIProvider { selected }
    func model(_ provider: AIProvider) -> String { selectedModel }
    func instruction(_ key: InstructionKey) -> String { "fixture instructions" }
    func problem(_ provider: AIProvider) -> String? { issue }
    func write(_ feature: AIFeature, base: String, prompt: String, effort: String) async throws -> String {
        writes.append((feature, base, prompt))
        await onWrite?()
        return response
    }
    func reset() { selected = .test; selectedModel = "fixture-model"; issue = nil; response = "Draft summary\n\nDraft body"; writes = []; onWrite = nil }
}

struct GitResult { let output: String }
@MainActor enum Git {
    static var calls: [[String]] = []
    static var head = "abc"
    static var diff = "diff --git a/a.swift b/a.swift\n-old\n+new"
    static func run(_ args: [String], in repository: URL) async throws -> GitResult {
        precondition(repository.path == "/fixture/repository", "Only fixture reads are allowed")
        calls.append(args)
        switch args.first {
        case "rev-parse": return GitResult(output: head)
        case "diff": return GitResult(output: diff)
        case "log": return GitResult(output: "Core: Improve fixture")
        default: fatalError("Voice routing must never stage, commit, push or execute commands")
        }
    }
    static func reset() { calls = []; head = "abc"; diff = "diff --git a/a.swift b/a.swift\n-old\n+new" }
}
struct CommitReviewStamp: Equatable { let stamp: String; let headSha: String }
@MainActor enum Gitch {
    static var stamps = ["stable"]
    static var count = 0
    static func commitReviewStamp(in repository: URL) async throws -> CommitReviewStamp {
        let stamp = stamps[min(count, stamps.count - 1)]
        count += 1
        return CommitReviewStamp(stamp: stamp, headSha: Git.head)
    }
    static func reset() { stamps = ["stable"]; count = 0 }
}

enum AgentKind: CaseIterable { case claude, codex, gemini }
@MainActor final class AgentCenter {
    enum Place { case app, terminal }
    struct Call { let kind: AgentKind; let path: String; let task: String; let mode: String?; let place: Place? }
    static let shared = AgentCenter()
    var calls: [Call] = []
    var defaultPlace = Place.terminal
    func start(_ kind: AgentKind, in path: String, task: String, permissionMode: String? = nil, host: RepoStore? = nil, place: Place? = nil) throws {
        precondition(host != nil, "Voice agents have an in-app repository host")
        calls.append(Call(kind: kind, path: path, task: task, mode: permissionMode, place: place))
    }
}

@MainActor final class TerminalSession {
    let id = UUID()
    var running = true
    var directory = "/fixture/repository"
    var inserted: [String] = []
    var focused = false
    func insertText(_ text: String) { inserted.append(text) }
    func focus() { focused = true }
}
struct FixtureStatus { var staged = ["a.swift"] }
enum FixtureDestination { case home, repository }
enum FixtureSelection { case wip, other }
struct ChangeQuestionSnapshot { let head: String }
@MainActor final class ChangeQuestionSession {
    static var currentConfiguration: String { AIStore.shared.selected.rawValue + "|" + AIStore.shared.selectedModel }
    var snapshot: ChangeQuestionSnapshot?
    var loading = false
    var working = false
    var active = true
    var error: String?
    var question = ""
    func stop() { working = false }
}
@MainActor final class RepoStore {
    let id = UUID()
    var url: URL? = URL(fileURLWithPath: "/fixture/repository")
    var name = "repository"
    var headHash: String? = "abc"
    var headBranch: String? = "main"
    var status = FixtureStatus()
    var terminals = [TerminalSession()]
    var activeTerminalID: UUID?
    var terminalVoiceActionID: UUID?
    var diffSource: String? = "staged"
    var selection: FixtureSelection? = .wip
    var summary = "Existing summary"
    var message = "Existing body"
    var amend = false
    var aiWorking: String?
    var aiNotice: String?
    var destination = FixtureDestination.home
    var changeQuestionSession: ChangeQuestionSession?
    var openedQuestions = 0
    var sentQuestions = 0
    var presentedQuestions = 0
    var onSnapshot: (() async -> Void)?
    init() { activeTerminalID = terminals[0].id }
    func openChangeQuestion(refresh: Bool = false, present: Bool = true) async {
        openedQuestions += 1
        if present { presentedQuestions += 1 }
        let session = ChangeQuestionSession()
        session.snapshot = ChangeQuestionSnapshot(head: Git.head)
        changeQuestionSession = session
        await onSnapshot?()
    }
    func sendChangeQuestion() { sentQuestions += 1; changeQuestionSession?.working = true }
    func select(_ selection: FixtureSelection) { self.selection = selection }
}

@main struct TerminalVoiceActionTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func reset() { AIStore.shared.reset(); Git.reset(); Gitch.reset(); AgentCenter.shared.calls = [] }
        func capture(_ store: RepoStore) -> TerminalVoiceContext { store.terminalVoiceContext(for: store.terminals[0])! }
        func request(_ store: RepoStore, _ context: TerminalVoiceContext, _ destination: TerminalVoiceDestination, _ text: String = "Explain these changes") async throws {
            try await store.performTerminalVoiceAction(destination: destination, text: text, context: context, agentKind: .claude)
        }
        func rejects(_ expected: TerminalVoiceActionError, store: RepoStore, context: TerminalVoiceContext, destination: TerminalVoiceDestination, text: String = "Explain these changes") async {
            do { try await request(store, context, destination, text); preconditionFailure("A stale voice action was accepted") }
            catch let error as TerminalVoiceActionError { check(error == expected, "Wrong voice rejection: \(error)") }
            catch { preconditionFailure("Unexpected rejection: \(error)") }
        }

        reset()
        let terminal = RepoStore(), terminalContext = capture(terminal)
        check(Git.calls.isEmpty && AIStore.shared.writes.isEmpty && AgentCenter.shared.calls.isEmpty, "Opening a composer is inert")
        try await request(terminal, terminalContext, .terminal, "  echo ready\nwhoami\u{1B}[201~  ")
        check(terminal.terminals[0].inserted == ["echo ready whoami [201~"], "Terminal insertion removes controls and Return")
        check(terminal.terminals[0].focused, "Terminal receives focus after insertion")
        check(Git.calls.isEmpty && AIStore.shared.writes.isEmpty && AgentCenter.shared.calls.isEmpty, "Terminal destination never invokes AI or an agent")
        check(terminal.terminalVoiceActionID == nil, "Completed requests release ownership")

        reset()
        let empty = RepoStore(), emptyContext = capture(empty)
        await rejects(.emptyText, store: empty, context: emptyContext, destination: .agent, text: " \n ")
        await rejects(.textTooLong, store: empty, context: emptyContext, destination: .agent, text: String(repeating: "a", count: 6_001))
        check(Git.calls.isEmpty && AgentCenter.shared.calls.isEmpty, "Invalid input has no side effects")

        let moved = RepoStore(), movedContext = capture(moved)
        moved.url = URL(fileURLWithPath: "/fixture/another")
        await rejects(.repositoryChanged, store: moved, context: movedContext, destination: .terminal)
        let stopped = RepoStore(), stoppedContext = capture(stopped)
        stopped.terminals[0].running = false
        await rejects(.terminalUnavailable, store: stopped, context: stoppedContext, destination: .terminal)
        let removed = RepoStore(), removedContext = capture(removed)
        removed.terminals = []
        await rejects(.terminalUnavailable, store: removed, context: removedContext, destination: .terminal)
        let switched = RepoStore(), switchedContext = capture(switched)
        switched.activeTerminalID = UUID()
        await rejects(.terminalUnavailable, store: switched, context: switchedContext, destination: .terminal)
        let folder = RepoStore(), folderContext = capture(folder)
        folder.terminals[0].directory = "/fixture/another"
        await rejects(.directoryChanged, store: folder, context: folderContext, destination: .agent)
        let branch = RepoStore(), branchContext = capture(branch)
        branch.headHash = "other"
        await rejects(.headChanged, store: branch, context: branchContext, destination: .commitDraft)
        let provider = RepoStore(), providerContext = capture(provider)
        AIStore.shared.selectedModel = "changed"
        await rejects(.settingsChanged, store: provider, context: providerContext, destination: .explainChanges)
        reset()
        let selection = RepoStore(), selectionContext = capture(selection)
        selection.diffSource = "another file"
        await rejects(.selectionChanged, store: selection, context: selectionContext, destination: .explainChanges)
        let changedHead = RepoStore(), changedHeadContext = capture(changedHead)
        Git.head = "changed-on-disk"
        await rejects(.headChanged, store: changedHead, context: changedHeadContext, destination: .agent)
        check(AgentCenter.shared.calls.isEmpty, "An on-disk HEAD change cannot start an agent")

        reset()
        let explain = RepoStore(), explainContext = capture(explain)
        try await request(explain, explainContext, .explainChanges, "Why did this change?\nMention risks.")
        check(explain.openedQuestions == 1 && explain.sentQuestions == 1, "Confirmed question really dispatches the existing Q&A workflow")
        check(explain.presentedQuestions == 0, "Routing does not present a second sheet over the composer")
        check(explain.changeQuestionSession?.question == "Why did this change?\nMention risks.", "AI destinations retain reviewed paragraphs")
        check(explain.changeQuestionSession?.working == true, "Existing Q&A owns answer progress")

        reset()
        let unconfigured = RepoStore(), unconfiguredContext = capture(unconfigured)
        AIStore.shared.issue = "Choose a configured provider"
        do { try await request(unconfigured, unconfiguredContext, .explainChanges); preconditionFailure("Unconfigured provider was called") }
        catch is AIError { checks += 1 }
        check(unconfigured.openedQuestions == 0 && unconfigured.sentQuestions == 0, "Missing provider does not replace a question draft")
        reset()
        let duplicate = RepoStore(), duplicateContext = capture(duplicate)
        let runningToken = UUID(); duplicate.terminalVoiceActionID = runningToken
        await rejects(.busy, store: duplicate, context: duplicateContext, destination: .terminal)
        check(duplicate.terminalVoiceActionID == runningToken && duplicate.terminals[0].inserted.isEmpty, "A duplicate Send cannot replace a running request")

        reset()
        let cancelledQuestion = RepoStore(), cancelledContext = capture(cancelledQuestion)
        let prior = ChangeQuestionSession(); prior.question = "Keep this draft"
        cancelledQuestion.changeQuestionSession = prior
        cancelledQuestion.onSnapshot = { cancelledQuestion.cancelTerminalVoiceAction() }
        do { try await request(cancelledQuestion, cancelledContext, .explainChanges); preconditionFailure("Cancelled question dispatched") }
        catch is CancellationError { checks += 1 }
        check(cancelledQuestion.sentQuestions == 0 && cancelledQuestion.changeQuestionSession === prior, "Cancellation restores the previous question draft")

        reset()
        let draft = RepoStore(), draftContext = capture(draft)
        try await request(draft, draftContext, .commitDraft, "Emphasize the cache invalidation fix")
        check(draft.summary == "Draft summary" && draft.message == "Draft body", "Commit destination creates a message draft")
        check(draft.destination == .repository && draft.selection == .wip, "Commit draft reveals the existing review area")
        check(AIStore.shared.writes.count == 1 && AIStore.shared.writes[0].2.contains("Emphasize the cache invalidation fix"), "Voice guidance reaches the selected commit provider")
        check(AIStore.shared.writes[0].1.contains("Do not run commands, stage files, commit or push"), "Commit generation remains text-only")
        check(draft.aiWorking == nil && draft.terminalVoiceActionID == nil, "Draft completion releases busy state")
        check(Git.calls.allSatisfy { ["rev-parse", "diff", "log"].contains($0.first ?? "") }, "No routing path stages, commits or pushes")

        reset()
        let edited = RepoStore(), editedContext = capture(edited)
        AIStore.shared.onWrite = { edited.summary = "User edits during request" }
        await rejects(.draftChanged, store: edited, context: editedContext, destination: .commitDraft)
        check(edited.summary == "User edits during request" && edited.message == "Existing body", "Draft generation preserves concurrent user edits")
        reset()
        let staged = RepoStore(), stagedContext = capture(staged)
        Gitch.stamps = ["before", "before", "after"]
        await rejects(.stagedChanged, store: staged, context: stagedContext, destination: .commitDraft)
        check(staged.summary == "Existing summary", "Changed staging cannot overwrite the draft")
        reset()
        let changedBeforeSend = RepoStore(), changedBeforeContext = capture(changedBeforeSend)
        Gitch.stamps = ["before", "after"]
        await rejects(.stagedChanged, store: changedBeforeSend, context: changedBeforeContext, destination: .commitDraft)
        check(AIStore.shared.writes.isEmpty, "A moving staged snapshot cannot be sent to AI")
        reset()
        let emptyDraft = RepoStore(), emptyDraftContext = capture(emptyDraft)
        AIStore.shared.response = "  "
        await rejects(.emptyDraft, store: emptyDraft, context: emptyDraftContext, destination: .commitDraft)
        check(emptyDraft.summary == "Existing summary" && emptyDraft.message == "Existing body", "An empty provider result preserves the user's draft")
        reset()
        let config = RepoStore(), configContext = capture(config)
        AIStore.shared.onWrite = { AIStore.shared.selectedModel = "replacement" }
        await rejects(.settingsChanged, store: config, context: configContext, destination: .commitDraft)
        check(config.summary == "Existing summary", "Changed AI configuration cannot apply an old result")
        reset()
        let cancelled = RepoStore(), cancelledDraftContext = capture(cancelled)
        AIStore.shared.onWrite = { cancelled.cancelTerminalVoiceAction() }
        do { try await request(cancelled, cancelledDraftContext, .commitDraft); preconditionFailure("Cancelled result applied") }
        catch is CancellationError { checks += 1 }
        check(cancelled.summary == "Existing summary" && cancelled.aiWorking == nil, "Cancelled results cannot overwrite or leave busy state")
        reset()
        let replacement = RepoStore(), replacementContext = capture(replacement)
        let replacementToken = UUID()
        AIStore.shared.onWrite = {
            replacement.cancelTerminalVoiceAction()
            replacement.terminalVoiceActionID = replacementToken
            replacement.aiWorking = "New workflow owns this state"
        }
        do { try await request(replacement, replacementContext, .commitDraft); preconditionFailure("Replaced result applied") }
        catch is CancellationError { checks += 1 }
        check(replacement.terminalVoiceActionID == replacementToken && replacement.aiWorking == "New workflow owns this state", "An old completion cannot clear a newer workflow's busy state")
        reset()
        let missing = RepoStore(), missingContext = capture(missing)
        Git.diff = ""
        do { try await request(missing, missingContext, .commitDraft); preconditionFailure("An empty staged diff was sent") }
        catch is AIError { checks += 1 }
        check(AIStore.shared.writes.isEmpty && missing.summary == "Existing summary", "No staged changes means no AI call or draft overwrite")

        for kind in AgentKind.allCases {
            reset()
            let agent = RepoStore(), context = capture(agent)
            try await agent.performTerminalVoiceAction(destination: .agent, text: "Investigate the test failure", context: context, agentKind: kind)
            let call = AgentCenter.shared.calls[0]
            check(call.kind == kind && call.place == .app && AgentCenter.shared.defaultPlace == .terminal, "Voice destination forces app without changing the global external preference")
            check(call.path == context.directory && call.task == "Investigate the test failure", "Agent uses the reviewed repository folder and task")
            let expected = kind == .claude ? "default" : kind == .codex ? "read-only" : "plan"
            check(call.mode == expected, "Voice starts with explicit permission checks or read-only mode")
        }
        print("Terminal voice routing: \(checks) checks passed without AI, agent processes, staging or commits")
    }
}
