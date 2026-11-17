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

/// What Escape does on the repository screen; the first match wins. Whatever takes keys of its own keeps Escape (a
/// sheet, a menu or a popover, the terminal); then an open file history or blame closes, then an open diff; then the
/// sidebar's Filter branches field, when the keys are in it and it has text, is cleared; and last, never from a text
/// field, Changes turns off and the graph is back. (Windows: repositoryEscape)
enum RepositoryEscape: Equatable {
    case none, closeFileInspect, closeDiff, clearFilter, showGraph

    init(overlay: Bool, terminal: Bool, typing: Bool, repositoryScreen: Bool, fileInspect: Bool, diff: Bool, filter: Bool, changes: Bool) {
        if overlay || terminal || !repositoryScreen { self = .none }
        else if fileInspect { self = .closeFileInspect }
        else if diff { self = .closeDiff }
        else if filter { self = .clearFilter }
        else { self = changes && !typing ? .showGraph : .none }
    }
}

/// Where the icon rail and the page sit while the page list is open, folded or sliding between the two
/// (docs/design.md › App shell, Sidebar). The list slides over the rail, so the rail shows only where the list has left
/// it, and the page starts where the list or the rail ends. While the list slides, a page's flexible column keeps the
/// width it has with the list folded and is cut off (WorkspaceColumns): laying it out again on every frame of the
/// slide takes longer than a frame.
struct PageListFold: Equatable {
    /// The rail with its edge line
    static let railWidth: CGFloat = 53
    /// How much of the rail shows beside the list
    let rail: CGFloat
    /// How much wider the page will be once the list has folded; 0 unless the list is sliding
    let overhang: CGFloat

    /// showing: how much of the list is in the window
    init(showing: CGFloat, sliding: Bool) {
        let showing = max(0, showing)
        rail = max(0, Self.railWidth - showing)
        overhang = sliding ? max(0, showing - Self.railWidth) : 0
    }
}

/// The pages of a repository window. Repository is the three-column screen (branches | graph | inspector);
/// the rest are full-width pages. (Windows: entities/git/model/workspace-navigation.ts)
enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home, repository, compare, rebase, code
    case pullRequests, issues, actions, releases, projects, account
    case flows
    var id: String { rawValue }

    /// Restore known pages only.
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
    /// Whether the page can be opened: one that needs a repository is disabled until one is open, so a window without
    /// a repository never shows it (docs/design.md › App shell, Sidebar). (Windows: destinationAvailable)
    func isAvailable(hasRepository: Bool) -> Bool { hasRepository || !needsRepository }
    /// The Go menu's shortcut, ⌘1–⌘8 in the sidebar's order (docs/design.md › App shell, Sidebar). Home is ⇧⌘H;
    /// Releases, Projects and Account have none. (Windows: destinationShortcut)
    var shortcutDigit: Int? {
        switch self {
        case .repository: return 1
        case .compare: return 2
        case .rebase: return 3
        case .code: return 4
        case .pullRequests: return 5
        case .issues: return 6
        case .actions: return 7
        case .flows: return 8
        default: return nil
        }
    }
    /// The shortcut as the sidebar shows it beside the row
    var shortcutLabel: String? { self == .home ? "⇧⌘H" : shortcutDigit.map { "⌘\($0)" } }
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
        }
    }
}
