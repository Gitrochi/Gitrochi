import SwiftUI

/// "This branch compared with the server", as the Summary card states board draws it: the branch, how far it is from
/// its base and from the server, and the one next step. Read from local refs. The card is there from the first frame,
/// loading until the list and the counts are read, and says so when the branch has no request to open.
/// (Windows: pages/repo/ui/PullRequestSummary.tsx)
struct PullRequestSummary: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let target: RepoTarget
    let compact: Bool
    @ViewState private var counts: (key: String, value: PullRequestPage.BranchCounts)?
    /// The list this view saw read: a refresh, or a failed one, keeps the card as that read left it
    @ViewState private var readKey: String?

    private var gitlab: Bool { target.provider == .gitlab }
    private var head: String? { store.headBranch }
    private var request: PullRequest? { store.pullRequests.first { $0.source == head && !$0.fromFork } }
    private var base: String? {
        request?.target ?? ActionsPage.baseRef(store.localBranches.map(\.name) + store.remoteBranches.map(\.shortName))
    }
    private var remoteBase: String? { base.map { target.remote + "/" + $0 } }
    private var server: String { gitlab ? String(localized: "on GitLab") : String(localized: "on GitHub") }
    private var listKey: String { "\(store.url?.path ?? "")|\(target.host)/\(target.path)|\(store.hostingAccount?.id ?? "")" }
    private var countsKey: String { "\(store.url?.path ?? "")|\(head ?? "")|\(remoteBase ?? "")" }
    private var list: PullRequestPage.ListRead {
        switch store.prState {
        case .loaded: return .read
        case .needsAccount: return .noAccount
        case .failed: return readKey == listKey ? .read : .failed
        case .idle, .loading, .authorizationRequired: return readKey == listKey ? .read : .pending
        }
    }
    private var card: PullRequestPage.SummaryCard {
        PullRequestPage.summaryCard(list: list, head: head, base: base, hasRequest: request != nil, ahead: store.status.ahead,
                                    counts: counts?.key == countsKey ? counts?.value ?? .pending : .pending)
    }
    private var loadingCaption: String { gitlab ? String(localized: "Loading merge requests…") : String(localized: "Loading pull requests…") }
    private var nothingToOpen: String { gitlab ? String(localized: "No merge request to open from here") : String(localized: "No pull request to open from here") }
    private var connect: String {
        gitlab ? String(localized: "Connect a GitLab account to see merge requests") : String(localized: "Connect a GitHub account to see pull requests")
    }

    var body: some View {
        let card = card
        HostedListSummary(compact: compact) {
            HostedListSummaryCaption(text: String(localized: "This branch"))
            // a branch name is cut from the front, where it says least
            Text(verbatim: head ?? String(localized: "Detached HEAD")).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.head)
            if card == .loading {
                HostedListSummaryLoadingLine(caption: loadingCaption)
            } else if let line = line(card) {
                HostedListSummaryCaption(text: line)
            }
        } middle: {
            switch card {
            case .loading: HostedListSummaryBars()
            case .noAccount:
                HostedListSummaryMessage(title: connect, caption: String(localized: "\(target.path) is on \(target.host). Commits and branches work without an account."))
            case .detached: HostedListSummaryMessage(title: nothingToOpen)
            case .base:
                HostedListSummaryMessage(title: nothingToOpen, caption: String(localized: "\(base ?? "") is the base branch. Switch to another branch to open one."))
            case .failed, .uncounted: Color.clear
            case .branch(let state):
                track(state, base: base ?? "").accessibilityElement(children: .ignore).accessibilityLabel(headline(state, base: base ?? ""))
            }
        } trail: {
            switch card {
            case .loading: HostedListSummaryBar()
            case .branch(let state): trail(state, base: base ?? "")
            default: action(card)
            }
        } strip: {
            if card == .loading { ProgressView().controlSize(.mini) }
            Text(verbatim: head ?? String(localized: "Detached HEAD")).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.head)
            HostedListSummaryCaption(text: stripLine(card))
            Spacer(minLength: 8)
            action(card)
        }
        .padding(.top, compact ? 0 : 4)
        .accessibilityLabel("This branch compared with the server")
        // on the card itself, which is always drawn: a task on a view that waits for its data never reads it
        .task(id: "\(head ?? "")|\(store.headHash ?? "")|\(remoteBase ?? "")") { await load() }
        .onChange(of: store.prState, initial: true) { _, state in if state == .loaded { readKey = listKey } }
    }

    /// Both counts come from one local read; a base that was never fetched leaves the card without its track
    private func load() async {
        let key = countsKey
        var value = PullRequestPage.BranchCounts.unavailable
        if let url = store.url, let remoteBase, head != nil, head != base,
           let output = try? await Git.run(["rev-list", "--left-right", "--count", remoteBase + "...HEAD"], in: url).output {
            let parts = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if parts.count == 2 { value = .read(incoming: parts[0], commits: parts[1]) }
        }
        guard !Task.isCancelled, key == countsKey else { return }
        counts = (key, value)
    }

    /// What this clone knows of the branch without the server
    private var local: String? {
        guard head != nil else { return nil }
        if store.status.upstream == nil { return String(localized: "Not on the server yet") }
        return base.flatMap { $0 == head ? nil : String(localized: "Based on \($0)") }
    }

    /// The line under the branch name
    private func line(_ card: PullRequestPage.SummaryCard) -> String? {
        switch card {
        case .loading, .detached, .base: return nil
        case .noAccount: return local
        case .failed: return String(localized: "Couldn't reach \(target.host)")
        case .uncounted(let hasRequest): return hasRequest ? requestOpen : local
        case .branch(let state): return headline(state, base: base ?? "")
        }
    }

    /// The strip says in one line what the card says in its lead and its middle
    private func stripLine(_ card: PullRequestPage.SummaryCard) -> String {
        switch card {
        case .loading: return loadingCaption
        case .noAccount: return connect
        case .detached, .base: return nothingToOpen
        default: return line(card) ?? ""
        }
    }

    private var requestOpen: String { gitlab ? String(localized: "Merge request open") : String(localized: "Pull request open") }

    private func headline(_ state: PullRequestPage.BranchSummary, base: String) -> String {
        switch state {
        case .noRequest: return store.status.upstream == nil ? String(localized: "Not on the server yet") : String(localized: "Based on \(base)")
        case .moved, .upToDate, .notPushed: return requestOpen
        }
    }

    private func commitsLabel(_ count: Int) -> String {
        String(localized: "\(count) commits")
    }

    @ViewBuilder private func track(_ state: PullRequestPage.BranchSummary, base: String) -> some View {
        let sha = String((store.headHash ?? "").prefix(7))
        HStack(alignment: .top, spacing: 0) {
            switch state {
            case .noRequest(let commits):
                if case .read(let incoming, _)? = counts?.value, incoming > 0 {
                    node(remoteBase ?? base, String(localized: "\(incoming) new commits"), tone: .waiting)
                } else {
                    node(base, String(localized: "base"))
                }
                line(commitsLabel(commits)); node("HEAD", sha, current: true, mono: true)
            case .moved(let incoming, let commits):
                node(remoteBase ?? base, String(localized: "\(incoming) new commits"), tone: .waiting); line(commitsLabel(commits)); node("HEAD = \(target.remote)", server, current: true)
            case .upToDate(let commits):
                node(base, String(localized: "base")); line(commitsLabel(commits)); node("HEAD = \(target.remote)", server, current: true)
            case .notPushed(let onServer, _):
                node(base, String(localized: "base")); line(commitsLabel(onServer)); node(target.remote, server, strong: true)
                line(String(localized: "Not pushed"), dashed: true); node("HEAD", sha, current: true, mono: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    private func node(_ title: String, _ caption: String, tone: StudioStyle.Tone? = nil, current: Bool = false, strong: Bool = false, mono: Bool = false) -> some View {
        VStack(spacing: 4) {
            Circle().fill(current ? Color.accentColor : strong ? Color.primary.opacity(0.78) : StudioStyle.Rail.icon.opacity(0.7))
                .frame(width: current || strong ? 12 : 10, height: current || strong ? 12 : 10)
                .background(Circle().fill(Color.accentColor.opacity(current ? 0.18 : 0)).frame(width: 18, height: 18))
                .frame(height: 16)
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
            Text(verbatim: caption).font(.system(size: 11, design: mono ? .monospaced : .default)).foregroundStyle(tone?.text ?? HostedList.caption).lineLimit(1).fixedSize()
        }
        .frame(width: 96)
    }

    private func line(_ label: String, dashed: Bool = false) -> some View {
        Rectangle().fill(.clear).frame(height: 16)
            .overlay {
                if dashed {
                    Line().stroke(Color.primary.opacity(0.78), style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(height: 2)
                } else {
                    Rectangle().fill(StudioStyle.border).frame(height: 2)
                }
            }
            .overlay(alignment: .top) {
                Text(verbatim: label).font(.system(size: 11, weight: dashed ? .semibold : .regular)).foregroundStyle(dashed ? Color.primary : HostedList.caption)
                    .lineLimit(1).fixedSize().offset(y: -14)
            }
            .padding(.horizontal, -36)
            .frame(minWidth: 40, maxWidth: .infinity)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return path
        }
    }

    @ViewBuilder private func trail(_ state: PullRequestPage.BranchSummary, base: String) -> some View {
        action(state, base: base)
        switch state {
        case .noRequest: EmptyView()
        case .moved: HostedListSummaryCaption(text: String(localized: "Merges \(remoteBase ?? base) into this branch"))
        case .upToDate: HostedListSummaryCaption(text: String(localized: "Nothing to push"))
        case .notPushed:
            if let request {
                HostedListSummaryCaption(text: gitlab ? String(localized: "Updates merge request #\(String(request.number))") : String(localized: "Updates pull request #\(String(request.number))"))
            }
        }
    }

    /// The one next step, in the trail and at the end of the strip
    @ViewBuilder private func action(_ card: PullRequestPage.SummaryCard) -> some View {
        switch card {
        // the state blocks the page, so its action is the filled one
        case .noAccount: Button("Connect account…") { openSettings() }.hostedListFilledButton()
        case .uncounted(hasRequest: false): create
        case .branch(let state): action(state, base: base ?? "")
        default: EmptyView()
        }
    }

    private var create: some View {
        Button(gitlab ? "Create merge request…" : "Create pull request…") { store.sheet = .createPullRequest }.buttonStyle(HostedListButtonStyle())
    }

    @ViewBuilder private func action(_ state: PullRequestPage.BranchSummary, base: String) -> some View {
        switch state {
        case .noRequest:
            create
        case .moved:
            Button("Update branch") { if let remoteBase { Task { await store.merge(remoteBase) } } }.buttonStyle(HostedListButtonStyle())
        case .upToDate:
            EmptyView()
        case .notPushed(_, let local):
            Button { Task { _ = await store.push() } } label: {
                Label(local == 1 ? String(localized: "Push 1 commit") : String(localized: "Push \(local) commits"), symbol: "arrow.up")
            }
            .buttonStyle(HostedListButtonStyle())
        }
    }
}
