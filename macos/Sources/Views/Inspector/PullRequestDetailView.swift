import SwiftUI
import AppKit

/// One request, as the redesign's boards draw it: the header with its actions, underline tabs, and the Conversation,
/// Changed files and Checks tabs. Changed files trades the tall header for one 44pt row. Windows: PullRequestDetailView.tsx.
struct PullRequestDetailView: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    /// The page's list column is showing; with it the Changed files header and file tree compact
    var listShown = true
    /// On the Pull requests page; the repository's inspector shows the same request in a narrow column
    var onPage = false
    @ViewState private var draft = ""
    @ViewState private var tab = "conversation"
    @ViewState private var reviewing = false
    @ViewState private var editing = false
    @ViewState private var checksBadge: PullRequestPage.ChecksBadge?
    @FocusState private var composing: Bool

    private var reviewContext: String { "\(store.collaboration.contextID):\(store.hostingAccount?.id ?? ""):\(number)" }
    private var review: PullRequestReview? { store.review?.number == number ? store.review : nil }
    private var lifecycle: RequestLifecycle? { store.collaboration.lifecycle?.number == number ? store.collaboration.lifecycle : nil }

    var body: some View {
        if let pr = store.pullRequests.first(where: { $0.number == number }), let t = store.target {
            GeometryReader { geometry in
                let width = geometry.size.width
                let compact = PullRequestPage.isCompact(listShown: listShown, width: width)
                VStack(spacing: 0) {
                    if PullRequestPage.headerInOneRow(onPage: onPage, tab: tab, width: width) { filesHeader(pr, t, compact: compact) } else { header(pr, t, wide: width >= 640) }
                    // every tab stays mounted: drafts, metadata edits and loaded checks survive a tab switch
                    ZStack(alignment: .topLeading) {
                        panel("conversation") { conversation(pr, t, wide: width >= 716) }
                        panel("files") { PullRequestFilesView(number: number, compact: compact, active: tab == "files", treeOnly: !onPage) }
                        panel("checks") { checks(pr) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(number)
                    if tab == "conversation" {
                        Divider()
                        composer(t.provider)
                    }
                }
            }
            .task(id: reviewContext) { await store.loadReview(number) }
            .onChange(of: number) { _, _ in draft = ""; tab = "conversation"; editing = false; reviewing = false; checksBadge = nil }
            // a file of this request is open (it was opened from the repository's inspector, or the page was left on it)
            .onAppear { if case .review(let open, _, _)? = store.diffSource, open == number { tab = "files" } }
            // the open file belongs to Changed files: no other tab or page should find it still open
            .onChange(of: tab) { old, _ in if old == "files", case .review? = store.diffSource { store.closeDiff() } }
        } else {
            ContentUnavailableView("\(store.target?.provider.requestShort ?? "PR") not in the list", symbol: "arrow.triangle.pull",
                                   description: Text("It was closed or hasn't been loaded yet."))
        }
    }

    private func panel<Content: View>(_ value: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(tab == value ? 1 : 0)
            .allowsHitTesting(tab == value).accessibilityHidden(tab != value)
    }

    // MARK: Header

    /// Conversation and Checks: number and state, the title with the actions, who and which branches, then the tabs
    private func header(_ pr: PullRequest, _ t: RepoTarget, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: "#\(pr.number)").font(.system(size: 13, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon)
                statusPill(pr)
                if store.reviewLoading { ProgressView().controlSize(.small) }
            }
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            layout {
                Text(pr.title).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    HStack(spacing: 6) { leadButton(pr); reviewButton(t); browserButton(pr); moreMenu(pr, t, navigation: false) }.fixedSize()
                } else {
                    WorkbenchFlow(spacing: 6) { leadButton(pr); reviewButton(t); browserButton(pr); moreMenu(pr, t, navigation: false) }
                }
            }
            WorkbenchFlow(spacing: 12) { meta(pr) }
            // tab labels are never cut: a column too narrow for the three scrolls them
            ScrollView(.horizontal) { tabs(compact: false) }.scrollIndicators(.hidden).padding(.top, 4)
        }
        .padding(.horizontal, 24).padding(.top, 20)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 24) }
    }

    /// Changed files: one 44pt row, so the diff gets the height. The title gives way first; the tabs never shrink.
    private func filesHeader(_ pr: PullRequest, _ t: RepoTarget, compact: Bool) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Text(verbatim: "#\(pr.number)").font(.system(size: 13, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon).fixedSize()
                Text(pr.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail).help(pr.title)
            }
            .frame(minWidth: 160, alignment: .leading)
            tabs(compact: true).fixedSize().layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                // with the list shown these two wait at the top of the More menu
                if !compact, let sha = graphCommit(pr) { graphButton(sha) }
                reviewButton(t)
                if !compact { browserButton(pr) }
                moreMenu(pr, t, navigation: compact)
            }
            .fixedSize().layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func statusPill(_ pr: PullRequest) -> some View {
        let scope = store.collaboration.query.scope
        let state = lifecycle?.state ?? (["closed", "merged"].contains(scope) ? scope : "open")
        if state == "merged" {
            StatusPill(title: WorkState.title(state), symbol: "arrow.triangle.merge", tone: .neutral)
        } else if state != "open" && state != "opened" {
            StatusPill(title: WorkState.title(state), symbol: "xmark.circle", tone: .neutral)
        } else if pr.isDraft {
            StatusPill(title: String(localized: "Draft"), symbol: "arrow.triangle.pull", tone: .waiting)
        } else {
            StatusPill(title: WorkState.title("open"), symbol: "arrow.triangle.pull", tone: .passed)
        }
    }

    private func ownBranch(_ pr: PullRequest) -> Bool { !pr.fromFork && pr.source == store.headBranch }
    private func graphCommit(_ pr: PullRequest) -> String? { pr.headSHA.flatMap { store.commitIndex[$0] != nil ? $0 : nil } }
    private func open(_ string: String) { if let url = URL(string: string) { NSWorkspace.shared.open(url) } }

    private func graphButton(_ sha: String) -> some View {
        Button { store.reveal(sha) } label: { Label("Show in graph", symbol: "point.3.connected.trianglepath.dotted") }
            .buttonStyle(PullRequestButtonStyle())
    }

    /// The checked-out branch's own request shows where it is in the graph; any other offers to check it out
    @ViewBuilder private func leadButton(_ pr: PullRequest) -> some View {
        if ownBranch(pr) {
            if let sha = graphCommit(pr) { graphButton(sha) }
        } else {
            Button { Task { await store.checkoutPullRequest(pr) } } label: { Label("Check out", symbol: "arrow.down.to.line") }
                .buttonStyle(PullRequestButtonStyle())
        }
    }

    private func reviewButton(_ t: RepoTarget) -> some View {
        Button { reviewing = true } label: { Label("Review…", symbol: "text.bubble") }
            .buttonStyle(PullRequestButtonStyle())
            .popover(isPresented: $reviewing, arrowEdge: .bottom) {
                PullRequestReviewForm(number: number, provider: t.provider, draft: $draft) { reviewing = false }
            }
    }

    private func browserButton(_ pr: PullRequest) -> some View {
        Button { open(pr.url) } label: { Label("Open in browser", symbol: "arrow.up.right.square") }
            .buttonStyle(PullRequestButtonStyle())
    }

    /// `navigation`: Show in graph and Open in browser left the row and lead the menu
    private func moreMenu(_ pr: PullRequest, _ t: RepoTarget, navigation: Bool) -> some View {
        let own = ownBranch(pr), busy = store.collaboration.lifecycleBusy || store.collaboration.lifecycleLoading
        return Menu {
            if navigation || !own, let sha = graphCommit(pr) {
                Button { store.reveal(sha) } label: { Label("Show in graph", symbol: "point.3.connected.trianglepath.dotted") }
            }
            if navigation { Button { open(pr.url) } label: { Label("Open in browser", symbol: "arrow.up.right.square") } }
            Divider()
            Button { store.copy(pr.url) } label: { Label("Copy link", symbol: "doc.on.doc") }
            Button { Task { await store.checkoutPullRequest(pr) } } label: {
                Text("Check out branch")
                // a disabled item says why
                if own { Text("Already checked out") }
            }
            .disabled(own)
            if let r = lifecycle {
                if r.canEdit { Button("Edit request…") { editing = true; tab = "conversation" }.disabled(busy) }
                if r.canRebase { Button("Rebase on server…") { store.confirmRequestRebase() }.disabled(busy) }
            }
            Button("Refresh conversation and approvals") { Task { await store.loadReview(number); await store.loadRequestLifecycle(number) } }
            if let r = lifecycle, r.state != "merged", r.canEdit {
                Divider()
                if r.state == "open" {
                    Button(t.provider == .gitlab ? "Close merge request…" : "Close pull request…", role: .destructive) { store.confirmRequestState(open: false) }.disabled(busy)
                } else {
                    Button("Reopen…") { store.confirmRequestState(open: true) }.disabled(busy)
                }
            }
        } label: {
            DesignIconImage(icon: .more, size: 12).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(t.provider == .gitlab ? "More merge request actions" : "More pull request actions")
        .accessibilityLabel(t.provider == .gitlab ? "More merge request actions" : "More pull request actions")
    }

    @ViewBuilder private func meta(_ pr: PullRequest) -> some View {
        HStack(spacing: 6) {
            RequestAuthorAvatar(author: pr.author, size: 20)
            Text(verbatim: "@\(pr.author)").font(.system(size: 13, weight: .semibold))
        }
        HStack(spacing: 5) {
            if ownBranch(pr) { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            Text(verbatim: PullRequestPage.branchLabel(pr, currentBranch: store.headBranch, thisBranch: String(localized: "This branch")) + (pr.fromFork ? String(localized: "  (fork)") : ""))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.Tone.neutral.text).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.Tone.neutral.fill.opacity(0.6)))
        if let r = review, !r.files.isEmpty {
            LineStatText(added: r.files.reduce(0) { $0 + $1.additions }, deleted: r.files.reduce(0) { $0 + $1.deletions })
        }
    }

    // MARK: Tabs

    /// Underline tabs: the labels never change weight, so they never shift. Tabs own their counts.
    private func tabs(compact: Bool) -> some View {
        HStack(spacing: 4) {
            tabButton("conversation", "Conversation", compact: compact) { EmptyView() }
            tabButton("files", "Changed files", compact: compact) {
                if let count = review?.files.count { StatusPill(title: String(count), symbol: nil, tone: .neutral) }
            }
            tabButton("checks", "Checks", compact: compact) {
                // only what needs attention is counted; nothing when every check passed
                switch checksBadge {
                case .failed(let count)?: StatusPill(title: String(count), symbol: "xmark", tone: .failed).help("\(count) failed")
                case .running(let count)?: StatusPill(title: String(count), symbol: "clock", tone: .waiting).help("\(count) running")
                case nil: EmptyView()
                }
            }
        }
    }

    private func tabButton<Badge: View>(_ value: String, _ title: LocalizedStringKey, compact: Bool, @ViewBuilder badge: () -> Badge) -> some View {
        let on = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 6) { Text(title).lineLimit(1).fixedSize(); badge() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Tone.neutral.text))
                .padding(.horizontal, compact ? 10 : 12)
                .frame(height: compact ? 44 : 36)
                .overlay(alignment: .bottom) { Rectangle().fill(on ? Color.accentColor : Color.clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Conversation

    private func conversation(_ pr: PullRequest, _ t: RepoTarget, wide: Bool) -> some View {
        ScrollView {
            // the side cards sit beside the thread, or under it when the column is too narrow for both
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
            layout {
                thread(pr, t).frame(maxWidth: .infinity, alignment: .leading)
                side(pr, t).frame(width: wide ? 280 : nil)
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func thread(_ pr: PullRequest, _ t: RepoTarget) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = store.reviewError {
                Label(error, symbol: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled)
            }
            if pr.body.trimmed.isEmpty { PullRequestCaption(String(localized: "No description")) }
            else { MarkdownView(pr.body, target: t, revision: pr.headSHA ?? pr.source, baseURL: URL(string: pr.url)) }
            Divider()
            Text("Activity").font(.system(size: 15, weight: .semibold))
            if let r = review {
                if !store.reviewDraftsFor(number).isEmpty { ReviewDraftPanel(number: number) }
                RequestActivity(number: number, review: r, author: pr.author, revision: pr.headSHA ?? pr.source, baseURL: URL(string: pr.url)) { path in
                    guard let file = r.files.first(where: { $0.path == path }) else { return }
                    store.openReviewFile(number, file); tab = "files"
                }
            } else if store.reviewLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func side(_ pr: PullRequest, _ t: RepoTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RequestLifecyclePanel(number: number, review: review?.state, headSHA: pr.headSHA, badge: checksBadge, editing: $editing)
            let issues = PullRequestPage.linkedIssues(pr.body)
            if !issues.isEmpty {
                PullRequestCard(title: "Linked issue") {
                    ForEach(issues, id: \.self) { issue in
                        Button { open(t.webURL + (t.provider == .github ? "/issues/\(issue)" : "/-/issues/\(issue)")) } label: {
                            HStack(spacing: 8) {
                                SymbolIcon("smallcircle.filled.circle").font(.system(size: 13)).foregroundStyle(StudioStyle.Tone.passed.text)
                                Text(verbatim: "#\(issue)").font(.system(size: 12, design: .monospaced))
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open in browser")
                    }
                }
            }
        }
    }

    // MARK: Composer

    /// One 36pt line that grows into an editor while it has focus or text. Reviews with a verdict are under Review….
    private func composer(_ provider: Provider) -> some View {
        let text = draft.trimmed
        let pending = store.reviewDraftsFor(number)
        let canSubmit = !text.isEmpty || !pending.isEmpty
        let expanded = composing || !draft.isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .focused($composing)
                .disabled(store.reviewBusy || store.reviewLoading)
                .accessibilityLabel("Comment · review feedback")
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7).padding(.vertical, 9)
                .frame(height: expanded ? 96 : 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(composing ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.16)))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Write a comment…").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 9).allowsHitTesting(false)
                    }
                }
            if store.reviewBusy { ProgressView().controlSize(.small).frame(height: 28) }
            Button(pending.isEmpty ? String(localized: "Comment") : String(localized: "Submit review")) {
                Task { if await store.postReviewComment(number, body: text), store.selection == .pullRequest(number), draft.trimmed == text { draft = "" } }
            }
            .buttonStyle(PullRequestButtonStyle(filled: true))
            .disabled(!canSubmit || store.reviewBusy)
            .keyboardShortcut(.return, modifiers: .command)
            .help(canSubmit ? "Comment (⌘↩)" : "A comment needs text")
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(StudioStyle.canvas)
        .animation(.easeOut(duration: 0.12), value: expanded)
    }

    // MARK: Checks

    @ViewBuilder private func checks(_ pr: PullRequest) -> some View {
        if let sha = pr.headSHA, !sha.isEmpty {
            RequestChecksPanel(number: number, headSHA: sha, draft: pr.isDraft) { checksBadge = $0 }
        } else {
            PullRequestCaption(String(localized: "Checks are unavailable until the request's commit is known.")).padding(24)
        }
    }
}

/// Review…: a review with a verdict. The text is the composer's draft, so nothing typed there is lost.
struct PullRequestReviewForm: View {
    @Environment(RepoStore.self) private var store
    let number: Int
    let provider: Provider
    @Binding var draft: String
    let close: () -> Void
    @ViewState private var verdict = ReviewVerdict.comment

    var body: some View {
        let state = store.review?.number == number ? store.review?.state : nil
        let text = draft.trimmed
        let pending = store.reviewDraftsFor(number)
        // GitLab approves apart from comments, and an approval can be taken back
        let revoke = provider == .gitlab && state?.approvedByMe == true
        let reason = blocked(text: text, pending: pending.count, approved: state?.approvedByMe == true, revoke: revoke)
        VStack(alignment: .leading, spacing: 10) {
            PullRequestSegmented(label: "Review type", items: types(revoke: revoke), selection: verdict) { verdict = $0 }
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .disabled(store.reviewBusy)
                .accessibilityLabel("Comment · review feedback")
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
            if !pending.isEmpty { PullRequestCaption(String(localized: "Pending line comments (\(pending.count))")) }
            HStack(spacing: 8) {
                if store.reviewBusy { ProgressView().controlSize(.small) }
                // the one reason sits beside the disabled button
                if let reason { PullRequestCaption(reason) }
                Spacer(minLength: 8)
                Button("Cancel", action: close).buttonStyle(PullRequestButtonStyle()).keyboardShortcut(.cancelAction)
                Button(revoke && verdict == .approve ? String(localized: "Revoke approval") : String(localized: "Submit review")) {
                    Task { await submit(text, revoke: revoke) }
                }
                .buttonStyle(PullRequestButtonStyle(filled: true))
                .disabled(reason != nil || store.reviewBusy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func types(revoke: Bool) -> [PullRequestSegmented<ReviewVerdict>.Item] {
        var items: [PullRequestSegmented<ReviewVerdict>.Item] = [
            .init(value: .comment, title: String(localized: "Comment")),
            .init(value: .approve, title: revoke ? String(localized: "Revoke approval") : String(localized: "Approve")),
        ]
        if provider == .github { items.append(.init(value: .requestChanges, title: String(localized: "Request changes"))) }
        return items
    }

    private func blocked(text: String, pending: Int, approved: Bool, revoke: Bool) -> String? {
        switch verdict {
        case .comment: return text.isEmpty && pending == 0 ? String(localized: "A comment needs text") : nil
        case .requestChanges: return text.isEmpty ? String(localized: "Request changes with a comment (comment required)") : nil
        case .approve: return approved && !revoke ? String(localized: "Approved") : nil
        }
    }

    private func submit(_ text: String, revoke: Bool) async {
        var sent = true
        switch verdict {
        case .comment: sent = await store.postReviewComment(number, body: text)
        case .requestChanges: sent = await store.requestChanges(number, body: text)
        case .approve:
            if revoke { await store.unapprovePullRequest(number); close(); return }
            sent = await store.approvePullRequest(number, body: text)
        }
        guard sent, store.selection == .pullRequest(number) else { return }
        if draft.trimmed == text { draft = "" }
        close()
    }
}
