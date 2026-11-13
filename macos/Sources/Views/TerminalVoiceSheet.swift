import SwiftUI

/// The same voice workflow is available from the terminal button and the app-local hold shortcut.
struct TerminalVoiceSheet: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        let voice = store.terminalVoice
        TerminalDictationComposer(dictation: voice.dictation, target: voice.targetTitle,
                                  repositoryName: voice.context?.repositoryName ?? store.name,
                                  branch: store.headBranch ?? "",
                                  directory: voice.context?.directory ?? "",
                                  repositoryWords: voice.repositoryWords,
                                  commitAvailable: !store.status.staged.isEmpty,
                                  providerTitle: { destination in
                                      let ai = AIStore.shared
                                      let feature: AIFeature
                                      switch destination {
                                      case .explainChanges: feature = .explain
                                      case .commitDraft: feature = .commit
                                      default: return ""
                                      }
                                      let provider = ai.provider(for: feature)
                                      let model = ai.model(provider)
                                      return provider.title + (model.isEmpty ? "" : " · " + model)
                                  },
                                  isHolding: voice.isHolding,
                                  listen: { voice.startListening() },
                                  send: { destination, text, kind in
                                      try await voice.perform(destination, text: text, agentKind: kind)
                                  }, refreshContext: { await voice.refreshContext() },
                                  insert: { text in
                                      guard let id = voice.context?.sessionID,
                                            let terminal = store.terminals.first(where: { $0.id == id }) else { return }
                                      terminal.insertText(text)
                                      voice.dismiss()
                                  }, dismiss: { voice.dismiss() })
    }
}
