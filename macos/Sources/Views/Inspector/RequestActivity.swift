import SwiftUI

/// A request's activity in the server's order: verdicts and system events as one-line rows, comments on a file as a
/// thread card that names the file and line, other comments as they are. Windows: RequestActivity.tsx.
struct RequestActivity: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    let review: PullRequestReview
    /// The request's author, who gets the "Author" pill on their comments
    let author: String
    let revision: String?
    let baseURL: URL?
    /// Opens a commented file on Changed files
    let openFile: (String) -> Void

    private enum Item: Identifiable {
        case event(ReviewComment)
        case comment(ReviewComment)
        case thread(id: String, comments: [ReviewComment])

        var id: String {
            switch self {
            case .event(let c), .comment(let c): return c.id
            case .thread(let id, _): return "thread:" + id
            }
        }
    }

    /// Replies join the thread card of the first comment on their line
    private var items: [Item] {
        var result: [Item] = [], threads: [String: Int] = [:]
        for comment in review.comments {
            if comment.kind != .comment { result.append(.event(comment)); continue }
            guard comment.path != nil else { result.append(.comment(comment)); continue }
            let key = comment.threadID ?? comment.id
            if let index = threads[key], case .thread(let id, let comments) = result[index] {
                result[index] = .thread(id: id, comments: comments + [comment])
            } else {
                threads[key] = result.count
                result.append(.thread(id: key, comments: [comment]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if review.comments.isEmpty { PullRequestCaption(String(localized: "No comments yet.")) }
            ForEach(items) { item in
                switch item {
                case .event(let comment): event(comment)
                case .comment(let comment):
                    VStack(alignment: .leading, spacing: 4) {
                        article(comment)
                        ReviewThreadActions(number: number, comment: comment).padding(.leading, 34)
                    }
                case .thread(_, let comments): thread(comments)
                }
            }
        }
        .font(.system(size: 13))
    }

    // MARK: Rows

    /// Approved, changes requested, or a system event: an icon, who and what, and when
    @ViewBuilder private func event(_ comment: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkbenchFlow(spacing: 10) {
                HStack(spacing: 10) {
                    switch comment.kind {
                    case .approved: Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioStyle.Tone.passed.text)
                    case .changesRequested: Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(StudioStyle.Tone.waiting.text)
                    default: Image(systemName: "circle.dotted").foregroundStyle(StudioStyle.Rail.icon)
                    }
                    switch comment.kind {
                    case .approved: Text("\(Text(verbatim: "@" + comment.author).fontWeight(.semibold).foregroundStyle(.primary)) approved these changes")
                    case .changesRequested: Text("\(Text(verbatim: "@" + comment.author).fontWeight(.semibold).foregroundStyle(.primary)) requested changes")
                    default: Text("\(Text(verbatim: "@" + comment.author).fontWeight(.semibold).foregroundStyle(.primary)) \(Text(verbatim: comment.body))")
                    }
                }
                .foregroundStyle(StudioStyle.Tone.neutral.text)
                if let date = comment.date { Text(PullRequestDate.short(date)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).help(Fmt.long(date)) }
            }
            // a verdict can carry a comment of its own
            if comment.kind != .system, !comment.body.isEmpty {
                MarkdownView(comment.body, target: store.target, revision: revision, baseURL: baseURL).padding(.leading, 26)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func article(_ comment: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: comment.author, email: comment.author, size: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: "@\(comment.author)").fontWeight(.semibold)
                    if let date = comment.date { Text(PullRequestDate.short(date)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).help(Fmt.long(date)) }
                    if comment.author == author { StatusPill(title: String(localized: "Author"), symbol: nil, tone: .neutral) }
                }
                if !comment.body.isEmpty { MarkdownView(comment.body, target: store.target, revision: revision, baseURL: baseURL) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func thread(_ comments: [ReviewComment]) -> some View {
        let first = comments[0], path = first.path ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                Button { openFile(path) } label: {
                    Text(verbatim: (path as NSString).lastPathComponent).fontWeight(.medium).foregroundStyle(StudioStyle.link).lineLimit(1)
                }
                .buttonStyle(.plain).help(path)
                if let line = first.line { Text(verbatim: "· " + String(localized: "line \(line)")).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon) }
                Spacer(minLength: 0)
                if first.resolved { StatusPill(title: String(localized: "Resolved"), symbol: "checkmark", tone: .neutral) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioStyle.canvas)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                ForEach(comments) { article($0) }
                // one Reply / Resolve for the thread, under its last comment
                ReviewThreadActions(number: number, comment: first).padding(.leading, 34)
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
    }
}
