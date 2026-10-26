import SwiftUI

struct ReviewDraftPanel: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    @FocusState private var focusedDraft: String?
    var body: some View {
        let drafts = store.reviewDraftsFor(number)
        let review = store.review?.number == number ? store.review : nil
        VStack(alignment: .leading, spacing: 8) {
            ForEach(review?.warnings ?? [], id: \.self) { warning in Text(warning).font(.caption).foregroundStyle(.orange) }
            Text("Use the comment button beside a diff line to add it to your review. Drafts stay on this device until submitted.")
                .font(.caption).foregroundStyle(.secondary)
            if !drafts.isEmpty {
                Text("Pending line comments (\(drafts.count))").font(.subheadline.weight(.semibold))
                if store.target?.provider == .gitlab {
                    Text("GitLab publishes threads one at a time; approval is a separate action.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(drafts) { draft in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.bubble").font(.caption)
                            Text("\(draft.anchor.path):\(draft.anchor.line)").font(.caption.monospaced()).lineLimit(2)
                            Text(draft.anchor.side == .left ? String(localized: "Old version") : String(localized: "New version")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { store.removeReviewDraft(draft.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Remove draft").disabled(store.reviewBusy)
                        }
                        if let review, draft.anchor.refs != review.refs {
                            Text("This comment belongs to an older diff. Copy its text, remove it and select a line in the refreshed diff.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        TextEditor(text: Binding(get: { store.reviewDrafts.first(where: { $0.id == draft.id })?.body ?? "" }, set: { store.updateReviewDraft(draft.id, body: $0) }))
                            .font(.callout).frame(height: 60).disabled(store.reviewBusy)
                            .accessibilityLabel("Line comment")
                            .focused($focusedDraft, equals: draft.id)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
        .onChange(of: drafts.map(\.id)) { previous, current in
            if let added = current.first(where: { !previous.contains($0) }) { focusedDraft = added }
        }
    }
}

struct ReviewThreadActions: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    let comment: ReviewComment
    @ViewState private var replying = false
    @ViewState private var bodyText = ""
    var body: some View {
        if comment.threadID != nil, comment.kind == .comment {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button("Reply") { replying.toggle() }
                    if comment.resolvable {
                        Button(comment.resolved ? String(localized: "Reopen thread") : String(localized: "Resolve thread")) {
                            Task { await store.resolveReviewThread(number, comment: comment) }
                        }
                    }
                    if comment.resolved { Text("Resolved").font(.caption).foregroundStyle(.secondary) }
                }
                .controlSize(.small).disabled(store.reviewBusy)
                if replying {
                    TextEditor(text: $bodyText).font(.callout).frame(height: 55).accessibilityLabel("Reply").disabled(store.reviewBusy)
                    Button("Send reply") {
                        Task { if await store.replyReviewComment(number, comment: comment, body: bodyText) { bodyText = ""; replying = false } }
                    }.disabled(store.reviewBusy || bodyText.trimmed.isEmpty).controlSize(.small)
                }
            }
        }
    }
}
