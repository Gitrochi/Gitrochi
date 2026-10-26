import SwiftUI
import AppKit

/// An issue on the Issues page, laid out like the pull request detail: title, details, Markdown description,
/// the conversation and a reply box. (Windows: widgets/inspector/ui/IssueDetail.tsx)
struct IssueDetailView: View {
    @Environment(RepoStore.self) private var store
    let detail: CollaborationInboxDetail
    @ViewState private var draft = ""

    private var item: CollaborationInboxItem { detail.item }
    private var isOpen: Bool { ["open", "opened"].contains(item.state) }
    private var busy: Bool { store.collaboration.inboxBusy || store.collaboration.inboxLoading }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "circle.dotted" : "checkmark.circle").foregroundStyle(isOpen ? Color.green : Color.secondary)
                Text("Issue #\(item.number)").font(.headline)
                Spacer()
                if store.collaboration.inboxLoading { ProgressView().controlSize(.small) }
                Button { Task { await store.openInboxItem(item) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh conversation")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            InspectorScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow { Text("Author").foregroundStyle(.secondary); Text(verbatim: "@\(item.author)") }
                        GridRow { Text("State").foregroundStyle(.secondary); Text(verbatim: WorkState.title(item.state)) }
                    }
                    .font(.callout)
                    HStack {
                        Button {
                            store.sheet = .issueEditor(number: item.number, title: item.title, body: item.body)
                        } label: { Label("Edit issue", systemImage: "pencil") }
                        Button { store.confirmIssueState(item) } label: {
                            Label(isOpen ? String(localized: "Close issue…") : String(localized: "Reopen…"),
                                  systemImage: isOpen ? "checkmark.circle" : "arrow.uturn.backward.circle")
                        }
                        Button { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } } label: {
                            Label("Browser", systemImage: "safari")
                        }
                    }
                    .disabled(busy)
                    Divider()
                    if item.body.trimmed.isEmpty {
                        Text("No description").foregroundStyle(.secondary)
                    } else {
                        MarkdownView(item.body, target: store.target)
                    }
                    if let error = store.collaboration.inboxError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    conversation
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(item.id)
            Divider()
            composer
        }
        .onChange(of: item.id) { _, _ in draft = "" }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation \(detail.comments.count)").font(.subheadline.weight(.semibold))
            ForEach(detail.comments) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "@\(c.author)").font(.callout.weight(.semibold))
                    if !c.body.isEmpty { MarkdownView(c.body, target: store.target).font(.callout) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
            if detail.more {
                Button("Load more comments") { Task { await store.openInboxItem(item, append: true) } }.disabled(busy)
            }
        }
    }

    private var composer: some View {
        let text = draft.trimmed
        return VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.callout)
                .disabled(store.collaboration.inboxBusy)
                .frame(height: 56)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Write a comment (Markdown)").font(.callout).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Comment")
            HStack(spacing: 6) {
                if store.collaboration.inboxBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Comment") {
                    let sent = draft
                    Task {
                        if await store.inboxAction(item, action: "comment", body: sent),
                           store.collaboration.inboxDetail?.item.id == item.id, draft == sent {
                            draft = ""
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty || busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
    }
}
