import SwiftUI

/// Server activity in its original order. Windows: RequestActivity.tsx.
struct RequestActivity: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    let review: PullRequestReview
    let revision: String?
    let baseURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Conversation \(review.comments.filter { $0.kind != .system }.count)")
                .font(.subheadline.weight(.semibold))
            if review.comments.isEmpty {
                Text("No comments yet.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(review.comments) { comment in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(comment)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tint(comment)).frame(width: 28, height: 28)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.16)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            WorkbenchFlow(spacing: 8) {
                                HStack(spacing: 6) {
                                    Avatar(name: comment.author, email: comment.author, size: 24)
                                    Text("@\(comment.author)").font(.callout.weight(.semibold))
                                }
                                if comment.kind == .approved { Label("Approve", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                                if comment.kind == .changesRequested { Label("Request changes", systemImage: "exclamationmark.bubble.fill").foregroundStyle(.orange) }
                                if let date = comment.date {
                                    Text(Fmt.short(date)).foregroundStyle(.secondary).help(Fmt.long(date))
                                }
                            }.font(.caption)
                            if let path = comment.path {
                                Text(path + (comment.line.map { ":\($0)" } ?? ""))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if !comment.body.isEmpty {
                                if comment.kind == .system { Text(comment.body).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                                else { MarkdownView(comment.body, target: store.target, revision: revision, baseURL: baseURL).font(.callout) }
                            }
                            if comment.kind != .system { ReviewThreadActions(number: number, comment: comment) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 22)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .background(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1).padding(.leading, 14)
            }
        }
    }

    private func symbol(_ comment: ReviewComment) -> String {
        switch comment.kind {
        case .system: return "circle.dotted"
        case .approved: return "checkmark"
        case .changesRequested: return "exclamationmark.bubble"
        case .comment: return "bubble.left"
        }
    }

    private func tint(_ comment: ReviewComment) -> Color {
        switch comment.kind {
        case .approved: return .green
        case .changesRequested: return .orange
        default: return .secondary
        }
    }
}
