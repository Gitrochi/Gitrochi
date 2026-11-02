import SwiftUI

struct TerminalVoiceReviewDraft {
    let destination: TerminalVoiceDestination
    let text: String
    let agentKind: AgentKind
}

/// Both texts remain visible until the user explicitly chooses the AI suggestion.
struct TerminalCleanupComparison: View {
    let original: String
    let suggestion: String
    let canApply: Bool
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Original").font(.caption.weight(.medium))
            Text(verbatim: original).font(.system(size: 12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Text("Cleaned text").font(.caption.weight(.medium))
            Text(verbatim: suggestion).font(.system(size: 12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Use cleaned text", action: apply).controlSize(.small).disabled(!canApply)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityIdentifier("terminal-dictation-comparison")
    }
}

/// Repository hints are optional and custom spelling stays under the user's control.
struct TerminalVocabularyOptions: View {
    @Binding var enabled: Bool
    @Binding var words: String
    let hints: [String]

    var body: some View {
        DisclosureGroup("Recognition hints") {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Use repository word hints", isOn: $enabled)
                Text("File names, branch names and your own terms help preserve Korean names and development words.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Custom words, separated by commas or new lines", text: $words, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    .accessibilityLabel("Custom recognition words")
                Text("\(hints.count) word hints enabled").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    Text(verbatim: hints.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced)).fixedSize()
                }.frame(height: 24)
                Text("Hints improve spelling; they do not replace or execute your words.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
        .font(.callout)
        .accessibilityIdentifier("terminal-dictation-vocabulary")
    }
}

/// A non-terminal destination gets one final, explicit review before any AI request or agent starts.
struct TerminalVoiceConfirmation: View {
    let draft: TerminalVoiceReviewDraft
    let repository: String
    let directory: String
    var provider = ""
    let working: Bool
    let back: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ready to send", systemImage: draft.destination.symbol).font(.callout.weight(.semibold))
            HStack {
                Text(verbatim: draft.destination.title)
                Spacer()
                Text(verbatim: repository).lineLimit(1)
            }.font(.caption.weight(.medium))
            if !provider.isEmpty {
                Text("Provider: \(provider)").font(.caption).foregroundStyle(.secondary)
            }
            if draft.destination == .agent {
                Text(verbatim: draft.agentKind.title + " · " + (directory as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(verbatim: draft.text).font(.system(size: 12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.detail(for: draft.destination)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back", action: back).disabled(working)
                Spacer()
                Button(draft.destination.actionTitle, action: confirm)
                    .buttonStyle(.borderedProminent).disabled(working)
                    .accessibilityIdentifier("terminal-dictation-confirm-send")
            }.controlSize(.small)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.2)) }
        .accessibilityIdentifier("terminal-dictation-confirmation")
    }

    static func detail(for destination: TerminalVoiceDestination) -> LocalizedStringKey {
        switch destination {
        case .terminal: return "Inserts one line into the selected terminal. Press Return yourself to run it."
        case .explainChanges: return "Sends your question and the current change snapshot to the configured explanation provider."
        case .commitDraft: return "Uses staged changes and your guidance to prepare a commit message. No commit is created."
        case .agent: return "Starts a new agent inside this app with normal approval or read-only permissions. The task is kept in its session."
        }
    }
}
