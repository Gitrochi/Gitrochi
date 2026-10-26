import SwiftUI
import AppKit

/// 오른쪽: PR·MR 상세 — 설명, CI, 승인 상태와 승인·변경 요청, 바뀐 파일(누르면 가운데 diff), 대화와 댓글 쓰기
struct PullRequestDetailView: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    @ViewState private var draft = ""

    var body: some View {
        if let pr = store.pullRequests.first(where: { $0.number == number }), let t = store.target {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
                    Text("\(t.provider.requestShort) #\(pr.number)").font(.headline)
                    if pr.isDraft {
                        Text("Draft").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    Spacer()
                    if store.reviewLoading { ProgressView().controlSize(.small) }
                    Button { Task { await store.loadReview(number) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh conversation and approvals")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(pr.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        info(pr)
                        actions(pr)
                        Divider()
                        if pr.body.trimmed.isEmpty {
                            Text("No description").foregroundStyle(.secondary)
                        } else {
                            MarkdownView(pr.body, target: t)
                        }
                        if let e = store.reviewError {
                            Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let r = store.review, r.number == number {
                            approval(r.state, provider: t.provider)
                            files(r)
                            conversation(r)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(number)
                Divider()
                composer(t.provider)
            }
            .task(id: number) { draft = ""; await store.loadReview(number) }
        } else {
            ContentUnavailableView("\(store.target?.provider.requestShort ?? "PR") not in the list", systemImage: "arrow.triangle.pull",
                                   description: Text("It was closed or hasn't been loaded yet."))
        }
    }

    private func info(_ pr: PullRequest) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow { Text("Author").foregroundStyle(.secondary); Text("@\(pr.author)") }
            GridRow {
                Text("Branch").foregroundStyle(.secondary)
                Text("\(pr.source) → \(pr.target)\(pr.fromFork ? String(localized: "  (fork)") : "")")
            }
            if let d = pr.updated {
                GridRow { Text("Update").foregroundStyle(.secondary); Text(Fmt.long(d)) }
            }
            if let sha = pr.headSHA, let ci = store.ciBySha[sha] {
                GridRow {
                    Text("CI").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        CIStatusIcon(status: ci.status, size: 11)
                        Text("\(ci.status.title) · #\(ci.number)")
                        Button("Open") { if let u = URL(string: ci.url) { NSWorkspace.shared.open(u) } }.buttonStyle(.link)
                    }
                }
            }
        }
        .font(.callout)
    }

    private func actions(_ pr: PullRequest) -> some View {
        HStack {
            Button { Task { await store.checkoutPullRequest(pr) } } label: {
                Label("Check out branch", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            Button { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } } label: {
                Label("Browser", systemImage: "safari")
            }
            if let sha = pr.headSHA, store.commitIndex[sha] != nil {
                Button { store.reveal(sha) } label: { Label("Show in graph", systemImage: "point.3.connected.trianglepath.dotted") }
            }
        }
    }

    /// 승인 상태
    private func approval(_ s: ReviewState, provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review").font(.subheadline.weight(.semibold))
            if s.approvedBy.isEmpty && s.changesRequestedBy.isEmpty {
                Text("No one has approved yet.").font(.callout).foregroundStyle(.secondary)
            }
            if !s.approvedBy.isEmpty {
                Label(String(localized: "Approved: ") + s.approvedBy.map { "@\($0)" }.joined(separator: ", "), systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            if !s.changesRequestedBy.isEmpty {
                Label(String(localized: "Changes requested: ") + s.changesRequestedBy.map { "@\($0)" }.joined(separator: ", "), systemImage: "exclamationmark.bubble.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let left = s.approvalsLeft, left > 0 {
                Text("\(left) more approvals needed.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 바뀐 파일(누르면 가운데에 diff)
    private func files(_ r: PullRequestReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changed files \(r.files.count)").font(.subheadline.weight(.semibold))
            ForEach(r.files) { f in
                HStack(spacing: 6) {
                    StatusBadge(kind: f.kind)
                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                    Text((f.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    LineStatText(added: f.additions, deleted: f.deletions)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(isOpen(f) ? Color.accentColor.opacity(0.18) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { store.openReviewFile(r.number, f) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { store.openReviewFile(r.number, f) }
                .help(f.patch == nil ? "Binary or too large — view it in the browser" : "Click to see the diff in the center")
            }
        }
    }

    private func isOpen(_ f: ReviewFile) -> Bool {
        if case .review(let n, let c, _)? = store.diffSource { return n == number && c.path == f.path }
        return false
    }

    /// 대화(일반 댓글·코드 줄 댓글·리뷰·시스템 기록)
    private func conversation(_ r: PullRequestReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation \(r.comments.filter { $0.kind != .system }.count)").font(.subheadline.weight(.semibold))
            ForEach(r.comments) { c in
                if c.kind == .system {
                    Text("@\(c.author) \(c.body)").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("@\(c.author)").font(.callout.weight(.semibold))
                            switch c.kind {
                            case .approved: Label("Approve", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                            case .changesRequested: Label("Request changes", systemImage: "exclamationmark.bubble.fill").font(.caption).foregroundStyle(.orange)
                            default: EmptyView()
                            }
                            Spacer()
                            if let d = c.date { Text(Fmt.short(d)).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let path = c.path {
                            Text(path + (c.line.map { ":\($0)" } ?? ""))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if !c.body.isEmpty {
                            MarkdownView(c.body, target: store.target)
                                .font(.callout)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
    }

    /// 아래: 댓글 쓰기 · 승인 · 변경 요청
    private func composer(_ provider: Provider) -> some View {
        let s = store.review?.number == number ? store.review?.state : nil
        let text = draft.trimmed
        return VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.callout)
                .frame(height: 56)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Comment · review feedback").font(.callout).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 6) {
                if store.reviewBusy { ProgressView().controlSize(.small) }
                Spacer()
                if provider == .github {
                    Button("Request changes") { Task { if await store.requestChanges(number, body: text) { draft = "" } } }
                        .disabled(text.isEmpty || store.reviewBusy)
                        .help("Request changes with a comment (comment required)")
                }
                if provider == .gitlab, s?.approvedByMe == true {
                    Button("Revoke approval") { Task { await store.unapprovePullRequest(number) } }
                        .disabled(store.reviewBusy)
                } else {
                    Button { Task { if await store.approvePullRequest(number, body: text) { draft = "" } } } label: {
                        Label("Approve", systemImage: "checkmark.seal")
                    }
                    .disabled(store.reviewBusy || s?.approvedByMe == true)
                    .help(text.isEmpty ? "Approves this request" : "Approve with a comment")
                }
                Button("Comment") { Task { if await store.postReviewComment(number, body: text) { draft = "" } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty || store.reviewBusy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Comment (⌘↩)")
            }
            .controlSize(.small)
        }
        .padding(10)
    }
}
