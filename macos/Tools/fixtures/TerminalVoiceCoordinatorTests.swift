import AppKit
import Foundation
import Observation

enum AppLanguage { static let key = "appLanguage" }
enum AgentKind { case claude, codex, gemini }
enum AIError: LocalizedError {
    case notConfigured(String)
    var errorDescription: String? { if case .notConfigured(let value) = self { return value }; return nil }
}

/// Key-window status is deterministic; these windows are never ordered onto the desktop.
final class CoordinatorFixtureWindow: NSWindow {
    var fixtureKey = true
    var fixtureParent: NSWindow?
    var fixtureSheet: NSWindow?
    override var isKeyWindow: Bool { fixtureKey }
    override var attachedSheet: NSWindow? { fixtureSheet }
    override var sheetParent: NSWindow? { fixtureParent }
    convenience init() {
        self.init(contentRect: NSRect(x: -5000, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
}

@MainActor final class CoordinatorFixtureGate {
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
    }
    func finish() {
        guard let continuation else { preconditionFailure("A fixture gate must be awaiting completion") }
        self.continuation = nil
        continuation.resume()
    }
}

/// This boundary records requests, without permissions, audio devices or speech services.
@MainActor @Observable final class TerminalDictation {
    var transcript = ""
    var isBusy = false
    var needsPermissionSetup = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancels = 0
    private(set) var lastLocale = ""
    private(set) var lastHints: [String] = []
    func start(localeIdentifier: String, contextualStrings: [String] = []) {
        starts += 1; isBusy = true
        lastLocale = localeIdentifier; lastHints = contextualStrings
    }
    func stop() { stops += 1; isBusy = false }
    func cancel() { cancels += 1; isBusy = false; transcript = "" }
}

struct CoordinatorFixtureChange { let path: String }
struct CoordinatorFixtureBranch { let name: String }
struct CoordinatorFixtureStatus {
    var staged = [CoordinatorFixtureChange(path: "src/Changed.swift")]
    var unstaged: [CoordinatorFixtureChange] = []
}
enum CoordinatorFixtureSheet { case changeQuestion, other }
@MainActor final class ChangeQuestionSession {
    let repository: URL
    var active = true
    init(repository: URL) { self.repository = repository }
}
@MainActor final class TerminalSession {
    let id = UUID()
    var running = true
    var directory = "/fixture/repository"
    var title = "Fixture terminal"
}
struct CoordinatorFixtureGitResult { let data: Data }
@MainActor enum Git {
    static var reads = 0
    static func run(_ arguments: [String], in repository: URL) async throws -> CoordinatorFixtureGitResult {
        precondition(arguments == ["ls-files", "-z"], "The coordinator only reads local path hints")
        reads += 1
        return CoordinatorFixtureGitResult(data: Data("src/Routes.swift\0.env\0".utf8))
    }
}

/// The production coordinator talks to these inert repository actions, never AI or agent processes.
@MainActor final class RepoStore {
    let id = UUID()
    var name = "Fixture repository"
    var url: URL? = URL(fileURLWithPath: "/fixture/repository")
    let fixtureWindow = CoordinatorFixtureWindow()
    var window: NSWindow? { fixtureWindow }
    var isActive = true
    var sheet: CoordinatorFixtureSheet?
    var status = CoordinatorFixtureStatus()
    var localBranches = [CoordinatorFixtureBranch(name: "feature/voice-context")]
    var head = "abc"
    var terminals: [TerminalSession] = []
    var activeTerminalID: UUID?
    var showTerminal = false
    var changeQuestionSession: ChangeQuestionSession?
    var actionCalls: [(TerminalVoiceDestination, String)] = []
    var cancelCalls = 0
    var newTerminalCalls = 0
    var reloadCalls = 0
    var reloadHead: String?
    var action: (() async throws -> Void)?
    var reloadAction: (() async -> Void)?
    var activeTerminal: TerminalSession? { terminals.first { $0.id == activeTerminalID } ?? terminals.last }
    @discardableResult func newTerminal() -> TerminalSession? {
        newTerminalCalls += 1
        let session = TerminalSession(); terminals.append(session); activeTerminalID = session.id
        return session
    }
    func selectTerminal(_ terminal: TerminalSession) { activeTerminalID = terminal.id }
    func terminalVoiceContext(for terminal: TerminalSession) -> TerminalVoiceContext? {
        guard let url, terminals.contains(where: { $0.id == terminal.id }), terminal.running else { return nil }
        return TerminalVoiceContext(repositoryURL: url, sessionID: terminal.id, directory: terminal.directory, head: head,
            repositoryName: name, storeID: id, explainConfiguration: "fixture-explain", commitConfiguration: "fixture-commit",
            selectionSignature: "fixture-staged", hasStagedChanges: !status.staged.isEmpty)
    }
    func cancelTerminalVoiceAction() { cancelCalls += 1 }
    func performTerminalVoiceAction(destination: TerminalVoiceDestination, text: String, context: TerminalVoiceContext, agentKind: AgentKind) async throws {
        actionCalls.append((destination, text))
        if let action { try await action() }
        if destination == .explainChanges { changeQuestionSession = ChangeQuestionSession(repository: context.repositoryURL) }
    }
    func reload(quiet: Bool) async {
        precondition(quiet, "Context refresh must not disrupt the repository UI")
        reloadCalls += 1
        await reloadAction?()
        if let reloadHead { head = reloadHead }
    }
}

@main struct TerminalVoiceCoordinatorTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func environment() -> (RepoStore, TerminalVoiceCoordinator) {
            let store = RepoStore(), voice = TerminalVoiceCoordinator()
            voice.attach(to: store)
            return (store, voice)
        }
        func settle() async {
            for _ in 0..<4 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(3))
        }
        func awaitGate(_ gate: CoordinatorFixtureGate) async {
            for _ in 0..<100 {
                if gate.waiting { return }
                await Task.yield()
            }
            preconditionFailure("The production coordinator did not reach the fixture boundary")
        }
        func cancelled(_ task: Task<Void, Error>) async {
            do { try await task.value; preconditionFailure("An obsolete coordinator action completed") }
            catch is CancellationError { checks += 1 }
            catch { preconditionFailure("Unexpected coordinator error: \(error)") }
        }
        func foreignKey(_ store: RepoStore, _ foreign: CoordinatorFixtureWindow) {
            store.fixtureWindow.fixtureKey = false
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: foreign)
        }

        let (hiddenStore, hidden) = environment()
        check(!hiddenStore.showTerminal && hiddenStore.terminals.isEmpty, "The fixture begins without a visible terminal")
        hidden.open()
        check(hidden.presented && hiddenStore.showTerminal && hiddenStore.newTerminalCalls == 1, "Voice opens and creates its target when the terminal is hidden")
        check(hidden.context?.sessionID == hiddenStore.activeTerminalID && hidden.context?.repositoryURL == hiddenStore.url, "The context belongs to the selected terminal and repository")
        check(hiddenStore.actionCalls.isEmpty && hidden.dictation.starts == 0, "Opening never records or dispatches work")
        await settle()
        check(hidden.paths == ["src/Routes.swift", ".env"], "Only synthetic local path names are loaded")
        check(hidden.vocabulary.contains("FixtureTerm") && hidden.vocabulary.contains("Routes.swift") && !hidden.vocabulary.contains(".env"), "Explicit words and non-private repository terms reach recognition")
        hidden.startListening()
        check(hidden.dictation.lastLocale == "ko-KR" && hidden.dictation.lastLocale == hidden.localeIdentifier, "Automatic/manual opening shares the saved Korean locale resolver")
        check(hidden.dictation.lastHints == hidden.vocabulary, "Listening receives the same bounded hints shown for this repository")
        hidden.dismiss()
        check(!hidden.presented && hidden.context == nil && !hidden.dictation.isBusy, "Dismissal clears capture and target ownership")
        hiddenStore.terminals[0].running = false
        hidden.open()
        check(hidden.presented && hiddenStore.newTerminalCalls == 2 && hidden.context?.sessionID != hiddenStore.terminals[0].id, "A stopped terminal is replaced with a running target")
        hidden.detach()

        let (sheetStore, blocked) = environment()
        sheetStore.sheet = .other; blocked.open()
        check(!blocked.presented && sheetStore.newTerminalCalls == 0, "Other sheets block voice opening without side effects")
        blocked.detach()

        let (raceStore, race) = environment()
        race.open(); race.dictation.transcript = "Old reviewed request"
        let oldGate = CoordinatorFixtureGate()
        raceStore.action = { try await oldGate.wait() }
        let old = Task { try await race.perform(.commitDraft, text: "Old request", agentKind: .claude) }
        await awaitGate(oldGate)
        check(race.performing, "An in-flight action owns the coordinator busy flag")
        race.dismiss(); race.open(); race.dictation.transcript = "A new draft must survive"
        let currentContext = race.context
        let newGate = CoordinatorFixtureGate()
        raceStore.action = { try await newGate.wait() }
        let newer = Task { try await race.perform(.commitDraft, text: "New request", agentKind: .codex) }
        await awaitGate(newGate)
        oldGate.finish(); await cancelled(old)
        check(race.presented && race.performing && race.context == currentContext, "Old completion cannot close the new presentation or clear its busy flag")
        check(race.dictation.transcript == "A new draft must survive", "Old completion cannot wipe a new draft")
        newGate.finish(); try await newer.value
        check(!race.presented && !race.performing && race.context == nil, "The current operation closes only its own presentation")
        race.detach()

        let (captureStore, capture) = environment()
        capture.open(); capture.startListening(); capture.dictation.transcript = "Partial capture"
        let foreign = CoordinatorFixtureWindow()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: captureStore.fixtureWindow)
        check(capture.dictation.isBusy, "The owning window does not cancel its capture")
        let attached = CoordinatorFixtureWindow(); attached.fixtureParent = captureStore.fixtureWindow
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: attached)
        check(capture.dictation.isBusy, "The attached voice sheet does not cancel its capture")
        foreignKey(captureStore, foreign)
        check(!capture.dictation.isBusy && capture.dictation.transcript.isEmpty && capture.presented, "A different window cancels manual capture but retains the voice workspace")
        capture.dictation.transcript = "Reviewed draft stays local"
        let beforeCancelCount = capture.dictation.cancels
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: foreign)
        check(capture.dictation.transcript == "Reviewed draft stays local" && capture.dictation.cancels == beforeCancelCount, "Changing windows does not erase a reviewed draft")
        captureStore.fixtureWindow.fixtureKey = true
        let backgroundGate = CoordinatorFixtureGate()
        captureStore.action = { try await backgroundGate.wait() }
        let background = Task { try await capture.perform(.commitDraft, text: "Reviewed draft stays local", agentKind: .claude) }
        await awaitGate(backgroundGate)
        foreignKey(captureStore, foreign)
        check(!capture.performing && captureStore.cancelCalls > 0, "Losing the window invalidates in-flight work")
        backgroundGate.finish(); await cancelled(background)
        check(capture.presented && capture.dictation.transcript == "Reviewed draft stays local", "Late background completion preserves the reviewed text")
        capture.detach()

        // a page's own sheet (not `store.sheet`) is over the window: voice waits for it instead of queueing behind it
        let (coveredStore, covered) = environment()
        coveredStore.fixtureWindow.fixtureSheet = CoordinatorFixtureWindow()
        covered.open()
        check(!covered.presented && !covered.dictation.isBusy && covered.context == nil, "Voice does not open under another sheet")
        coveredStore.fixtureWindow.fixtureSheet = nil
        covered.open()
        check(covered.presented, "Voice opens once the other sheet has closed")
        // while it is open, the window's sheet is the voice sheet itself
        coveredStore.fixtureWindow.fixtureSheet = CoordinatorFixtureWindow()
        covered.startListening()
        check(covered.dictation.isBusy, "The voice sheet does not block its own capture")
        covered.detach()

        for competition in ["none", "newVoice", "otherSheet", "newQuestion", "newRepository", "inactiveWindow", "dismissed"] {
            let (store, voice) = environment()
            voice.open(); voice.dictation.transcript = "Explain this diff"
            try await voice.perform(.explainChanges, text: "Explain this diff", agentKind: .claude)
            check(!voice.presented && store.sheet == nil, "A completed question waits for actual voice-sheet dismissal")
            let originalQuestion = store.changeQuestionSession
            switch competition {
            case "newVoice": voice.open(); voice.dictation.transcript = "New voice draft"
            case "otherSheet": store.sheet = .other
            case "newQuestion": store.changeQuestionSession = ChangeQuestionSession(repository: store.url!)
            case "newRepository": store.url = URL(fileURLWithPath: "/fixture/another")
            case "inactiveWindow": store.fixtureWindow.fixtureKey = false
            case "dismissed": voice.dismiss()
            default: break
            }
            voice.sheetDidClose()
            await settle()
            if competition == "none" {
                check(store.sheet == .changeQuestion && store.changeQuestionSession === originalQuestion, "Dismissal presents the exact confirmed question session")
            } else if competition == "otherSheet" {
                check(store.sheet == .other, "Question handoff never replaces a competing sheet")
            } else {
                check(store.sheet == nil, "An obsolete question handoff cannot present over newer context")
            }
            if competition == "newVoice" {
                check(voice.presented && voice.dictation.transcript == "New voice draft", "Question handoff cannot close a new voice workspace")
            }
            voice.detach()
        }

        let (refreshStore, refresh) = environment()
        refresh.open(); refresh.dictation.transcript = "Keep this draft"
        refreshStore.reloadHead = "reloaded-head"
        await refresh.refreshContext()
        check(refreshStore.reloadCalls == 1 && refresh.context?.head == "reloaded-head", "Context refresh awaits a fresh repository reload")
        check(refresh.dictation.transcript == "Keep this draft", "Refreshing context does not replace the draft")
        let refreshGate = CoordinatorFixtureGate()
        refreshStore.reloadAction = { try? await refreshGate.wait() }
        let oldRefresh = Task { await refresh.refreshContext() }
        await awaitGate(refreshGate)
        refresh.dismiss(); refresh.open(); refresh.dictation.transcript = "Fresh presentation"
        let reopenedContext = refresh.context
        refreshStore.reloadHead = "late-head"
        refreshGate.finish(); await oldRefresh.value
        check(refresh.context == reopenedContext && refresh.dictation.transcript == "Fresh presentation", "An old refresh cannot replace a reopened context or draft")
        refresh.detach()

        check(TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.control, .shift]), "The app-local chord is Ctrl-Shift-Space")
        check(!TerminalHoldToTalk.matchesChord(keyCode: 49, modifiers: [.control, .option]), "The former chord does not trigger capture")
        print("Terminal voice coordinator: \(checks) checks passed with inert microphone, AI and agent boundaries")
    }
}
