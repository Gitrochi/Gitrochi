import SwiftUI
import AppKit

/// Voice input moves from a local draft to optional cleanup and an explicitly reviewed destination.
struct TerminalDictationComposer: View {
    @Bindable var dictation: TerminalDictation
    @AppStorage("terminalDictationLocale") private var localeIdentifier = ""
    @AppStorage("terminalDictationUseRepositoryWords") private var useRepositoryWords = true
    @AppStorage("terminalDictationWords") private var customWords = ""
    @ViewState private var cleanup = TerminalTextCleanup()
    @ViewState private var destination = TerminalVoiceDestination.terminal
    @ViewState private var agentKind = AgentKind.claude
    @ViewState private var confirmation: TerminalVoiceReviewDraft?
    @ViewState private var acceptedOriginal: String?
    @ViewState private var submitting = false
    @ViewState private var actionError: String?
    @ViewState private var actionTask: Task<Void, Never>?
    @ViewState private var refreshingContext = false
    let target: String
    var repositoryName = ""
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

    var body: some View {
        VStack(spacing: 0) {
            header.padding(18)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        recordingSection
                        editor
                        if destination == .terminal && !dictation.isBusy && !insertionText.isEmpty && dictation.transcript != insertionText {
                            insertionPreview
                        }
                        VStack(alignment: .leading, spacing: 8) { errors }.id("voice-errors")
                        cleanupSection.disabled(submitting || dictation.isBusy || refreshingContext)
                            .id("voice-cleanup")
                        if send != nil { destinationSection }
                        TerminalVocabularyOptions(enabled: $useRepositoryWords, words: $customWords, hints: activeWords)
                            .disabled(dictation.isBusy || submitting)
                        if let confirmation {
                            TerminalVoiceConfirmation(draft: confirmation, repository: repositoryName,
                                                      directory: directory, provider: providerTitle(confirmation.destination), working: submitting,
                                                      back: { self.confirmation = nil },
                                                      confirm: { perform(confirmation) })
                                .id("voice-confirmation")
                        }
                        Label("Speech stays on your Mac. Clean up and AI destinations use your configured provider only when you send.", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                }
                .onChange(of: confirmation != nil) { _, ready in
                    if ready { withAnimation { scroll.scrollTo("voice-confirmation", anchor: .bottom) } }
                }
                .onChange(of: cleanup.hasSuggestion) { _, ready in
                    if ready { withAnimation { scroll.scrollTo("voice-cleanup", anchor: .top) } }
                }
                .onChange(of: actionError) { _, error in
                    if error != nil { withAnimation { scroll.scrollTo("voice-errors", anchor: .top) } }
                }
            }
            Divider()
            footer.padding(14)
        }
        .frame(width: 500)
        .frame(minHeight: 520, idealHeight: 660, maxHeight: 760)
        .onChange(of: dictation.transcript) { _, text in
            cleanup.invalidate(ifSourceChanged: text)
            confirmation = nil
        }
        .onChange(of: dictation.state) { _, state in
            if state == .requesting || state == .listening {
                cleanup.reset(); acceptedOriginal = nil; confirmation = nil; actionError = nil
            }
        }
        .onChange(of: destination) { _, _ in confirmation = nil; actionError = nil }
        .onChange(of: agentKind) { _, _ in confirmation = nil; actionError = nil }
        .onChange(of: customWords) { _, value in
            if value.count > 4_000 { customWords = String(value.prefix(4_000)) }
        }
        .onDisappear { actionTask?.cancel(); cleanup.reset(); dictation.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TerminalBrand(compact: true)
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Voice workspace").font(.headline)
                Text(verbatim: repositoryName.isEmpty ? target : repositoryName + " · " + target)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(verbatim: "macOS").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Speech language", selection: $localeIdentifier) {
                Text("Automatic").tag("")
                Text(verbatim: "English (US)").tag("en-US")
                Text(verbatim: "한국어").tag("ko-KR")
            }
            .disabled(dictation.isBusy || submitting || refreshingContext)
            HStack(spacing: 10) {
                waveform
                Text(status).font(.callout.weight(.medium))
                Spacer(minLength: 0)
                if dictation.isBusy && dictation.state != .listening { ProgressView().controlSize(.small) }
                Text(verbatim: "⌃⇧Space")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Color.primary.opacity(isHolding ? 0.12 : 0.045), in: RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 28)
            if dictation.needsPermissionSetup {
                Text("Allow access with Start listening before using hold to talk.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Hold Control-Shift-Space to talk. Release to review. Works only in this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your draft").font(.caption.weight(.medium))
                Spacer()
                Text(verbatim: "\(dictation.transcript.count.formatted()) / 6,000")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(dictation.transcript.count > TerminalVoiceActionRequest.textLimit ? Color.red : Color.secondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $dictation.transcript)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden).padding(6)
                    .disabled(dictation.isBusy || submitting)
                    .accessibilityLabel("Dictated text")
                if dictation.transcript.isEmpty {
                    Text("Speak a prompt, then review it here.")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)) }
        }
    }

    private var insertionPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Will insert as one line").font(.caption.weight(.medium))
            ScrollView(.horizontal) {
                Text(verbatim: insertionText).font(.system(size: 11, design: .monospaced))
                    .fixedSize().textSelection(.enabled)
            }.frame(height: 26)
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("terminal-dictation-insertion-preview")
    }

    @ViewBuilder private var errors: some View {
        if let error = dictation.error {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        if let recovery = dictation.recovery, let url = recovery.settingsURL {
            Button(recoveryTitle(recovery)) { NSWorkspace.shared.open(url) }
                .buttonStyle(.borderless).font(.caption)
                .accessibilityIdentifier("terminal-dictation-recovery")
        }
        if let notice = dictation.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        if let actionError { Text(actionError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        if actionError != nil, let refreshContext {
            Button("Refresh repository context") {
                refreshingContext = true; confirmation = nil
                actionTask = Task { @MainActor in
                    await refreshContext()
                    guard !Task.isCancelled else { return }
                    refreshingContext = false; actionError = nil
                }
            }
                .buttonStyle(.borderless).font(.caption)
                .disabled(submitting || refreshingContext)
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("Polish your words", systemImage: "wand.and.stars").font(.callout.weight(.medium))
                Spacer()
                if cleanup.working {
                    ProgressView().controlSize(.small)
                    Button("Stop") { cleanup.cancel() }.controlSize(.small)
                } else {
                    Button("Clean up") {
                        actionError = nil; confirmation = nil
                        cleanup.clean(dictation.transcript, vocabulary: activeWords, language: effectiveLocale)
                    }
                    .controlSize(.small)
                    .disabled(dictation.isBusy || submitting || cleanupProblem != nil || dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("terminal-dictation-cleanup")
                }
            }
            Text(verbatim: cleanup.providerTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let cleanupProblem {
                Text(cleanupProblem).font(.caption).foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings") }.font(.caption)
            }
            Text("Only this draft and enabled word hints are sent. The original is kept for comparison.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = cleanup.error { Text(error).font(.caption).foregroundStyle(.red) }
            if cleanup.hasSuggestion, let original = cleanup.original, let suggestion = cleanup.suggestion {
                TerminalCleanupComparison(original: original, suggestion: suggestion,
                                          canApply: cleanup.canApply(to: dictation.transcript), apply: {
                    guard cleanup.canApply(to: dictation.transcript) else { return }
                    acceptedOriginal = original
                    cleanup.reset()
                    dictation.transcript = suggestion
                })
            }
            if let acceptedOriginal, dictation.transcript != acceptedOriginal {
                Button("Restore original") {
                    cleanup.reset(); dictation.transcript = acceptedOriginal; self.acceptedOriginal = nil
                }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Choose a destination").font(.callout.weight(.medium))
            Picker("Destination", selection: $destination) {
                ForEach(TerminalVoiceDestination.allCases) { value in Text(verbatim: value.title).tag(value) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(dictation.isBusy || submitting || refreshingContext)
            Text(TerminalVoiceConfirmation.detail(for: destination))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !providerTitle(destination).isEmpty {
                Text("Provider: \(providerTitle(destination))").font(.caption).foregroundStyle(.secondary)
            }
            if destination == .agent {
                Picker("Agent", selection: $agentKind) {
                    ForEach(AgentKind.allCases) { kind in Text(verbatim: kind.title).tag(kind) }
                }.disabled(submitting || refreshingContext)
            }
            if destination == .commitDraft && !commitAvailable {
                Text("Stage changes before drafting a commit.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("terminal-dictation-destination")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            if dictation.isBusy {
                Button("Stop listening") { dictation.stop() }
                    .disabled(dictation.state != .listening)
            } else {
                Button(dictation.transcript.isEmpty ? LocalizedStringKey("Start listening") : LocalizedStringKey("Record again")) {
                    cleanup.reset(); acceptedOriginal = nil; confirmation = nil
                    if let listen { listen() }
                    else { dictation.start(localeIdentifier: effectiveLocale, contextualStrings: activeWords) }
                }.disabled(submitting)
            }
            if submitting { ProgressView().controlSize(.small) }
            Button(destination == .terminal ? LocalizedStringKey("Insert text") : LocalizedStringKey("Review before sending")) {
                let draft = TerminalVoiceReviewDraft(destination: destination, text: dictation.transcript, agentKind: agentKind)
                if destination == .terminal { perform(draft) } else { confirmation = draft }
            }
            .buttonStyle(.borderedProminent)
            .disabled(submitDisabled)
            .accessibilityIdentifier("terminal-dictation-submit")
        }
        .controlSize(.small)
    }

    private var submitDisabled: Bool {
        dictation.isBusy || cleanup.working || submitting || refreshingContext || insertionText.isEmpty
            || dictation.transcript.count > TerminalVoiceActionRequest.textLimit
            || (destination == .commitDraft && !commitAvailable)
    }
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
    private func perform(_ draft: TerminalVoiceReviewDraft) {
        guard !submitting else { return }
        submitting = true; actionError = nil
        actionTask = Task { @MainActor in
            do {
                if let send { try await send(draft.destination, draft.text, draft.agentKind) }
                else if draft.destination == .terminal { insert(draft.text) }
                submitting = false
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                submitting = false; confirmation = nil
                actionError = String(localized: "The request was cancelled. Your draft is kept.")
            } catch {
                guard !Task.isCancelled else { return }
                submitting = false; confirmation = nil; actionError = error.localizedDescription
            }
        }
    }
    private func recoveryTitle(_ recovery: TerminalDictation.Recovery) -> LocalizedStringKey {
        switch recovery {
        case .microphone: return "Open Microphone settings"
        case .speech: return "Open Speech Recognition settings"
        case .language: return "Open Keyboard settings"
        case .inputDevice: return "Open Sound settings"
        }
    }
    private var status: LocalizedStringKey {
        switch dictation.state {
        case .idle: return "Ready to listen"
        case .requesting: return "Requesting access…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .review: return "Review your text"
        case .failure: return "Voice input unavailable"
        }
    }
    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(0..<9) { index in
                Capsule().fill(dictation.state == .listening ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 3, height: dictation.state == .listening
                           ? 4 + CGFloat(dictation.level) * CGFloat([12, 20, 14, 24, 16, 22, 12, 18, 10][index]) : 4)
            }
        }
        .frame(width: 44, height: 28).animation(.easeOut(duration: 0.1), value: dictation.level)
        .accessibilityHidden(true)
    }
}
