import Foundation

/// The toolbar items a window shows (docs/design.md › App shell). (Windows: toolbarSet in workspace-navigation.ts)
enum ToolbarSet: Equatable {
    /// The repository screen: Changes, Fetch, Pull, Push, Branch, More, terminal, right panel and account
    case repository
    /// Another page with a repository open: More, terminal and account
    case page
    /// No repository open: only the account; More and the terminal act on a repository
    case noRepository

    init(destination: WorkspaceDestination, hasRepository: Bool) {
        if !hasRepository { self = .noRepository } else { self = destination == .repository ? .repository : .page }
    }
}

/// The one sync action drawn prominent: Push when there are only commits to push, Pull when a fast-forward is
/// possible, none when the branch has diverged or has no upstream. (Windows: recommendedSync)
enum RecommendedSync: Equatable {
    case push, pull, none

    init(ahead: Int, behind: Int, hasUpstream: Bool) {
        if !hasUpstream { self = .none } else if ahead > 0 && behind == 0 { self = .push } else if behind > 0 && ahead == 0 { self = .pull } else { self = .none }
    }
}

/// The pages of a repository window. Repository is the three-column screen (branches | graph | inspector);
/// the rest are full-width pages. (Windows: entities/git/model/workspace-navigation.ts)
enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home, repository, compare, rebase, code
    case pullRequests, issues, actions, releases, projects, account
    case flows, ledger
    var id: String { rawValue }

    /// Restore known pages, including the Ledger without a preview environment.
    init?(rawValue: String) {
        guard let page = Self.allCases.first(where: { $0.rawValue == rawValue }), page.isShown else { return nil }
        self = page
    }

    var isShown: Bool { true }
    static var shown: [WorkspaceDestination] { allCases.filter(\.isShown) }
    /// Pages the repository screen links to (request and issue rows, a commit's CI icon, the tags); opened from there,
    /// they offer the way back
    var returnsToRepository: Bool { [.pullRequests, .issues, .actions, .releases].contains(self) }
    var needsRepository: Bool { [.repository, .compare, .rebase, .code, .pullRequests, .actions, .flows].contains(self) }
    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .repository: return String(localized: "Repository")
        case .compare: return String(localized: "Compare")
        case .rebase: return String(localized: "Rebase")
        case .code: return String(localized: "Code")
        case .pullRequests: return String(localized: "Pull requests")
        case .issues: return String(localized: "Issues")
        case .actions: return String(localized: "Actions")
        case .releases: return String(localized: "Releases")
        case .projects: return String(localized: "Projects")
        case .account: return String(localized: "Account")
        case .flows: return String(localized: "Flows")
        case .ledger: return String(localized: "Ledger")
        }
    }
    func title(gitlab: Bool) -> String {
        if gitlab {
            switch self {
            case .pullRequests: return String(localized: "Merge requests")
            case .actions: return String(localized: "Pipelines")
            default: break
            }
        }
        return title
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .repository: return "folder"
        case .compare: return "arrow.left.arrow.right"
        case .rebase: return "list.number"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .pullRequests: return "arrow.triangle.pull"
        case .issues: return "circle.dotted"
        case .actions: return "play.circle"
        case .releases: return "tag"
        case .projects: return "rectangle.3.group"
        case .account: return "person.crop.circle"
        case .flows: return "flowchart"
        case .ledger: return "checklist"
        }
    }
}
