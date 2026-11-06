import SwiftUI

/// The Pull requests page (merge requests on GitLab), as the redesign's boards draw it: a 312pt list column beside the
/// selected request's Conversation, Changed files and Checks. Hide list / Show list is one control; the choice is the
/// same on every tab and nothing hides the list on its own. (Windows: pages/repo/ui/PullRequestsWorkspace.tsx)
struct PullRequestsWorkspace: View {
    @Environment(RepoStore.self) private var store
    @AppStorage("pullRequestListHidden") private var listHidden = false

    var body: some View {
        if let target = store.target {
            VStack(spacing: 0) {
                top(target)
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        PullRequestSummary(target: target, compact: geometry.size.width < 680)
                        Divider()
                        columns(target)
                    }
                }
            }
            .task { await store.loadPullRequests() }
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView("No hosting remote", symbol: "arrow.triangle.pull", description: Text("Open a repository with a GitHub or GitLab remote to use this workspace."))
                Button("Open repository…") { store.presentOpenPanel() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func columns(_ target: RepoTarget) -> some View {
                GeometryReader { geometry in
                    // a narrow window stacks the list above the request; children keep their identity so a draft survives
                    let stacked = geometry.size.width < 680
                    let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                    layout {
                        Group {
                            if listHidden {
                                strip(target, stacked: stacked)
                            } else {
                                PullRequestList(target: target) { listHidden = true }
                                    .frame(width: stacked ? nil : PullRequestPage.listWidth, height: stacked ? max(160, min(280, geometry.size.height * 0.36)) : nil)
                                    .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity, alignment: .top)
                            }
                        }
                        .background(StudioStyle.canvas)
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: stacked ? nil : 1, height: stacked ? 1 : nil)
                        detail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
    }

    /// Where the list comes from, and the two things done to the list as a whole
    private func top(_ target: RepoTarget) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(target.host) / \(target.path)").font(.system(size: 13)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            if store.prState == .loading { ProgressView().controlSize(.small) }
            Button { Task { await store.loadPullRequests() } } label: { DesignIconImage(icon: .refresh) }
                .buttonStyle(PullRequestButtonStyle(iconOnly: true))
                .help("Refresh list").accessibilityLabel("Refresh list")
            Button { store.sheet = .createPullRequest } label: {
                Label(target.provider == .gitlab ? "New merge request…" : "New pull request…", symbol: "plus")
            }
            .buttonStyle(PullRequestButtonStyle())
            .disabled(store.headBranch == nil)
            .help("New \(target.provider.requestShort) from the current branch")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// The hidden list: a strip that holds only Show list
    private func strip(_ target: RepoTarget, stacked: Bool) -> some View {
        Button { listHidden = false } label: { DesignIconImage(icon: .panelLeft) }
            .buttonStyle(PullRequestButtonStyle(iconOnly: true))
            .help("Show list")
            .accessibilityLabel(target.provider == .gitlab ? "Show merge request list" : "Show pull request list")
            .padding(stacked ? .vertical : .top, stacked ? 6 : 12)
            .frame(width: stacked ? nil : PullRequestPage.listStripWidth)
            .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity, alignment: stacked ? .leading : .top)
            .padding(.leading, stacked ? 12 : 0)
    }

    @ViewBuilder private var detail: some View {
        if case .pullRequest(let number)? = store.selection {
            PullRequestDetailView(number: number, listShown: !listHidden, onPage: true)
        } else {
            VStack(spacing: 8) {
                DesignIconImage(icon: .pullRequests, size: 24).foregroundStyle(StudioStyle.Rail.icon).accessibilityHidden(true)
                Text("Select a pull request").font(.system(size: 15, weight: .semibold))
                Text("Search the list, then review the conversation, files and merge checks here.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
