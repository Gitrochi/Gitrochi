import Foundation

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home, repositories, repository, changes, commits, branches, compare, rebase, code
    case inbox, myWork, pullRequests, issues, actions, releases, projects, organizations, gists
    case assistant, agents, flows, worktrees, operations
    var id: String { rawValue }
    var repositorySection: RepositorySection? { RepositorySection(rawValue: rawValue) }
    var needsRepository: Bool { [.repository, .changes, .commits, .branches, .compare, .rebase, .code, .pullRequests, .actions, .assistant, .agents, .flows, .worktrees].contains(self) }
    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .repositories: return String(localized: "Repository library")
        case .repository: return String(localized: "Repository")
        case .changes: return String(localized: "Changes")
        case .commits: return String(localized: "Commits")
        case .branches: return String(localized: "Branches")
        case .compare: return String(localized: "Compare")
        case .rebase: return String(localized: "Rebase")
        case .code: return String(localized: "Code")
        case .inbox: return String(localized: "Inbox")
        case .myWork: return String(localized: "My work")
        case .pullRequests: return String(localized: "Pull requests")
        case .issues: return String(localized: "Issues")
        case .actions: return String(localized: "Actions")
        case .releases: return String(localized: "Releases")
        case .projects: return String(localized: "Projects")
        case .organizations: return String(localized: "Organizations")
        case .gists: return "Gists"
        case .assistant: return String(localized: "Repository assistant")
        case .agents: return String(localized: "Agents")
        case .flows: return String(localized: "Flows")
        case .worktrees: return String(localized: "Worktrees")
        case .operations: return String(localized: "Tools and diagnosis")
        }
    }
    func title(gitlab: Bool) -> String {
        if gitlab {
            switch self {
            case .pullRequests: return String(localized: "Merge requests")
            case .actions: return String(localized: "Pipelines")
            case .organizations: return String(localized: "Groups")
            case .gists: return String(localized: "Snippets")
            default: break
            }
        }
        return title
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .repositories: return "externaldrive"
        case .repository: return "folder"
        case .changes: return "doc.badge.plus"
        case .commits: return "circle"
        case .branches: return "arrow.triangle.branch"
        case .compare: return "arrow.left.arrow.right"
        case .rebase: return "list.number"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .inbox: return "tray"
        case .myWork: return "person.crop.rectangle"
        case .pullRequests: return "arrow.triangle.pull"
        case .issues: return "circle.dotted"
        case .actions: return "play.circle"
        case .releases: return "tag"
        case .projects: return "rectangle.3.group"
        case .organizations: return "building.2"
        case .gists: return "curlybraces"
        case .assistant: return "sparkles"
        case .agents: return "person.2.wave.2"
        case .flows: return "flowchart"
        case .worktrees: return "square.stack.3d.up"
        case .operations: return "wrench.and.screwdriver"
        }
    }
}

/// 저장소 작업은 한 화면 안에서 전환하며 필요한 작업만 왼쪽에 고정한다.
enum RepositorySection: String, CaseIterable, Identifiable {
    case changes, commits, branches, compare, rebase, code
    var id: String { rawValue }
    var destination: WorkspaceDestination { WorkspaceDestination(rawValue: rawValue)! }
    var title: String { destination.title }
    var symbol: String { destination.symbol }
}

struct WorkspaceLocation: Equatable {
    var destination: WorkspaceDestination
    var repositorySection: RepositorySection
    init(_ destination: WorkspaceDestination, section: RepositorySection = .changes) {
        self.destination = destination.repositorySection == nil ? destination : .repository
        self.repositorySection = destination.repositorySection ?? section
    }
}
