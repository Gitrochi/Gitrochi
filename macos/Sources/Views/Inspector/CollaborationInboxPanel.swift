import SwiftUI
import AppKit

struct CollaborationInboxPanel: View {
    @Environment(RepoStore.self) private var store
    var initialKind: String? = nil
    var embedded = false
    @ViewState private var draft = ""
    private var state: CollaborationState { store.collaboration }
    private var disabled: Bool { state.inboxBusy || state.inboxLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Issues and mentions").font(.headline)
                Spacer()
                if disabled { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await store.loadInbox() } }.disabled(disabled)
            }
            if let target = store.target { Text("\(target.host)/\(target.path) · @\(store.hostingAccount?.username ?? "")").font(.caption).foregroundStyle(.secondary) }
            HStack {
                ForEach(["issue", "review", "mention"], id: \.self) { kind in
                    Button {
                        Task { await store.loadInbox(kind: kind) }
                    } label: { Text(kind == "issue" ? String(localized: "Assigned issues") : kind == "review" ? String(localized: "Review requested") : String(localized: "Mentions")) }
                    .tint(state.inboxKind == kind ? .accentColor : .secondary)
                }
            }.disabled(disabled)
            if let error = state.inboxError { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.inbox) { item in
                            Button { Task { await store.openInboxItem(item) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(item.unread ? "● " : "")#\(item.number) \(item.title)").font(.callout.weight(.medium))
                                    Text("\(item.author.isEmpty ? "" : "@" + item.author + " · ")\(item.state)").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(state.inboxDetail?.item.id == item.id ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
                            }.buttonStyle(.plain)
                        }
                        if state.inbox.isEmpty, !state.inboxLoading { Text("No items in this page.").foregroundStyle(.secondary) }
                        if state.inboxMore { Button("Load more") { Task { await store.loadInbox(append: true) } }.disabled(disabled) }
                    }.padding(6)
                }.frame(minWidth: 190, idealWidth: 260, maxWidth: 340)
                ScrollView {
                    if let detail = state.inboxDetail { detailView(detail).padding(10) }
                    else { Text("Select an item to read its conversation.").foregroundStyle(.secondary).padding(16) }
                }.frame(minWidth: 290, maxWidth: .infinity)
            }.frame(minHeight: 300, idealHeight: 460, maxHeight: embedded ? .infinity : 600)
            Text("Only the selected repository and connected account are queried.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: embedded ? 300 : 720, idealWidth: 920, maxWidth: .infinity, maxHeight: embedded ? .infinity : nil)
        .task(id: "\(store.url?.path ?? "")|\(store.collaboration.contextID)|\(AccountStore.shared.revision)") { await store.loadInbox(kind: initialKind) }
        .onChange(of: state.inboxDetail?.item.id) { _, _ in draft = "" }
    }
    private func detailView(_ detail: CollaborationInboxDetail) -> some View {
        let item = detail.item
        return VStack(alignment: .leading, spacing: 9) {
            Text("#\(item.number) \(item.title)").font(.headline).textSelection(.enabled)
            HStack {
                Text(item.state).font(.caption).foregroundStyle(.secondary)
                Button("Browser") { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
                if item.unread, item.readID != nil { Button("Mark as read") { Task { _ = await store.inboxAction(item, action: "read") } }.disabled(disabled) }
                if item.kind == "issue" { Button(["open", "opened"].contains(item.state) ? String(localized: "Close issue…") : String(localized: "Reopen…")) { store.confirmIssueState(item) }.disabled(disabled) }
            }.controlSize(.small)
            Text(item.body.isEmpty ? String(localized: "No description") : item.body).textSelection(.enabled)
            ForEach(detail.comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(comment.author)").font(.callout.weight(.semibold))
                    Text(comment.body).font(.callout).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.08)))
            }
            if detail.more { Button("Load more comments") { Task { await store.openInboxItem(item, append: true) } }.disabled(disabled) }
            TextEditor(text: $draft).font(.callout).frame(height: 70).disabled(disabled).accessibilityLabel("Comment")
            Button("Comment") {
                let sent = draft
                Task { if await store.inboxAction(item, action: "comment", body: sent), state.inboxDetail?.item.id == item.id, draft == sent { draft = "" } }
            }.buttonStyle(.borderedProminent).disabled(disabled || draft.trimmed.isEmpty)
        }
    }
}
