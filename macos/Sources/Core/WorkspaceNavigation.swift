import Foundation

/// The pages of a repository window. Repository is the three-column screen (branches | graph | inspector);
/// the rest are full-width pages. (Windows: entities/git/model/workspace-navigation.ts)
enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home, repository, compare, rebase, code
    case pullRequests, issues, actions, releases, projects, account
    case flows, ledger
    var id: String { rawValue }

    /// A remembered page that is not shown (Ledger without its preview) reads as unknown, so the default page opens
    init?(rawValue: String) {
        guard let page = Self.allCases.first(where: { $0.rawValue == rawValue }), page.isShown else { return nil }
        self = page
    }

    /// Ledger stays hidden until its core is connected: GITROCHI_LEDGER_PREVIEW=1 shows it on demo data
    /// (GITROCHI_LEDGER_DEMO=large or =empty picks the large or the empty demo)
    static let ledgerPreview = ProcessInfo.processInfo.environment["GITROCHI_LEDGER_PREVIEW"] == "1"
    var isShown: Bool { self != .ledger || Self.ledgerPreview }
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
