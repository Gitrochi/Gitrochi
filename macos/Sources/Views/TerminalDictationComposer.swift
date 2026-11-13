import SwiftUI
import AppKit

/// What stopped a send, in the failure block's words
struct TerminalVoiceFailure {
    let title: String
    var caption: String? = nil
    /// The provider's own words, on hover
    var detail: String? = nil
}

/// Voice input moves from a local draft to optional cleanup and an explicitly reviewed destination.
struct TerminalDictationComposer: View {
    @Bindable var dictation: TerminalDictation
    @AppStorage("terminalDictationLocale") private var localeIdentifier = ""
    @AppStorage("terminalDictationUseRepositoryWords") private var useRepositoryWords = true
    @AppStorage("terminalDictationWords") private var customWords = ""
    @Environment(\.openSettings) private var openSettings
    @ViewState private var cleanup = TerminalTextCleanup()
    @ViewState private var destination = TerminalVoiceDestination.terminal
    @ViewState private var agentKind = AgentKind.claude
    @ViewState private var confirmation: TerminalVoiceReviewDraft?
    @ViewState private var acceptedOriginal: String?
    @ViewState private var submitting = false
    @ViewState private var failure: TerminalVoiceFailure?
    @ViewState private var actionTask: Task<Void, Never>?
    @ViewState private var refreshingContext = false
    @ViewState private var listeningSince: Date?
    // the board's idle body, until the first layout measures the real one
    @ViewState private var bodyHeight: CGFloat = 474
    let target: String
    var repositoryName = ""
    var branch = ""
    var directory = ""
    var repositoryWords: [String] = []
    var commitAvailable = true
    var providerTitle: (TerminalVoiceDestination) -> String = { _ in "" }
    var isHolding = false
    var listen: (() -> Void)?
    var send: ((TerminalVoiceDestination, String, AgentKind) async throws -> Void)?
    var refreshContext: (() async -> Void)?
    let insert: (String) -> Void
    let dismiss: () -> Void

    /// The sheet is as tall as what it shows, up to the comparison of two versions; past this the body scrolls
    private static let bodyLimit: CGFloat = 624

