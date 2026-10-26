import SwiftUI

/// 저장소의 현재 상태를 읽고 다음 작업으로 이동하는 홈 화면.
struct RepositoryOverview: View {
    @Environment(RepoStore.self) private var store

    private var recentCommits: [Commit] {
        Array(store.entries.lazy.map(\.commit).filter { !$0.isWIP && $0.wipWorktree == nil }.prefix(7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            workingState
            metrics
            recentHistory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.name)
                .font(.system(size: 25, weight: .semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { branchName; remoteState }
                VStack(alignment: .leading, spacing: 7) { branchName; remoteState }
            }
        }
    }

    private var branchName: some View {
        Label(store.headBranch ?? String(localized: "Detached HEAD"), systemImage: "arrow.triangle.branch")
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(StudioStyle.selection, in: RoundedRectangle(cornerRadius: 6))
            .help(store.headBranch ?? store.headHash ?? String(localized: "Detached HEAD"))
    }

    private var remoteState: some View {
        Text(remoteDescription)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
    }

    private var remoteDescription: String {
        guard let upstream = store.status.upstream else {
            return store.remotes.isEmpty
                ? String(localized: "No remote configured")
                : String(localized: "No tracking branch")
        }
        if store.status.ahead == 0, store.status.behind == 0 {
            return upstream + " · " + String(localized: "Up to date")
        }
        return upstream + " · " + String(localized: "↑\(store.status.ahead) to push · ↓\(store.status.behind) to pull")
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 10) { actionButtons }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var actionButtons: some View {
        Button { store.navigate(.changes) } label: {
            Label("Review changes", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.borderedProminent)
        .tint(StudioStyle.accent)
        Button { store.navigate(.commits) } label: {
            Label("Browse commits", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.bordered)
        Button { store.navigate(.branches) } label: {
            Label("Manage branches", systemImage: "arrow.triangle.branch")
        }
        .buttonStyle(.bordered)
    }

    private var workingState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stateIcon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(stateColor)
                .frame(width: 34, height: 34)
                .background(stateColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(stateTitle).font(.system(size: 14, weight: .semibold))
                Text(stateDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .combine)
    }

    private var stateIcon: String {
        if !store.status.conflicted.isEmpty { return "exclamationmark.triangle" }
        if store.repoState != .clean { return "arrow.triangle.merge" }
        return store.status.isEmpty ? "checkmark.circle" : "doc.badge.ellipsis"
    }

    private var stateColor: Color {
        if !store.status.conflicted.isEmpty { return Color(nsColor: .systemOrange) }
        return store.status.isEmpty && store.repoState == .clean ? Color(nsColor: .systemGreen) : StudioStyle.accent
    }

    private var stateTitle: String {
        if !store.status.conflicted.isEmpty { return String(localized: "Resolve conflicts before committing") }
        if store.repoState != .clean { return store.repoState.title }
        return store.status.isEmpty ? String(localized: "Working tree clean") : String(localized: "Changes ready for review")
    }

    private var stateDescription: String {
        if !store.status.conflicted.isEmpty {
            return String(localized: "Open Changes to resolve the conflicted files and continue your Git operation.")
        }
        if store.repoState != .clean {
            return String(localized: "Open Changes to review the operation and its next step.")
        }
        return store.status.isEmpty
            ? String(localized: "Your files match the latest commit. Browse history or choose another branch to continue.")
            : String(localized: "Review your files, stage the changes you want, then write a commit message.")
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { metricButtons }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { metricButtons }
        }
    }

    @ViewBuilder private var metricButtons: some View {
        OverviewMetric(title: String(localized: "Changed files"), value: store.status.count,
                       detail: String(localized: "Review working changes"), icon: "doc.text") {
            store.navigate(.changes)
        }
        OverviewMetric(title: String(localized: "Staged files"), value: store.status.staged.count,
                       detail: String(localized: "Included in your next commit"), icon: "checkmark.square") {
            store.navigate(.changes)
        }
        OverviewMetric(title: String(localized: "Outgoing commits"), value: store.status.ahead,
                       detail: store.status.upstream == nil ? String(localized: "No tracking branch") : String(localized: "Ready to push"),
                       icon: "arrow.up.right") {
            store.navigate(.commits)
        }
        OverviewMetric(title: String(localized: "Incoming commits"), value: store.status.behind,
                       detail: store.status.upstream == nil ? String(localized: "No tracking branch") : String(localized: "Available to pull"),
                       icon: "arrow.down.left") {
            store.navigate(.commits)
        }
    }

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Recent commits").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button("View history") { store.navigate(.commits) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .tint(StudioStyle.accent)
                    .foregroundStyle(StudioStyle.accent)
            }
            VStack(spacing: 0) {
                if recentCommits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No commits yet").font(.system(size: 13, weight: .medium))
                        Text("Your first commit will appear here.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(recentCommits) { commit in
                        OverviewCommitRow(commit: commit, isHead: commit.id == store.headHash) {
                            store.navigate(.commits)
                            store.select(.commit(commit.id))
                            store.scrollTarget = commit.id
                        }
                        if commit.id != recentCommits.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct OverviewMetric: View {
    let title: String
    let value: Int
    let detail: String
    let icon: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) { metricContent }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private var metricContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricValue
            metricDescription
        }
        .padding(14)
        .frame(minWidth: 132, maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var metricValue: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(StudioStyle.accent)
            Spacer(minLength: 4)
            Text(value.formatted())
                .font(.system(size: 23, weight: .semibold))
                .monospacedDigit()
        }
    }

    private var metricDescription: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var backgroundColor: Color { hovering ? StudioStyle.selection : StudioStyle.surface }
    private var helpText: String { title + " · " + detail }
    private var accessibilityText: String { title + ": " + value.formatted() + ". " + detail }
}

private struct OverviewCommitRow: View {
    let commit: Commit
    let isHead: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AuthorAvatar(name: commit.author, email: commit.email, size: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(commit.subject)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 7) {
                        Text(commit.author).lineLimit(1).truncationMode(.middle)
                        Text(commit.short).fontDesign(.monospaced)
                        if isHead {
                            Text("HEAD").font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(StudioStyle.selection, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Fmt.short(commit.date))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? StudioStyle.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(commit.subject + "\n" + commit.author + " · " + Fmt.long(commit.date))
        .accessibilityElement(children: .combine)
    }
}
