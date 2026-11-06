import SwiftUI

/// "This branch compared with the server", as the Summary card states board draws it: the branch, how far it is from
/// its base and from the server, and the one next step. Read from local refs; a branch that is its own base has none.
/// (Windows: pages/repo/ui/PullRequestSummary.tsx)
struct PullRequestSummary: View {
    @Environment(RepoStore.self) private var store
    let target: RepoTarget
    let compact: Bool
    @ViewState private var counts: (incoming: Int, commits: Int)?

    private var gitlab: Bool { target.provider == .gitlab }
    private var head: String? { store.headBranch }
    private var request: PullRequest? { store.pullRequests.first { $0.source == head && !$0.fromFork } }
    private var base: String? {
        request?.target ?? ActionsPage.baseRef(store.localBranches.map(\.name) + store.remoteBranches.map(\.shortName))
    }
    private var remoteBase: String? { base.map { target.remote + "/" + $0 } }
    private var server: String { gitlab ? String(localized: "on GitLab") : String(localized: "on GitHub") }

    var body: some View {
        // not a Group: with no card yet it would be no view at all, and its task would never read the counts
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            // before the list is read, "no request yet" would be a guess
            if let head, let base, head != base, let counts, store.prState == .loaded {
                let state = PullRequestPage.branchSummary(hasRequest: request != nil, ahead: store.status.ahead, incoming: counts.incoming, commits: counts.commits)
                HostedListSummary(compact: compact) {
                    HostedListSummaryCaption(text: String(localized: "This branch"))
                    // a branch name is cut from the front, where it says least
                    Text(verbatim: head).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.head)
                    HostedListSummaryCaption(text: headline(state, base: base))
                } middle: {
                    track(state, base: base).accessibilityElement(children: .ignore).accessibilityLabel(headline(state, base: base))
                } trail: {
                    trail(state, base: base)
                } strip: {
                    Text(verbatim: head).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.head)
                    HostedListSummaryCaption(text: headline(state, base: base))
                    Spacer(minLength: 8)
                    action(state, base: base)
                }
                .padding(.top, compact ? 0 : 4)
                .accessibilityLabel("This branch compared with the server")
            }
        }
        .task(id: "\(head ?? "")|\(store.headHash ?? "")|\(remoteBase ?? "")") { await load() }
    }

    /// Both counts come from one local read; a base that was never fetched leaves the card out
    private func load() async {
        guard let url = store.url, let remoteBase, head != base,
              let output = try? await Git.run(["rev-list", "--left-right", "--count", remoteBase + "...HEAD"], in: url).output else { counts = nil; return }
        let parts = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        counts = parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private func headline(_ state: PullRequestPage.BranchSummary, base: String) -> String {
        switch state {
        case .noRequest: return store.status.upstream == nil ? String(localized: "Not on the server yet") : String(localized: "Based on \(base)")
        case .moved, .upToDate, .notPushed: return gitlab ? String(localized: "Merge request open") : String(localized: "Pull request open")
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
                if let counts, counts.incoming > 0 {
                    node(remoteBase ?? base, String(localized: "\(counts.incoming) new commits"), tone: .waiting)
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

    @ViewBuilder private func action(_ state: PullRequestPage.BranchSummary, base: String) -> some View {
        switch state {
        case .noRequest:
            Button(gitlab ? "Create merge request…" : "Create pull request…") { store.sheet = .createPullRequest }.buttonStyle(HostedListButtonStyle())
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
