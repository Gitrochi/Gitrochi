import SwiftUI

/// 커밋 준비는 넓은 diff 아래에 고정해 파일 선택·스테이지 후 바로 이어 쓸 수 있게 한다.
struct CommitComposer: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var descriptionExpanded = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Commit").font(.system(size: 14, weight: .semibold))
                Text("\(store.status.staged.count) staged files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(StudioStyle.canvas, in: Capsule())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { Task { await store.generateCommitMessage() } } label: {
                    Label("AI message", systemImage: "sparkles")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(StudioStyle.accent)
                .disabled(store.status.staged.isEmpty || store.aiWorking != nil || store.busy != nil)
                .help("AI writes a message from the staged changes. (⌥⌘M)")
                Menu {
                    Button("Split into commits") { Task { await store.planSplit() } }
                        .disabled(store.splittableChanges.count < 2 || store.aiWorking != nil || !store.status.conflicted.isEmpty)
                    Divider()
                    Toggle("Amend previous commit", isOn: Binding(get: { store.amend }, set: { value in Task { await store.setAmend(value) } }))
                        .disabled(store.headHash == nil)
                } label: { Label("Options", systemImage: "ellipsis").labelStyle(.iconOnly) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Options")
                .help("Options")
                .fixedSize()
                .disabled(store.busy != nil)
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                TextField("Summary (required)", text: $store.summary)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityLabel("Commit summary")
                Text("\(store.summary.count)/72")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(store.summary.count > 72 ? Color.orange : Color.secondary)
                    .accessibilityLabel("Summary character count")
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: StudioStyle.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).strokeBorder(StudioStyle.border))
            DisclosureGroup("Description (optional)", isExpanded: $descriptionExpanded) {
                TextEditor(text: $store.message)
                    .font(.system(size: 13))
                    .frame(height: 56)
                    .padding(5)
                    .scrollContentBackground(.hidden)
                    .background(StudioStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius))
                    .accessibilityLabel("Commit description")
                    .overlay(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).strokeBorder(StudioStyle.border))
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            if store.amend {
                Label("Amend previous commit", systemImage: "arrow.uturn.backward")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let working = store.aiWorking {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(working) }.font(.caption)
            }
            if let notice = store.aiNotice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(alignment: .center, spacing: 10) {
                Text(store.commitGuidance)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { Task { await store.commit() } } label: {
                    Text(buttonTitle).padding(.horizontal, 8).frame(minHeight: 22)
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .tint(StudioStyle.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canCommit)
                .help(store.commitGuidance)
                .fixedSize()
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if let me = store.me {
                    Label { Text(verbatim: "\(me.name) · \(me.email)") } icon: { Image(systemName: "person.crop.circle") }
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help("\(me.name) <\(me.email)>")
                }
                GitchBar()
            }
        }
        .padding(12)
        .background(StudioStyle.canvas)
        .onAppear { descriptionExpanded = !store.message.isEmpty }
        .onChange(of: store.message) { _, message in if !message.isEmpty { descriptionExpanded = true } }
    }

    private var buttonTitle: String {
        if store.amend { return String(localized: "Amend commit") }
        if store.repoState == .merging { return String(localized: "Merge commit") }
        return String(localized: "Commit") + "  ⌘↩"
    }
}
