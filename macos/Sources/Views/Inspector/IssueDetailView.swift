import SwiftUI
import AppKit

/// An issue conversation keeps Markdown drafts and development handoffs together.
struct IssueDetailView: View {
    @Environment(RepoStore.self) private var store
    let detail: CollaborationInboxDetail
    @ViewState private var draft = ""
    @ViewState private var preview = false
    @ViewState private var editing: String?
    @ViewState private var editText = ""
    @FocusState private var composerFocused: Bool
    private var item: CollaborationInboxItem { detail.item }
    private var isOpen: Bool { ["open", "opened"].contains(item.state) }
    private var busy: Bool { store.collaboration.inboxBusy || store.collaboration.inboxLoading }
    private var context: String { [store.url?.path ?? "", store.target?.host ?? "", store.target?.path ?? "", store.hostingAccount?.id ?? "", item.id].joined(separator: "|") }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: isOpen ? "circle.dotted" : "checkmark.circle").foregroundStyle(isOpen ? Color.green : Color.secondary)
                Text("Issue #\(item.number)").font(.headline)
                Spacer()
                if store.collaboration.inboxLoading { ProgressView().controlSize(.small) }
                Button { Task { await store.openInboxItem(item) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh conversation").accessibilityLabel("Refresh conversation")
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            InspectorScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(WorkState.title(item.state)).font(.caption).foregroundStyle(isOpen ? Color.green : Color.secondary).padding(.horizontal, 10).padding(.vertical, 4).background((isOpen ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
                    Text(item.title).font(.system(size: 22, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    WorkbenchFlow(spacing: 8) { Avatar(name: item.author, email: item.author, size: 26); Text(verbatim: "@\(item.author)").font(.callout.weight(.medium)); if let date = item.createdAt ?? item.updatedAt { HostingDate(value: date, label: item.createdAt != nil ? "Opened {0}" : "Updated {0}") } else { Text("Author").font(.caption).foregroundStyle(.secondary) } }
                    WorkbenchFlow {
                        Button { store.sheet = .issueEditor(number: item.number, title: item.title, body: item.body) } label: { Label("Edit issue", systemImage: "pencil") }
                        Button { store.confirmIssueState(item) } label: { Label(isOpen ? String(localized: "Close issue…") : String(localized: "Reopen…"), systemImage: isOpen ? "checkmark.circle" : "arrow.uturn.backward.circle") }
                        Button { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } } label: { Label("Browser", systemImage: "arrow.up.right.square") }
                    }.disabled(busy)
                    Divider()
                    if item.body.trimmed.isEmpty { Text("No description").foregroundStyle(.secondary) }
                    else { MarkdownView(item.body, target: store.target).font(.callout) }
                    IssueDevelopmentPanel(item: item)
                    if let error = store.collaboration.inboxError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    conversation
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.id(context)
            Divider()
            composer
        }
        .onChange(of: context) { _, _ in draft = ""; preview = false; editing = nil; editText = "" }
    }
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Conversation", systemImage: "bubble.left.and.bubble.right").font(.subheadline.weight(.semibold)); Spacer(); Text(String(detail.comments.count)).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
            if detail.comments.isEmpty && !store.collaboration.inboxLoading { Text("No comments yet. Start the conversation.").font(.caption).foregroundStyle(.secondary) }
            ForEach(detail.comments) { comment in
                VStack(alignment: .leading, spacing: 12) {
                    WorkbenchFlow(spacing: 8) { Avatar(name: comment.author, email: comment.author, size: 26); Text(verbatim: "@\(comment.author)").font(.callout.weight(.semibold)); if comment.createdAt != nil { HostingDate(value: comment.createdAt) } }
                    Divider()
                    if editing == comment.id {
                        TextEditor(text: $editText).font(.callout).frame(minHeight: 100).accessibilityLabel("Edit comment").disabled(busy)
                        HStack {
                            Button("Save comment") { let value = editText; Task { if await store.changeIssueComment(item, comment: comment, body: value) { editing = nil } } }.disabled(busy || editText.trimmed.isEmpty)
                            Button("Cancel") { editing = nil }.disabled(busy)
                        }
                    } else { MarkdownView(comment.body, target: store.target).font(.callout) }
                    WorkbenchFlow {
                        Button { draft += (draft.isEmpty ? "" : "\n\n") + IssueWorkflow.quote(author: comment.author, body: comment.body); preview = false; composerFocused = true } label: { Label("Quote reply", systemImage: "text.quote") }.disabled(busy)
                        if comment.editable {
                            Button("Edit") { editing = comment.id; editText = comment.body }.disabled(busy || editing != nil)
                            Button("Delete", role: .destructive) { store.confirmDeleteIssueComment(item, comment: comment) }.disabled(busy)
                        }
                    }.controlSize(.small)
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.secondary.opacity(0.18)))
            }
            if detail.more { Button("Load more comments") { Task { await store.openInboxItem(item, append: true) } }.disabled(busy) }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Comment", selection: $preview) { Text("Write").tag(false); Text("Preview").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 210)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft).font(.callout).focused($composerFocused).disabled(store.collaboration.inboxBusy).frame(height: 92).scrollContentBackground(.hidden).padding(5).opacity(preview ? 0 : 1).allowsHitTesting(!preview).accessibilityHidden(preview).accessibilityLabel("Comment")
                if preview {
                    ScrollView { if draft.trimmed.isEmpty { Text("Nothing to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) } else { MarkdownView(draft, target: store.target).font(.callout) } }.frame(height: 92).padding(5)
                } else if draft.isEmpty { Text("Write a comment (Markdown)").font(.callout).foregroundStyle(.tertiary).padding(9).allowsHitTesting(false) }
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22)))
            HStack {
                if store.collaboration.inboxBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Comment") { send() }.buttonStyle(.borderedProminent).disabled(draft.trimmed.isEmpty || busy).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(14)
    }
    private func send() {
        let sent = draft, id = item.id
        guard !sent.trimmed.isEmpty, !busy else { return }
        Task { if await store.inboxAction(item, action: "comment", body: sent), store.collaboration.inboxDetail?.item.id == id, draft == sent { draft = ""; preview = false } }
    }
}
