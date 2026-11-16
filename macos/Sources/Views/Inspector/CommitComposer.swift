import SwiftUI

/// The commit form under the working changes, as the redesign board draws it: who commits, one 28 pt Summary field
/// with its count out of 72, the description folded away until it is wanted, "AI message" as a text button and the
/// one filled Commit. (Windows: CommitComposer in widgets/inspector/ui/Inspector.tsx)
struct CommitComposer: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var descriptionExpanded = false
    @FocusState private var focus: Field?

    private enum Field { case summary, description }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            if let me = store.me {
                HStack(spacing: 6) {
                    AuthorAvatar(name: me.name, email: me.email, size: 20)
                    Text(verbatim: me.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    // the email gives way first: the name says who commits
                    Text(verbatim: "· \(me.email)").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .lineLimit(1).truncationMode(.tail)
                }
                .help("\(me.name) <\(me.email)>")
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                TextField("Summary", text: $store.summary)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focus, equals: .summary)
                    .accessibilityLabel("Commit summary")
                Text(verbatim: "\(store.summary.count)/72")
                    .font(.system(size: 11, design: .monospaced))
                    // past 72 the count is in the waiting tone, never the accent
                    .foregroundStyle(store.summary.count > 72 ? StudioStyle.Tone.waiting.text : HostedList.caption)
                    .fixedSize()
                    .accessibilityLabel("Summary character count")
                    .accessibilityValue(Text(verbatim: "\(store.summary.count)/72"))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .field(focused: focus == .summary)
            Button { descriptionExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    SymbolIcon(descriptionExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Text("Description (optional)").font(.system(size: 12))
                }
                .foregroundStyle(HostedList.caption)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(descriptionExpanded ? "On" : "Off")
            if descriptionExpanded {
                TextEditor(text: $store.message)
                    .font(.system(size: 13))
                    .frame(height: 56)
                    .padding(5)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .description)
                    .accessibilityLabel("Commit description")
                    .field(focused: focus == .description)
            }
            if let working = store.aiWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: working).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if let failure = store.commitMessageFailure {
                FailureBlock(title: String(localized: "Couldn't write the commit message"), caption: failure) {
                    Task { await store.generateCommitMessage() }
                }
            }
            if let notice = store.aiNotice {
                Text(verbatim: notice).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // the reason sits beside a disabled Commit, and under the row when the panel is too narrow for that
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    aiButton
                    Spacer(minLength: 0)
                    commitButton.disabledReason(reason)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        aiButton
                        Spacer(minLength: 0)
                        commitButton.disabled(reason != nil)
                    }
                    if let reason {
                        Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
        .background(StudioStyle.FileList.composer)
        .onAppear { descriptionExpanded = !store.message.isEmpty }
        .onChange(of: store.message) { _, message in if !message.isEmpty { descriptionExpanded = true } }
    }

    private var aiButton: some View {
        Button { Task { await store.generateCommitMessage() } } label: {
            HStack(spacing: 6) {
                SymbolIcon("sparkles").font(.system(size: 13))
                Text("AI message")
            }
        }
        .buttonStyle(HostedListTextButtonStyle())
        .fixedSize()
        .disabled(store.status.staged.isEmpty || store.aiWorking != nil || store.busy != nil)
        .help("AI writes a message from the staged changes. (⌥⌘M)")
    }

    /// The region's one filled button, with its shortcut beside the words. While a merge or a rebase is in progress
    /// the banner's Continue is the filled one and this is plain.
    @ViewBuilder private var commitButton: some View {
        let button = Button { Task { await store.commit() } } label: {
            HStack(spacing: 6) {
                Text(verbatim: title)
                Text(verbatim: "⌘↩").font(.system(size: 12)).opacity(0.8)
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .fixedSize()
        if store.repoState == .clean {
            button.hostedListFilledButton()
        } else {
            button.buttonStyle(HostedListButtonStyle())
        }
    }

    /// Why Commit can't be used now; nil when it can
    private var reason: String? { store.canCommit ? nil : store.commitGuidance }

    private var title: String {
        // Amend previous commit is in the toolbar's ⋯; while it is on, the button says what it does
        if store.amend { return String(localized: "Amend commit") }
        if store.repoState == .merging { return String(localized: "Merge commit") }
        let count = store.status.staged.count
        if count == 0 { return String(localized: "Commit") }
        return count == 1 ? String(localized: "Commit 1 file") : String(localized: "Commit \(count) files")
    }
}

private extension View {
    /// A field of the composer: white with a hairline and a 6 pt radius, and the 2 pt accent ring while it has focus
    func field(focused: Bool) -> some View {
        background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.FileList.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(focused ? 0.4 : 0), lineWidth: 2))
    }
}
