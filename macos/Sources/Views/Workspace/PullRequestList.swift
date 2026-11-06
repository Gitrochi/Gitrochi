import SwiftUI
import AppKit

/// The list column of the Pull requests page, as the redesign's boards draw it: search with Sort and Hide list, a
/// neutral segmented filter, and two-line rows that end with the comment count and the author's avatar.
/// The repository sidebar keeps its own compact list (PullRequestSection). (Windows: PullRequestList.tsx)
struct PullRequestList: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let target: RepoTarget
    /// Hide list: the page's one list control, kept across the tabs
    let hide: () -> Void
    @AppStorage("pullRequestSort") private var sort = PullRequestPage.Sort.updated.rawValue
    @ViewState private var search = ""
    @ViewState private var hovered: Int?
    /// How many requests ask for the user's review, as last read from a list that says so
    @ViewState private var asked = 0
    @FocusState private var searchFocused: Bool

    private var gitlab: Bool { target.provider == .gitlab }
    private var scope: String { store.collaboration.query.scope }
    private var requests: [PullRequest] { PullRequestPage.sorted(store.pullRequests, by: PullRequestPage.Sort(rawValue: sort) ?? .updated) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                searchField
                sortMenu
                Button(action: hide) { DesignIconImage(icon: .panelLeft) }
                    .buttonStyle(PullRequestButtonStyle(iconOnly: true))
                    .help("Hide list")
                    .accessibilityLabel(gitlab ? "Hide merge request list" : "Hide pull request list")
            }
            PullRequestSegmented(label: "Filter", items: filters, selection: scope, fill: true) { value in
                Task { await store.filterPullRequests(scope: value, search: search) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let warning = store.collaboration.warning { PullRequestCaption(warning).padding(.horizontal, 10) }
                    state
                    ForEach(requests) { row($0) }
                    if store.collaboration.more {
                        Button("Load more") { Task { await store.loadPullRequests(append: true) } }
                            .buttonStyle(PullRequestTextButtonStyle())
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .disabled(store.prState == .loading)
                    }
                }
            }
        }
        .padding(12)
        .onAppear { search = store.collaboration.query.search }
        .onChange(of: store.pullRequests, initial: true) { _, requests in
            guard store.prState == .loaded else { return }
            if scope == "open" { asked = PullRequestPage.reviewRequestedCount(requests) } else if scope == "reviewRequested" { asked = requests.count }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: target.provider.requestsTitle))
    }

    // MARK: Search, sort and filter

    private var searchField: some View {
        HStack(spacing: 6) {
            DesignIconImage(icon: .search, size: 12).foregroundStyle(StudioStyle.Rail.icon)
            TextField(gitlab ? String(localized: "Search merge requests") : String(localized: "Search pull requests"), text: $search)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit(runSearch)
                .onKeyPress(.escape) {
                    guard !search.isEmpty else { return .ignored }
                    search = ""; runSearch()
                    return .handled
                }
            if !search.isEmpty {
                Button { search = ""; runSearch() } label: { SymbolIcon("xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.16)))
    }

    private func runSearch() { Task { await store.filterPullRequests(scope: scope, search: search) } }

    /// Sort, and below it the two filters the segmented control has no room for
    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                check(String(localized: "Recently updated"), on: sort == PullRequestPage.Sort.updated.rawValue) { sort = PullRequestPage.Sort.updated.rawValue }
                check(String(localized: "Newest"), on: sort == PullRequestPage.Sort.newest.rawValue) { sort = PullRequestPage.Sort.newest.rawValue }
                check(String(localized: "Most commented"), on: sort == PullRequestPage.Sort.comments.rawValue) { sort = PullRequestPage.Sort.comments.rawValue }
            }
            Section("Show") {
                ForEach(["closed", "merged"], id: \.self) { value in
                    check(WorkState.title(value), on: scope == value) { Task { await store.filterPullRequests(scope: scope == value ? "open" : value, search: search) } }
                }
            }
        } label: {
            DesignIconImage(icon: .sort, size: 12).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
                .contentShape(Rectangle())
        }
        // a plain button menu draws the whole label; a borderless one keeps only its glyph
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Sort")
        .accessibilityLabel("Sort")
    }

    private func check(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { if on { Label(title, symbol: "checkmark") } else { Text(verbatim: title) } }
    }

    private var filters: [PullRequestSegmented<String>.Item] {
        // the count sits inside the label
        return [
            .init(value: "open", title: WorkState.title("open")),
            .init(value: "reviewRequested", title: String(localized: "Review requested") + (asked > 0 ? " \(asked)" : "")),
            .init(value: "mine", title: String(localized: "Mine")),
        ]
    }

    // MARK: States

    @ViewBuilder private var state: some View {
        switch store.prState {
        case .authorizationRequired:
            if let account = store.hostingAccount { SavedAccountAccessNotice(account: account) { Task { await store.loadPullRequests() } } }
        case .needsAccount:
            if let account = store.hostingAccount {
                SavedAccountAccessNotice(account: account) { Task { await store.loadPullRequests() } }
            } else {
                // An account on this very host cannot be an alias for it, so only other servers are worth a try.
                let others = AccountStore.shared.accounts(for: target.provider).filter { $0.host != target.host }
                VStack(alignment: .leading, spacing: 6) {
                    if let a = others.first {
                        Button("Try with the connected account (@\(a.username) · \(a.host))") { Task { await store.tryExistingAccounts() } }
                            .buttonStyle(.link)
                            .help("If the same server is used under another address, an account you've already connected works there too")
                    }
                    Button(gitlab ? "Connect a self-hosted GitLab (\(target.host)) account…" : "Connect a GitHub account…") { openSettings() }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 10)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, symbol: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).lineLimit(3)
                Button("Retry") { Task { await store.loadPullRequests() } }.buttonStyle(PullRequestButtonStyle())
            }
            .padding(.horizontal, 10)
        case .loading where store.pullRequests.isEmpty:
            ProgressView().controlSize(.small).padding(10)
        case .loaded where store.pullRequests.isEmpty:
            PullRequestCaption(gitlab ? String(localized: "No merge requests match this filter.") : String(localized: "No pull requests match this filter."))
                .padding(10)
        default:
            EmptyView()
        }
    }

    // MARK: Rows

    private func row(_ pr: PullRequest) -> some View {
        let selected = store.selection == .pullRequest(pr.number)
        let secondary = selected ? Color.primary.opacity(0.72) : StudioStyle.Rail.icon
        let comments = PullRequestPage.commentCount(pr, review: store.review)
        return Button { store.select(.pullRequest(pr.number)) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(pr.title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(2)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    // the list row owns the updated date; it never truncates
                    if let date = pr.updated { Text(PullRequestDate.short(date)).font(.system(size: 12)).foregroundStyle(secondary).fixedSize().help(Fmt.long(date)) }
                }
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(secondary).fixedSize()
                    if let sha = pr.headSHA, let ci = store.ciBySha[sha] {
                        CIStatusIcon(status: ci.status, size: 12).help("CI: \(ci.status.title) · #\(ci.number)")
                    }
                    if pr.isDraft { PullRequestRowPill(title: String(localized: "Draft"), symbol: "arrow.triangle.pull", tone: .waiting, onSelection: selected).fixedSize() }
                    if !pr.fromFork, pr.source == store.headBranch {
                        PullRequestRowPill(title: String(localized: "This branch"), marker: true, tone: .neutral, onSelection: selected).fixedSize()
                    }
                    // the one pill that shrinks: the right slot and the other pills keep their size
                    if pr.reviewRequested { PullRequestRowPill(title: String(localized: "Review requested"), symbol: "eye", tone: .info, onSelection: selected).layoutPriority(-1) }
                    Spacer(minLength: 0)
                    if let comments, comments > 0 {
                        HStack(spacing: 4) {
                            DesignIconImage(icon: .comment, size: 10)
                            Text(verbatim: String(comments)).font(.system(size: 11))
                        }
                        .foregroundStyle(secondary).fixedSize()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(comments == 1 ? String(localized: "1 comment") : String(localized: "\(comments) comments"))
                    }
                    Avatar(name: pr.author, email: pr.author, size: 16).help(Text(verbatim: "@\(pr.author)")).accessibilityLabel(Text(verbatim: "@\(pr.author)"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // selection is a tint only; hover is lighter than any tint
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hovered == pr.number ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? pr.number : (hovered == pr.number ? nil : hovered) }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Check out branch") { Task { await store.checkoutPullRequest(pr) } }
            Button("Open in browser") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
            Button("Copy link") { store.copy(pr.url) }
        }
    }
}
