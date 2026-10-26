import SwiftUI

struct ChangeQuestionSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var showPreview = true

    var body: some View {
        Group {
            if let session = store.changeQuestionSession { content(session) }
            else { ProgressView().padding(40) }
        }
        .frame(width: 780)
        .onDisappear { store.cancelChangeQuestion() }
        .onExitCommand { dismiss() }
    }

    private func content(_ session: ChangeQuestionSession) -> some View {
        @Bindable var session = session
        let problem = AIStore.shared.problem(session.provider)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Ask AI about changes").font(.title3.weight(.semibold))
            Text(session.providerTitle).font(.callout).foregroundStyle(.secondary)
            Text("Review the snapshot before sending. Your question and recent conversation are included. AI answers do not change files.")
                .font(.caption).foregroundStyle(.secondary)
            if session.loading {
                HStack { ProgressView().controlSize(.small); Text("Preparing change snapshot…") }.padding(.vertical, 30)
            }
            if let snapshot = session.snapshot {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.scope).font(.subheadline.weight(.semibold))
                    if let path = snapshot.path { Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    Text(snapshot.repository + " · HEAD " + String(snapshot.head.prefix(12))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("This conversation keeps this snapshot even if your selection or files change. Use New snapshot to start again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.omitted > 0 {
                    Text("Diff truncated: \(snapshot.omitted) characters omitted.").font(.caption).foregroundStyle(.orange)
                }
                ForEach(snapshot.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Context for AI", isExpanded: $showPreview) {
                    ScrollView {
                        Text(snapshot.context).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: session.messages.isEmpty ? 180 : 110)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                if !session.messages.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(session.messages) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.isUser ? String(localized: "You") : String(localized: "AI answer")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(message.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.id(message.id)
                                }
                            }.padding(8)
                        }.frame(maxHeight: 240)
                            .onChange(of: session.messages.count) { _, _ in if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                TextEditor(text: $session.question)
                    .font(.callout).frame(height: 74).padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
                    .accessibilityLabel(Text("Question about this snapshot"))
                HStack {
                    ForEach([String(localized: "What risks do you see?"), String(localized: "Which tests should I run?"), String(localized: "Explain this change.")], id: \.self) { question in
                        Button(question) { session.question = question }.disabled(session.working)
                    }
                    Spacer()
                    Text("\(session.question.count)/\(ChangeQuestionSnapshot.questionLimit)").font(.caption).foregroundStyle(session.question.count > ChangeQuestionSnapshot.questionLimit ? .red : .secondary)
                }
            }
            if let error = session.error ?? problem {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("New snapshot") { Task { await store.openChangeQuestion(refresh: true) } }.disabled(session.loading || session.working)
                Spacer()
                if session.working {
                    ProgressView().controlSize(.small)
                    Button("Stop waiting") { session.stop() }
                }
                Button("Close") { dismiss() }
                Button("Send question") { store.sendChangeQuestion() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.loading || session.working || session.snapshot == nil || session.question.trimmed.isEmpty || session.question.count > ChangeQuestionSnapshot.questionLimit || problem != nil)
            }
        }.padding(20)
    }
}
