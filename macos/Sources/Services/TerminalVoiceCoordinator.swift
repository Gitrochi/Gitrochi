import AppKit
import Combine
import Observation

/// One voice draft belongs to one repository window and one captured terminal session.
@MainActor @Observable
final class TerminalVoiceCoordinator {
    let dictation = TerminalDictation()
    var presented = false
    private(set) var context: TerminalVoiceContext?
    private(set) var targetTitle = ""
    private(set) var isHolding = false
    private(set) var performing = false
    private(set) var paths: [String] = []
    @ObservationIgnored private weak var store: RepoStore?
    @ObservationIgnored private var hold: TerminalHoldToTalk?
    @ObservationIgnored private var pathsTask: Task<Void, Never>?
    @ObservationIgnored private var pathsRepository: URL?
    @ObservationIgnored private var windowObserver: AnyCancellable?
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var actionID: UUID?
    @ObservationIgnored private var pendingQuestion: (UUID, ChangeQuestionSession)?

    var repositoryWords: [String] {
        guard let store else { return [] }
        let changed = (store.status.staged + store.status.unstaged).map(\.path)
        return TerminalSpeechVocabulary.make(repositoryName: store.name,
                                             branches: store.localBranches.map(\.name),
                                             paths: changed + paths, custom: "")
    }

    var vocabulary: [String] {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "terminalDictationUseRepositoryWords") as? Bool ?? true
        let custom = defaults.string(forKey: "terminalDictationWords") ?? ""
        return TerminalSpeechVocabulary.bounded(
            TerminalSpeechVocabulary.make(repositoryName: "", branches: [], paths: [], custom: custom)
            + (enabled ? repositoryWords : []))
    }

    var localeIdentifier: String {
        let defaults = UserDefaults.standard
        return TerminalSpeechVocabulary.localeIdentifier(
            saved: defaults.string(forKey: "terminalDictationLocale") ?? "",
            appLanguage: defaults.string(forKey: AppLanguage.key) ?? "system",
            systemLanguage: TerminalSpeechVocabulary.preferredSystemLanguage)
    }

    func attach(to store: RepoStore) {
        self.store = store
        if windowObserver == nil {
            windowObserver = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
                .sink { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = notification.object as? NSWindow,
                              let owner = self.store?.window,
                              window !== owner && window !== owner.attachedSheet && window.sheetParent !== owner else { return }
                        if self.dictation.isBusy { self.dictation.cancel() }
                        self.isHolding = false
                        if self.performing {
                            self.store?.cancelTerminalVoiceAction()
                            self.lifecycle = UUID(); self.actionID = nil; self.performing = false
                        }
                    }
                }
        }
        if hold == nil {
            hold = TerminalHoldToTalk(isEligible: { [weak self, weak store] in
                guard let self, let store else { return false }
                return store.isActive && store.url != nil && store.sheet == nil && !self.performing && !self.underAnotherSheet
            }, begin: { [weak self] in
                guard let self else { return }
                if !self.presented { self.open() }
                guard self.presented else { return }
                self.isHolding = true
                if !self.dictation.needsPermissionSetup { self.startListening() }
            }, finish: { [weak self] in
                self?.isHolding = false
                self?.dictation.stop()
            }, cancel: { [weak self] in
                self?.isHolding = false
                self?.dictation.cancel()
            })
        }
        hold?.activate(in: store.window)
        loadPaths()
    }

    func detach() {
        hold?.deactivate()
        hold = nil
        pathsTask?.cancel()
        pathsTask = nil
        windowObserver = nil
        dismiss()
        store = nil
    }

    /// A sheet that is not `store.sheet` (a page's own) is over the window. The voice sheet would queue behind it while
    /// the microphone already listens, so the shortcut and the button wait for it to close.
    private var underAnotherSheet: Bool { !presented && store?.window?.attachedSheet != nil }

    func open(for session: TerminalSession? = nil) {
        guard let store, store.url != nil, store.sheet == nil, !performing, !underAnotherSheet else { return }
        if presented { return }
        let terminal = session ?? (store.activeTerminal?.running == true ? store.activeTerminal : nil) ?? store.newTerminal()
        guard let terminal, terminal.running,
              let context = store.terminalVoiceContext(for: terminal) else { return }
        store.selectTerminal(terminal)
        store.showTerminal = true
        self.context = context
        lifecycle = UUID(); pendingQuestion = nil
        targetTitle = terminal.title
        presented = true
        loadPaths()
    }

    func startListening() {
        guard presented, !performing, let context, let store,
              store.url == context.repositoryURL,
              store.activeTerminalID == context.sessionID else { return }
        dictation.start(localeIdentifier: localeIdentifier, contextualStrings: vocabulary)
    }

    func refreshContext() async {
        guard let store, !performing, let terminal = store.terminals.first(where: { $0.id == context?.sessionID }) else { return }
        let generation = lifecycle, repository = store.url
        await store.reload(quiet: true)
        guard !Task.isCancelled, generation == lifecycle, presented, !performing, store.url == repository else { return }
        context = store.terminalVoiceContext(for: terminal)
        targetTitle = terminal.title
        loadPaths()
    }

    func dismiss() {
        store?.cancelTerminalVoiceAction()
        lifecycle = UUID(); actionID = nil; pendingQuestion = nil
        dictation.cancel()
        isHolding = false
        performing = false
        presented = false
        context = nil
    }

    func perform(_ destination: TerminalVoiceDestination, text: String, agentKind: AgentKind) async throws {
        guard let store, let context, presented, !performing else {
            throw AIError.notConfigured(String(localized: "Open voice input again for the current repository."))
        }
        let generation = lifecycle, token = UUID()
        actionID = token; performing = true
        defer {
            if lifecycle == generation && actionID == token { performing = false; actionID = nil }
        }
        try await store.performTerminalVoiceAction(destination: destination, text: text, context: context, agentKind: agentKind)
        guard lifecycle == generation, actionID == token, presented, self.context == context else { throw CancellationError() }
        if destination == .explainChanges, let session = store.changeQuestionSession {
            pendingQuestion = (generation, session)
        }
        presented = false
        self.context = nil
        dictation.cancel()
    }

    func sheetDidClose() {
        guard !presented, let (generation, session) = pendingQuestion else { return }
        pendingQuestion = nil
        // Handoff follows the actual sheet dismissal and never replaces a newer window or task.
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, let store = self.store,
                  self.lifecycle == generation, !self.presented, store.sheet == nil,
                  store.url == session.repository, store.changeQuestionSession === session, session.active,
                  store.window?.isKeyWindow == true else { return }
            store.sheet = .changeQuestion
        }
    }

    private func loadPaths() {
        guard let store, let repository = store.url else { return }
        if pathsRepository != repository { paths = []; pathsRepository = repository }
        pathsTask?.cancel()
        pathsTask = Task { [weak self, weak store] in
            let result = try? await Git.run(["ls-files", "-z"], in: repository)
            guard !Task.isCancelled, let self, let store, store.url == repository else { return }
            self.paths = result.map { data in
                data.data.split(separator: 0).prefix(4000).map { String(decoding: $0, as: UTF8.self) }
            } ?? []
        }
    }
}
