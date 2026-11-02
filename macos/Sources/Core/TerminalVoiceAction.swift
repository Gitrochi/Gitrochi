import Foundation

/// A reviewed voice prompt has an explicit destination; choosing one never dispatches work.
enum TerminalVoiceDestination: String, CaseIterable, Identifiable {
    case terminal, explainChanges, commitDraft, agent

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: return String(localized: "Terminal")
        case .explainChanges: return String(localized: "Explain changes")
        case .commitDraft: return String(localized: "Commit draft")
        case .agent: return String(localized: "Ask agent")
        }
    }
    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .explainChanges: return "questionmark.bubble"
        case .commitDraft: return "text.badge.plus"
        case .agent: return "sparkles"
        }
    }
    var actionTitle: String {
        switch self {
        case .terminal: return String(localized: "Insert text")
        case .explainChanges: return String(localized: "Send question")
        case .commitDraft: return String(localized: "Generate draft")
        case .agent: return String(localized: "Start agent")
        }
    }
}

/// The composer stays bound to the repository, terminal and configuration it opened with.
struct TerminalVoiceContext: Equatable {
    let repositoryURL: URL
    let sessionID: UUID
    let directory: String
    let head: String?
    let repositoryName: String
    let storeID: UUID
    let explainConfiguration: String
    let commitConfiguration: String
    let selectionSignature: String
    let hasStagedChanges: Bool
}

/// Current state is supplied separately so stale destinations can be tested without processes or AI.
struct TerminalVoiceActionState {
    let repositoryURL: URL?
    let storeID: UUID
    let sessionID: UUID?
    let activeSessionID: UUID?
    let running: Bool
    let directory: String?
    let head: String?
    let explainConfiguration: String
    let commitConfiguration: String
    let selectionSignature: String
}

struct TerminalVoiceActionRequest {
    static let textLimit = 6_000
    let destination: TerminalVoiceDestination
    let text: String
    let context: TerminalVoiceContext

    var submittedText: String {
        destination == .terminal ? TerminalInput.singleLine(text) : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validate(current: TerminalVoiceActionState) throws {
        guard !submittedText.isEmpty else { throw TerminalVoiceActionError.emptyText }
        guard submittedText.count <= Self.textLimit else { throw TerminalVoiceActionError.textTooLong }
        guard current.storeID == context.storeID,
              current.repositoryURL.map(Self.path) == Self.path(context.repositoryURL) else {
            throw TerminalVoiceActionError.repositoryChanged
        }
        guard current.sessionID == context.sessionID, current.activeSessionID == context.sessionID, current.running else {
            throw TerminalVoiceActionError.terminalUnavailable
        }
        guard current.directory.map({ Self.path(URL(fileURLWithPath: $0)) }) == Self.path(URL(fileURLWithPath: context.directory)) else {
            throw TerminalVoiceActionError.directoryChanged
        }
        guard destination != .terminal else { return }
        guard (current.head ?? "") == (context.head ?? "") else { throw TerminalVoiceActionError.headChanged }
        if destination == .explainChanges {
            guard current.explainConfiguration == context.explainConfiguration else { throw TerminalVoiceActionError.settingsChanged }
            guard current.selectionSignature == context.selectionSignature else { throw TerminalVoiceActionError.selectionChanged }
        } else if destination == .commitDraft {
            guard current.commitConfiguration == context.commitConfiguration else { throw TerminalVoiceActionError.settingsChanged }
        }
    }

    private static func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}

enum TerminalVoiceActionError: LocalizedError, Equatable {
    case emptyText, textTooLong, repositoryChanged, terminalUnavailable, directoryChanged, headChanged
    case settingsChanged, selectionChanged, busy, stagedChanged, draftChanged, emptyDraft

    var errorDescription: String? {
        switch self {
        case .emptyText: return String(localized: "Enter or dictate a prompt first.")
        case .textTooLong: return String(localized: "This prompt is too long. Keep it under 6,000 characters.")
        case .repositoryChanged: return String(localized: "The repository changed. Reopen voice input before sending.")
        case .terminalUnavailable: return String(localized: "The selected terminal changed or stopped. Reopen voice input before sending.")
        case .directoryChanged: return String(localized: "The terminal folder changed. Reopen voice input before sending.")
        case .headChanged: return String(localized: "The repository HEAD changed. Reopen voice input before sending.")
        case .settingsChanged: return String(localized: "AI settings changed. Reopen voice input before sending.")
        case .selectionChanged: return String(localized: "The selected changes changed. Reopen voice input before sending.")
        case .busy: return String(localized: "Another request is still running. Wait for it to finish.")
        case .stagedChanged: return String(localized: "Staged changes changed while preparing the draft. Your existing message was kept.")
        case .draftChanged: return String(localized: "The commit message changed while preparing the draft. Your edits were kept.")
        case .emptyDraft: return String(localized: "The AI returned an empty draft. Your existing message was kept.")
        }
    }
}
