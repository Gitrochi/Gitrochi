import SwiftUI

/// 커밋 준비는 넓은 diff 아래에 고정해 파일 선택·스테이지 후 바로 이어 쓸 수 있게 한다.
struct CommitComposer: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var descriptionExpanded = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Commit").font(.headline)
                Text("\(store.status.staged.count) staged files")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { Task { await store.generateCommitMessage() } } label: {
                    Label("AI message", systemImage: "sparkles")
                }
                .disabled(store.status.staged.isEmpty || store.aiWorking != nil || store.busy != nil)
                .help("AI writes a message from the staged changes. (⌥⌘M)")
                Menu {
                    Button("Split into commits") { Task { await store.planSplit() } }
                        .disabled(store.splittableChanges.count < 2 || store.aiWorking != nil || !store.status.conflicted.isEmpty)
                    Divider()
                    Toggle("Amend previous commit", isOn: Binding(get: { store.amend }, set: { value in Task { await store.setAmend(value) } }))
                        .disabled(store.headHash == nil)
                } label: { Label("Options", systemImage: "ellipsis") }
                .fixedSize()
                .disabled(store.busy != nil)
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                TextField("Summary (required)", text: $store.summary)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .accessibilityLabel("Commit summary")
                Text("\(store.summary.count)/72")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(store.summary.count > 72 ? Color.orange : Color.secondary)
                    .accessibilityLabel("Summary character count")
            }
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            DisclosureGroup("Description (optional)", isExpanded: $descriptionExpanded) {
                TextEditor(text: $store.message)
                    .font(.callout)
                    .frame(height: 56)
                    .accessibilityLabel("Commit description")
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
            }
            .font(.callout).foregroundStyle(.secondary)
            if store.amend {
                Label("Amend previous commit", systemImage: "arrow.uturn.backward")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let working = store.aiWorking {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(working) }.font(.caption)
            }
            if let notice = store.aiNotice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(alignment: .center, spacing: 12) {
                Text(store.commitGuidance)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { Task { await store.commit() } } label: {
                    Text(buttonTitle).padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canCommit)
                .help(store.commitGuidance)
                .fixedSize()
            }
            Divider()
            if let me = store.me {
                Label { Text(verbatim: "\(me.name) · \(me.email)") } icon: { Image(systemName: "person.crop.circle") }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("\(me.name) <\(me.email)>")
            }
            GitchBar()
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { descriptionExpanded = !store.message.isEmpty }
        .onChange(of: store.message) { _, message in if !message.isEmpty { descriptionExpanded = true } }
    }

    private var buttonTitle: String {
        if store.amend { return String(localized: "Amend commit") }
        if store.repoState == .merging { return String(localized: "Merge commit") }
        return String(localized: "Commit") + "  ⌘↩"
    }
}
