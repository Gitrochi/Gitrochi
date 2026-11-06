import Foundation

// The linked pull/merge request's state and checks, as the Ledger shows them next to the "#142" chip. The rules here
// are pure so macos/Tools/test-ledger.sh can check them; reading the server is LedgerRequestStatusStore's job.
// (Windows: widgets/ledger-workspace/lib/request-status.ts)

/// A session's request in the open repository's hosting project
struct LedgerRequestLink: Hashable {
    let host: String
    let path: String
    let number: Int
    /// The cache key: one entry per request, whichever session or view asks
    var key: String { host.lowercased() + "/" + path.lowercased() + "#" + String(number) }
}

/// The request's state on the server; draft is an open request marked as a draft
enum LedgerRequestState: String, Hashable {
    case open, draft, merged, closed
}

/// The checks on the request's head commit, summed up for one pill
struct LedgerRequestChecks: Hashable {
    enum State: String, Hashable { case passing, failing, pending }
    let state: State
    /// Failing checks when failing, pending ones when pending, else every check that passed
    let count: Int
}

struct LedgerRequestStatus: Hashable {
    let state: LedgerRequestState
    let checks: LedgerRequestChecks?
}

enum LedgerRequestRules {
    /// A value younger than this is shown as it is; the existing request views read again no sooner either
    static let freshFor: LedgerMs = 60_000

    /// The request the session links to, only when the session belongs to the open repository and the request lives in
    /// that repository's hosting project: one of the session's linked folders is the repository (or, with no folder, its
    /// project is the repository's), and the request's address is under the hosting project's path
    static func link(_ s: LedgerSession, repositoryPath: String?, repositoryProject: String?, host: String?, path: String?) -> LedgerRequestLink? {
        guard let pr = s.links.pr, pr.number > 0, let repositoryPath, !repositoryPath.isEmpty,
              let host, !host.isEmpty, let path, !path.isEmpty else { return nil }
        let linked = [s.links.repoPath, s.links.worktree, s.links.cwd].compactMap { $0 }
        if !linked.isEmpty {
            guard linked.map(folder).contains(folder(repositoryPath)) else { return nil }
        } else {
            guard let repositoryProject, s.project == repositoryProject else { return nil }
        }
        guard let url = URL(string: pr.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == host.lowercased() || pr.host.lowercased() == host.lowercased() else { return nil }
        let project = "/" + path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        guard (url.path.lowercased() + "/").hasPrefix(project) else { return nil }
        return LedgerRequestLink(host: host, path: path, number: pr.number)
    }

    /// Passed, failing or pending over the checks' raw states (CIStatus raw values). Cancelled counts as failing, a job
    /// allowed to fail as passed, and manual or unknown checks are left out. Nil when nothing was reported.
    static func summary(_ checks: [(status: String, allowFailure: Bool)]) -> LedgerRequestChecks? {
        var passed = 0, failed = 0, pending = 0
        for check in checks {
            switch check.status {
            case "success", "neutral", "skipped": passed += 1
            case "failed": if check.allowFailure { passed += 1 } else { failed += 1 }
            case "canceled": failed += 1
            case "created", "waiting", "pending", "running", "scheduled": pending += 1
            default: break
            }
        }
        if failed > 0 { return LedgerRequestChecks(state: .failing, count: failed) }
        if pending > 0 { return LedgerRequestChecks(state: .pending, count: pending) }
        return passed > 0 ? LedgerRequestChecks(state: .passing, count: passed) : nil
    }

    /// "Request merged — mark merged?": the request is merged and the session is not finished. Nothing changes until a
    /// person picks the version.
    static func suggestsMerged(_ s: LedgerSession, _ status: LedgerRequestStatus?) -> Bool {
        status?.state == .merged && !s.status.isFinished
    }

    /// How long to wait before reading again while the request is on screen: as often as the request checks panel
    /// while checks run, every two minutes while it is open, never once it is merged or closed
    static func pollSeconds(_ status: LedgerRequestStatus?) -> Int? {
        guard let status else { return nil }
        switch status.state {
        case .merged, .closed: return nil
        case .open, .draft: return status.checks?.state == .pending ? 20 : 120
        }
    }

    private static func folder(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
    }
}
