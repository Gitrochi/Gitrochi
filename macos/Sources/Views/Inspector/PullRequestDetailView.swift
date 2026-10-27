import SwiftUI
import AppKit

/// 오른쪽: PR·MR 상세 — 설명, CI, 승인 상태와 승인·변경 요청, 바뀐 파일(누르면 가운데 diff), 대화와 댓글 쓰기
struct PullRequestDetailView: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    @ViewState private var draft = ""
    @ViewState private var tab = "conversation"

    private var reviewContext: String { "\(store.collaboration.contextID):\(store.hostingAccount?.id ?? ""):\(number)" }

    var body: some View {
        if let pr = store.pullRequests.first(where: { $0.number == number }), let t = store.target {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Label("\(t.provider.requestShort) #\(pr.number)", systemImage: "arrow.triangle.pull")
                            .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        if pr.isDraft {
                            Text("Draft").font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                        if store.reviewLoading { ProgressView().controlSize(.small) }
                        Button { Task { await store.loadReview(number); await store.loadRequestLifecycle(number) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Refresh conversation and approvals").accessibilityLabel("Refresh conversation and approvals")
                    }
                    Text(pr.title).font(.title2.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    info(pr)
                    actions(pr)
                }.padding(20)
                WorkbenchFlow(spacing: 6) {
                    tabButton("conversation", title: String(localized: "Conversation"), symbol: "bubble.left.and.bubble.right", count: store.review?.number == number ? store.review?.comments.filter { $0.kind != .system }.count : nil)
                    tabButton("files", title: String(localized: "Changed files"), symbol: "doc.on.doc", count: store.review?.number == number ? store.review?.files.count : nil)
                    tabButton("checks", title: String(localized: "Checks"), symbol: "checkmark.circle", count: nil)
                }.padding(.horizontal, 16).padding(.bottom, 10)
                Divider()
                InspectorScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let e = store.reviewError {
                            Label(e, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if tab == "conversation" {
                            Card {
                                Text("Description").font(.subheadline.weight(.semibold))
                                if pr.body.trimmed.isEmpty { Text("No description").foregroundStyle(.secondary) }
                                else { MarkdownView(pr.body, target: t, revision: pr.headSHA ?? pr.source, baseURL: URL(string: pr.url)) }
                            }
                            if let r = store.review, r.number == number {
                                Card { approval(r.state, provider: t.provider) }
                                ReviewDraftPanel(number: number)
                                conversation(r, revision: pr.headSHA ?? pr.source, baseURL: URL(string: pr.url))
                            }
                        } else if tab == "files" {
                            if let r = store.review, r.number == number {
                                Card { files(r) }
                                ReviewDraftPanel(number: number)
                            } else if store.reviewLoading { ProgressView().padding(20) }
                        } else {
                            if let sha = pr.headSHA, !sha.isEmpty { RequestChecksPanel(number: number, headSHA: sha) }
                            RequestLifecyclePanel(number: number)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(number)
                Divider()
                composer(t.provider)
            }
            .task(id: reviewContext) { await store.loadReview(number) }
            .onChange(of: number) { _, _ in draft = ""; tab = "conversation" }
        } else {
            ContentUnavailableView("\(store.target?.provider.requestShort ?? "PR") not in the list", systemImage: "arrow.triangle.pull",
                                   description: Text("It was closed or hasn't been loaded yet."))
        }
    }

    private func tabButton(_ value: String, title: String, symbol: String, count: Int?) -> some View {
        Button { tab = value } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                if let count { Text("\(count)").font(.caption2.monospacedDigit()).padding(.horizontal, 5).background(Color.secondary.opacity(0.12), in: Capsule()) }
            }.font(.system(size: 12, weight: tab == value ? .semibold : .medium))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundStyle(tab == value ? Color.accentColor : .secondary)
                .background(tab == value ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private func info(_ pr: PullRequest) -> some View {
        WorkbenchFlow(spacing: 10) {
            Label("@\(pr.author)", systemImage: "person.crop.circle").font(.callout)
            Text("\(pr.source) → \(pr.target)\(pr.fromFork ? String(localized: "  (fork)") : "")")
                .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            if let d = pr.updated { Text(Fmt.long(d)).font(.caption) }
            if let sha = pr.headSHA, let ci = store.ciBySha[sha] {
                Button { tab = "checks" } label: { HStack(spacing: 4) { CIStatusIcon(status: ci.status, size: 11); Text(ci.status.title).font(.caption) } }.buttonStyle(.plain).help("Checks")
            }
        }.foregroundStyle(.secondary)
    }

    private func actions(_ pr: PullRequest) -> some View {
        WorkbenchFlow(spacing: 8) {
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
    private func conversation(_ r: PullRequestReview, revision: String?, baseURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation \(r.comments.filter { $0.kind != .system }.count)").font(.subheadline.weight(.semibold))
            if r.comments.isEmpty { Text("No comments yet.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8) }
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
                        if !c.body.isEmpty { MarkdownView(c.body, target: store.target, revision: revision, baseURL: baseURL).font(.callout) }
                        ReviewThreadActions(number: number, comment: c)
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
        let pending = store.reviewDraftsFor(number)
        let canSubmit = !text.isEmpty || !pending.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.callout)
                .disabled(store.reviewBusy)
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
            WorkbenchFlow(spacing: 8) {
                if store.reviewBusy { ProgressView().controlSize(.small) }
                if provider == .github {
                    Button("Request changes") { Task { if await store.requestChanges(number, body: text), store.selection == .pullRequest(number), draft.trimmed == text { draft = "" } } }
                        .disabled(text.isEmpty || store.reviewBusy)
                        .help("Request changes with a comment (comment required)")
                }
                if provider == .gitlab, s?.approvedByMe == true {
                    Button("Revoke approval") { Task { await store.unapprovePullRequest(number) } }
                        .disabled(store.reviewBusy)
                } else {
                    Button { Task { if await store.approvePullRequest(number, body: text), store.selection == .pullRequest(number), draft.trimmed == text { draft = "" } } } label: {
                        Label("Approve", systemImage: "checkmark.seal")
                    }
                    .disabled(store.reviewBusy || s?.approvedByMe == true)
                    .help(text.isEmpty ? "Approves this request" : "Approve with a comment")
                }
                Button(pending.isEmpty ? String(localized: "Comment") : String(localized: "Submit review")) { Task { if await store.postReviewComment(number, body: text), store.selection == .pullRequest(number), draft.trimmed == text { draft = "" } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit || store.reviewBusy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Comment (⌘↩)")
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

}