    var body: some View {
        SharedSheet(title: String(localized: "Voice"),
                    // a terminal named after its repository would say the same word twice
                    context: repositoryName.isEmpty || repositoryName == target ? target : repositoryName + " · " + target,
                    primary: primary, cancel: dismiss) {
            if confirmation == nil {
                listenButton
            } else {
                Button("Back") { confirmation = nil; failure = nil }.disabled(submitting || refreshingContext)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ScrollViewReader { scroll in
                    ScrollView {
                        Group {
                            if let confirmation { summary(confirmation) } else { compose }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                    }
                    .frame(height: min(bodyHeight, Self.bodyLimit))
                    .onChange(of: cleanup.hasSuggestion) { _, ready in
                        if ready { withAnimation { scroll.scrollTo("voice-cleanup", anchor: .top) } }
                    }
                    .onChange(of: failure != nil) { _, failed in
                        if failed && confirmation == nil { withAnimation { scroll.scrollTo("voice-destination", anchor: .bottom) } }
                    }
                }
                privacy
            }
        }
        .onAppear { if dictation.state == .listening { listeningSince = Date() } }
        .onChange(of: dictation.transcript) { _, text in
            cleanup.invalidate(ifSourceChanged: text)
            confirmation = nil
        }
        .onChange(of: dictation.state) { _, state in
            if state == .requesting || state == .listening {
                cleanup.reset(); acceptedOriginal = nil; confirmation = nil; failure = nil
            }
            listeningSince = state == .listening ? Date() : nil
        }
        .onChange(of: destination) { _, _ in confirmation = nil; failure = nil }
        .onChange(of: agentKind) { _, _ in confirmation = nil; failure = nil }
        .onChange(of: customWords) { _, value in
            if value.count > 4_000 { customWords = String(value.prefix(4_000)) }
        }
        .onDisappear { actionTask?.cancel(); cleanup.reset(); dictation.cancel() }
    }

    // MARK: The draft

    private var compose: some View {
        VStack(alignment: .leading, spacing: 16) {
            languageRow
            // what went wrong takes the status's place, above the draft that can still be typed
            if let error = dictation.error { recognitionNotice(error) } else { statusBlock }
            editor
            if destination == .terminal && !dictation.isBusy && !insertionText.isEmpty && dictation.transcript != insertionText {
                insertionPreview
            }
            cleanupCard.disabled(submitting || refreshingContext).id("voice-cleanup")
            if send != nil { destinationSection.id("voice-destination") }
            TerminalVocabularyOptions(enabled: $useRepositoryWords, words: $customWords, hints: activeWords)
                .disabled(dictation.isBusy || submitting)
        }
    }

    private var languageRow: some View {
        HStack(spacing: 10) {
            Text("Speech language").font(.system(size: 13))
            Picker("Speech language", selection: $localeIdentifier) {
                Text("Automatic").tag("")
                Text(verbatim: "English (US)").tag("en-US")
                Text(verbatim: "한국어").tag("ko-KR")
            }
            .labelsHidden().fixedSize()
            .disabled(dictation.isBusy || submitting || refreshingContext)
            Spacer(minLength: 8)
            Text(verbatim: "⌃⇧Space")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.Tone.neutral.text)
                .padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHolding ? StudioStyle.Tone.neutral.fill : StudioStyle.canvas))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(HostedList.edge))
        }
        .frame(height: 28)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                meter
                Text(status).font(.system(size: 13, weight: .semibold))
                if dictation.state == .listening, let listeningSince {
                    TimelineView(.periodic(from: listeningSince, by: 1)) { timeline in
                        Text(verbatim: Self.elapsed(from: listeningSince, to: timeline.date))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(HostedList.caption)
                    }
                }
                if dictation.state == .requesting || dictation.state == .finishing { ProgressView().controlSize(.small) }
            }
            .frame(height: 20)
            Text(verbatim: hint).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your draft").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(verbatim: "\(dictation.transcript.count.formatted()) / 6,000")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(tooLong ? StudioStyle.Tone.failed.text : HostedList.caption)
            }
            .frame(height: 16)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $dictation.transcript)
                    .font(.system(size: 13)).lineSpacing(4)
                    .scrollContentBackground(.hidden).padding(.horizontal, 5).padding(.vertical, 8)
                    .disabled(dictation.isBusy || submitting)
                    .accessibilityLabel("Your draft")
                if dictation.transcript.isEmpty {
                    Text("Speak or type a prompt, then review it here.")
                        .font(.system(size: 13)).foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 10).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 8).fill(StudioStyle.surface))
            .overlay {
                // the words land here while listening: the input's focus ring, as the board draws it
                if dictation.state == .listening {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(HostedList.edge)
                }
            }
        }
    }

    private var insertionPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Will insert as one line").font(.system(size: 12, weight: .medium))
            ScrollView(.horizontal) {
                Text(verbatim: insertionText).font(.system(size: 11, design: .monospaced))
                    .fixedSize().textSelection(.enabled)
            }.frame(height: 24)
        }
        .foregroundStyle(HostedList.caption)
        .accessibilityIdentifier("terminal-dictation-insertion-preview")
    }

    /// A refused permission offers the one way out, filled; anything else can be tried again
    @ViewBuilder private func recognitionNotice(_ error: String) -> some View {
        let again = NoticeAction(title: String(localized: "Try again"), run: startListening)
        if let recovery = dictation.recovery {
            Group {
                switch recovery {
                case .microphone:
                    NoticeBlock(symbol: "exclamationmark.triangle.fill", title: String(localized: "Microphone access is off"), caption: error,
                                actions: [settings(String(localized: "Open Microphone Settings…"), recovery, filled: true)])
                case .speech:
                    NoticeBlock(symbol: "exclamationmark.triangle.fill", title: String(localized: "Speech recognition access is off"), caption: error,
                                actions: [settings(String(localized: "Open Speech Recognition Settings…"), recovery, filled: true)])
                case .language:
                    NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: String(localized: "Speech recognition isn't available"),
                                caption: error, actions: [settings(String(localized: "Open Keyboard Settings…"), recovery), again])
                case .inputDevice:
                    NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: error,
                                actions: [settings(String(localized: "Open Sound Settings…"), recovery), again])
                }
            }
            .accessibilityIdentifier("terminal-dictation-recovery")
        } else {
            NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: error, actions: [again])
        }
    }

    private func settings(_ title: String, _ recovery: TerminalDictation.Recovery, filled: Bool = false) -> NoticeAction {
        NoticeAction(title: title, filled: filled) {
            if let url = recovery.settingsURL { NSWorkspace.shared.open(url) }
        }
    }

    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Clean up with AI").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if cleanup.working {
                    ProgressView().controlSize(.small)
                    Button("Stop") { cleanup.cancel() }.buttonStyle(HostedListButtonStyle())
                } else if !cleanup.hasSuggestion && cleanup.error == nil && cleanupProblem == nil {
                    // it hides while there are two versions to choose from and after a failure, whose block has Retry
                    Button("Clean up", action: clean).buttonStyle(HostedListButtonStyle())
                        .disabled(dictation.isBusy || submitting || dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("terminal-dictation-cleanup")
                }
            }
            .frame(height: 28)
            Text("Sends this draft and word hints to \(Self.name(cleanup.providerTitle)). The original is kept.")
                .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            if let cleanupProblem {
                NoticeBlock(symbol: "exclamationmark.triangle.fill", title: cleanupProblem,
                            actions: [NoticeAction(title: String(localized: "Open Settings")) { openSettings() }])
                    .padding(.top, 10)
            } else if let error = cleanup.error {
                FailureBlock(title: cleanup.unreachable ? String(localized: "Couldn't reach \(Self.name(cleanup.providerTitle))") : error,
                             caption: cleanup.unreachable ? error : nil, retry: clean)
                    .padding(.top, 10)
                    .accessibilityIdentifier("terminal-dictation-cleanup-failure")
            } else if cleanup.hasSuggestion, let original = cleanup.original, let suggestion = cleanup.suggestion {
                TerminalCleanupComparison(original: original, suggestion: suggestion,
                                          canApply: cleanup.canApply(to: dictation.transcript), discard: { cleanup.reset() }, apply: {
                    guard cleanup.canApply(to: dictation.transcript) else { return }
                    acceptedOriginal = original
                    cleanup.reset()
                    dictation.transcript = suggestion
                })
                .padding(.top, 10)
            }
            if let acceptedOriginal, dictation.transcript != acceptedOriginal {
                Button("Restore original") {
                    cleanup.reset(); dictation.transcript = acceptedOriginal; self.acceptedOriginal = nil
                }
                .buttonStyle(PullRequestTextButtonStyle()).padding(.top, 6)
                .accessibilityIdentifier("terminal-dictation-restore")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send to").font(.system(size: 13, weight: .semibold)).frame(height: 20)
            PullRequestSegmented(label: "Send to", items: TerminalVoiceDestination.allCases.map { value in
                .init(value: value, title: value.title, disabledReason: dictation.isBusy ? String(localized: "Stop listening first") : nil)
            }, selection: destination, fill: true) { destination = $0 }
                .disabled(submitting || refreshingContext)
                .padding(.top, 8)
            Text(verbatim: TerminalVoiceSummary.hint(for: destination, target: target))
                .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            if destination == .agent {
                HStack(spacing: 8) {
                    Text("Agent").foregroundStyle(StudioStyle.Tone.neutral.text)
                    Picker("Agent", selection: $agentKind) {
                        ForEach(AgentKind.allCases) { kind in Text(verbatim: kind.title).tag(kind) }
                    }
                    .labelsHidden().fixedSize().disabled(dictation.isBusy || submitting || refreshingContext)
                    Text("\(agentKind.title) opens in a new terminal tab.").foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12)).frame(minHeight: 24).padding(.top, 8)
            }
            // an insertion that failed has no summary to show it in, so it sits under the destination it was for
            if let failure {
                FailureBlock(title: failure.title, caption: failure.caption, detail: failure.detail, retrying: refreshingContext, retry: retry)
                    .padding(.top, 10)
            }
        }
        .accessibilityIdentifier("terminal-dictation-destination")
    }

    // MARK: The review before sending

    /// A destination other than the terminal turns the body into what is about to be sent, and the primary into the send
    private func summary(_ draft: TerminalVoiceReviewDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready to send").font(.system(size: 13, weight: .semibold)).frame(height: 20)
            TerminalVoiceSummary(draft: draft, repository: branch.isEmpty ? repositoryName : repositoryName + " · " + branch,
                                 directory: directory, provider: providerTitle(draft.destination))
            if let failure {
                FailureBlock(title: failure.title, caption: failure.caption, detail: failure.detail, retrying: refreshingContext, retry: retry)
            } else if submitting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(draft.destination == .explainChanges ? LocalizedStringKey("Sending… The answer opens when it's ready.") : LocalizedStringKey("Sending…"))
                }
                .font(.system(size: 12)).foregroundStyle(HostedList.caption).frame(minHeight: 16)
            } else {
                Text(verbatim: TerminalVoiceSummary.detail(for: draft.destination, target: target))
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 16)
            }
        }
        .accessibilityIdentifier("terminal-dictation-confirmation")
    }

    // MARK: The strip and the footer

    private var privacy: some View {
        HStack(spacing: 8) {
            SymbolIcon("lock.shield").font(.system(size: 13))
            Text("Speech is recognized on this Mac. Text goes to AI only when you choose.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(HostedList.caption)
        .padding(.horizontal, 20).frame(minHeight: 32)
    }

    /// The footer's secondary action: recording starts and stops on the left, away from the one primary
    @ViewBuilder private var listenButton: some View {
        if dictation.isBusy {
            Button("Stop listening") { dictation.stop() }
                .disabled(dictation.state != .listening)
        } else {
            Button(dictation.transcript.isEmpty ? LocalizedStringKey("Start listening") : LocalizedStringKey("Record again"),
                   action: startListening).disabled(submitting)
        }
    }

    private var primary: SheetPrimary {
        if let confirmation {
            return SheetPrimary(title: submitting ? String(localized: "Sending…") : confirmation.destination.actionTitle,
                                disabledReason: failure == nil ? nil : DisabledReason.retryAbove, busy: submitting, isDefault: false,
                                identifier: "terminal-dictation-submit") { perform(confirmation) }
        }
        return SheetPrimary(title: destination == .terminal ? String(localized: "Insert text") : String(localized: "Review before sending"),
                            disabledReason: submitReason, disabled: submitting || refreshingContext, busy: submitting, isDefault: false,
                            identifier: "terminal-dictation-submit", run: submit)
    }

    private func submit() {
        let draft = TerminalVoiceReviewDraft(destination: destination, text: dictation.transcript, agentKind: agentKind)
        if destination == .terminal { perform(draft) } else { confirmation = draft }
    }

    /// Why the primary can't be used: it is never disabled without one of these beside it
    private var submitReason: String? {
        if failure != nil { return DisabledReason.retryAbove }
        if dictation.isBusy { return String(localized: "Stop listening first") }
        if cleanup.working { return String(localized: "Cleanup is still running") }
        if cleanup.hasSuggestion { return String(localized: "Choose a version first") }
        if insertionText.isEmpty { return String(localized: "Speak or type a draft first") }
        if tooLong { return String(localized: "This prompt is too long. Keep it under 6,000 characters.") }
        if destination == .commitDraft && !commitAvailable { return String(localized: "Stage changes before drafting a commit.") }
        return nil
    }

    private var tooLong: Bool { dictation.transcript.count > TerminalVoiceActionRequest.textLimit }
    private var insertionText: String { TerminalInput.singleLine(dictation.transcript) }
    private var cleanupProblem: String? { AIStore.shared.problem(AIStore.shared.provider) }
    private var activeWords: [String] {
        TerminalSpeechVocabulary.bounded(TerminalSpeechVocabulary.make(repositoryName: "", branches: [], paths: [], custom: customWords)
                                        + (useRepositoryWords ? repositoryWords : []))
    }
    private var effectiveLocale: String {
        TerminalSpeechVocabulary.localeIdentifier(saved: localeIdentifier,
            appLanguage: UserDefaults.standard.string(forKey: AppLanguage.key) ?? "system",
            systemLanguage: TerminalSpeechVocabulary.preferredSystemLanguage)
    }

    /// "Claude · sonnet" names its model too; a sentence takes the provider alone
    private static func name(_ provider: String) -> String { provider.components(separatedBy: " · ").first ?? provider }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
    }

    private func startListening() {
        cleanup.reset(); acceptedOriginal = nil; confirmation = nil
        if let listen { listen() }
        else { dictation.start(localeIdentifier: effectiveLocale, contextualStrings: activeWords) }
    }

    private func clean() {
        failure = nil; confirmation = nil
        cleanup.clean(dictation.transcript, vocabulary: activeWords, language: effectiveLocale)
    }

    private func perform(_ draft: TerminalVoiceReviewDraft) {
        guard !submitting else { return }
        submitting = true; failure = nil
        actionTask = Task { @MainActor in
            do {
                if let send { try await send(draft.destination, draft.text, draft.agentKind) }
                else if draft.destination == .terminal { insert(draft.text) }
                submitting = false
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                submitting = false
                failure = TerminalVoiceFailure(title: String(localized: "The request was cancelled. Your draft is kept."))
            } catch {
                guard !Task.isCancelled else { return }
                submitting = false
                // the summary stays, with what failed and Retry in it
                let provider = Self.name(providerTitle(draft.destination)), kept = String(localized: "Nothing was sent. Your draft is kept.")
                if case AIError.failed = error, !provider.isEmpty {
                    failure = TerminalVoiceFailure(title: String(localized: "Couldn't reach \(provider)"), caption: kept, detail: error.localizedDescription)
                } else {
                    failure = TerminalVoiceFailure(title: error.localizedDescription, caption: kept)
                }
            }
        }
    }

    /// Most sends fail because the repository or the terminal moved on: Retry reads them again, and the send is then
    /// the user's to press once more
    private func retry() {
        guard let refreshContext else { failure = nil; return }
        refreshingContext = true
        actionTask = Task { @MainActor in
            await refreshContext()
            guard !Task.isCancelled else { return }
            refreshingContext = false; failure = nil
        }
    }

    private var status: LocalizedStringKey {
        switch dictation.state {
        case .idle, .failure: return "Ready"
        case .requesting: return "Requesting access…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .review: return "Review your text"
        }
    }

    private var hint: String {
        if let notice = dictation.notice { return notice }
        switch dictation.state {
        case .listening, .finishing:
            return isHolding ? String(localized: "Release ⌃⇧Space to stop. Your words appear below as you speak.")
                : String(localized: "Your words appear below as you speak.")
        case .review: return String(localized: "Edit the draft if needed, or hold ⌃⇧Space to record again.")
        case .idle, .requesting, .failure:
            return dictation.needsPermissionSetup ? String(localized: "Allow access with Start listening before using hold to talk.")
                : String(localized: "Hold ⌃⇧Space to talk, release to review. Works only in this app.")
        }
    }

    /// Progress, not status: the bars take the accent only while they move
    private var meter: some View {
        HStack(spacing: 2) {
            ForEach(0..<9) { index in
                Capsule().fill(dictation.state == .listening ? Color.accentColor : StudioStyle.Rail.blocked)
                    .frame(width: 3, height: dictation.state == .listening
                           ? 4 + CGFloat(dictation.level) * CGFloat([3, 9, 12, 6, 12, 10, 4, 9, 2][index]) : 4)
            }
        }
        .frame(width: 43, height: 16).animation(.easeOut(duration: 0.1), value: dictation.level)
        .accessibilityHidden(true)
    }
}
