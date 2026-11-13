import SwiftUI

struct TerminalVoiceReviewDraft {
    let destination: TerminalVoiceDestination
    let text: String
    let agentKind: AgentKind
}

/// Both texts remain visible until the user explicitly chooses one of them.
struct TerminalCleanupComparison: View {
    let original: String
    let suggestion: String
    let canApply: Bool
    let discard: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                version("Original", original)
                StudioStyle.border.frame(height: 1).padding(.vertical, 8)
                version("Cleaned text", suggestion)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.border))
            .accessibilityElement(children: .contain)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Discard", action: discard).buttonStyle(HostedListButtonStyle())
                    .accessibilityIdentifier("terminal-dictation-discard")
                Button("Use cleaned text", action: apply).buttonStyle(HostedListButtonStyle()).disabled(!canApply)
            }
        }
        .accessibilityIdentifier("terminal-dictation-comparison")
    }

    private func version(_ label: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(HostedList.caption).frame(height: 16)
            // the whole text, not the board's one line: the two are there to be compared
            Text(verbatim: text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
    }
}

/// Repository hints are optional and custom spelling stays under the user's control.
struct TerminalVocabularyOptions: View {
    @Binding var enabled: Bool
    @Binding var words: String
    let hints: [String]
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use repository word hints", isOn: $enabled)
                Text("File names, branch names and your own terms help preserve Korean names and development words.")
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true)
                TextField("Custom words, separated by commas or new lines", text: $words, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    .accessibilityLabel("Custom recognition words")
                ScrollView(.horizontal) {
                    Text(verbatim: hints.joined(separator: " · "))
                        .font(.system(size: 11, design: .monospaced)).fixedSize()
                }.frame(height: 24)
                Text("Hints improve spelling; they do not replace or execute your words.")
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 8)
        } label: {
            // the count lives here, once
            HStack(spacing: 6) {
                Text("Recognition hints").font(.system(size: 13))
                Text("· \(hints.count) words on").font(.system(size: 12)).foregroundStyle(HostedList.caption)
            }
            .frame(height: 24)
        }
        .accessibilityIdentifier("terminal-dictation-vocabulary")
    }
}

/// What a destination other than the terminal is about to get: one final, explicit look before any AI request or agent
/// starts.
struct TerminalVoiceSummary: View {
    let draft: TerminalVoiceReviewDraft
    /// The repository and its branch
    let repository: String
    let directory: String
    var provider = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                row("Send to", draft.destination.title)
                row("Repository", repository)
                if !provider.isEmpty { row("AI provider", provider) }
                if draft.destination == .agent {
                    row("Agent", draft.agentKind.title)
                    row("Folder", (directory as NSString).abbreviatingWithTildeInPath)
                }
            }
            StudioStyle.border.frame(height: 1).padding(.vertical, 10)
            // the whole request, not the board's one line: this is the last look at it
            Text(verbatim: draft.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .contain)
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(key).foregroundStyle(HostedList.caption).frame(width: 96, alignment: .leading)
            Text(verbatim: value).lineLimit(1).truncationMode(.middle).help(value)
        }
        .font(.system(size: 12)).frame(minHeight: 20)
        .accessibilityElement(children: .combine)
    }

    /// The one line under the destinations: what the chosen one does
    static func hint(for destination: TerminalVoiceDestination, target: String) -> String {
        switch destination {
        case .terminal: return String(localized: "Inserts one line into \(target). Nothing runs until you press Return.")
        case .explainChanges: return String(localized: "Asks about your current changes, then opens the answer in a sheet.")
        case .commitDraft: return String(localized: "Writes a commit message from your staged changes. Nothing is committed.")
        case .agent: return String(localized: "Starts the agent in this app; it asks before it changes any file.")
        }
    }

    /// The line under the summary: what pressing the primary sends
    static func detail(for destination: TerminalVoiceDestination, target: String) -> String {
        destination == .explainChanges ? String(localized: "Sends this question with the current change snapshot, then opens the answer.")
            : hint(for: destination, target: target)
    }
}
