import Foundation

// The inspector's read-only Checks row: the latest Flow results recorded for the session's branch head commit. The
// rules are pure so macos/Tools/test-ledger.sh can check them; reading the records is LedgerFlowEvidenceStore's job,
// through the Flows workspace's own FlowEngine calls. (Windows: widgets/ledger-workspace/lib/flow-evidence.ts)

/// One finished Flow run as far as the Checks row needs it, from its record (run.json)
struct LedgerFlowRun: Hashable {
    let runId: String
    let flow: String
    /// The engine's run state: SUCCEEDED, FAILED, REJECTED, CANCELLED, ROLLED_BACK, ROLLBACK_FAILED …
    let state: String
    /// The commit the run was recorded for (`git.sha`)
    let sha: String
    /// When it finished, in milliseconds; nil while it runs
    let finishedAt: LedgerMs?
}

/// How a finished run reads in the Ledger: passed, failed, or held for a person
enum LedgerFlowOutcome: String, Hashable {
    case passed, failed, held, canceled

    /// Nil for a run that has not finished: only recorded results are evidence
    init?(state: String) {
        switch state {
        case "SUCCEEDED": self = .passed
        case "FAILED", "ROLLED_BACK": self = .failed
        // refused before running (trust, gate, production guard), or a rollback that failed and put the environment on hold
        case "REJECTED", "ROLLBACK_FAILED": self = .held
        case "CANCELLED": self = .canceled
        default: return nil
        }
    }
}

struct LedgerFlowResult: Hashable, Identifiable {
    let run: LedgerFlowRun
    let outcome: LedgerFlowOutcome
    var id: String { run.runId }
}

enum LedgerFlowEvidence {
    /// The newest finished run of each flow recorded for `head`, newest first. Runs for other commits never count, so a
    /// result always belongs to exactly the commit the branch points at.
    static func latest(_ runs: [LedgerFlowRun], head: String) -> [LedgerFlowResult] {
        guard !head.isEmpty else { return [] }
        var seen = Set<String>()
        return runs
            .filter { $0.sha.caseInsensitiveCompare(head) == .orderedSame && $0.finishedAt != nil }
            .sorted { ($0.finishedAt ?? 0, $0.runId) > ($1.finishedAt ?? 0, $1.runId) }
            .compactMap { run in
                guard let outcome = LedgerFlowOutcome(state: run.state), seen.insert(run.flow).inserted else { return nil }
                return LedgerFlowResult(run: run, outcome: outcome)
            }
    }

    /// Whether the session's folder is the open repository or one of its worktrees; without a folder, whether its
    /// project is the repository's
    static func belongs(_ s: LedgerSession, repositoryPath: String?, worktrees: [String], repositoryProject: String?) -> Bool {
        guard let repositoryPath, !repositoryPath.isEmpty else { return false }
        guard let linked = s.links.repoPath ?? s.links.worktree ?? s.links.cwd else { return repositoryProject != nil && s.project == repositoryProject }
        return ([repositoryPath] + worktrees).map(folder).contains(folder(linked))
    }

    private static func folder(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
    }
}
