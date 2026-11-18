import Foundation

/// A commit of the branch that already has runs (GitHub) or pipelines (GitLab) on that branch. Hosting APIs start new
/// runs only on a branch's tip, so a chosen commit runs again through one of its own: GitLab presses a job of its
/// pipeline, GitHub re-runs one of its workflow runs. (Windows: entities/ci/model/run-commits.ts › RunCommit)
struct RunCommit: Hashable, Identifiable {
    let sha: String
    let subject: String
    /// When its newest run was made
    let created: Date?
    /// Its runs on the branch, newest first
    let runs: [CIPipeline]
    var id: String { sha }
    var short: String { String(sha.prefix(7)) }
}

/// Which commits a run sheet offers and what starting one does. Pure, so it mirrors the tested Windows functions.
/// (Windows: entities/ci/model/run-commits.ts)
enum RunCommits {
    /// How many commits the sheet offers (Windows: runCommitLimit)
    static let limit = 30

    /// What starting a chosen GitLab job does now (Windows: commitJobAction)
    enum JobAction: Equatable { case play, retry, busy, unavailable }

    /// The branch's commits with runs on it, newest first, each with its runs. Subjects come from the local log, else
    /// from the run's own title. (Windows: runCommits)
    static func commits(_ runs: [CIPipeline], branch: String, subjects: [String: String], limit: Int = limit) -> [RunCommit] {
        var order: [String] = []
        var bySha: [String: [CIPipeline]] = [:]
        for run in runs where run.ref == branch {
            if bySha[run.sha] == nil { order.append(run.sha) }
            bySha[run.sha, default: []].append(run)
        }
        return order.prefix(limit).map { sha in
            let list = bySha[sha] ?? []
            let subject = subjects[sha] ?? list.first(where: { !$0.title.isEmpty })?.title ?? ""
            return RunCommit(sha: sha, subject: subject, created: list.first?.created, runs: list)
        }
    }

    /// GitHub: the newest run of each workflow, the ones a chosen commit can re-run (Windows: commitWorkflowRuns)
    static func workflowRuns(_ commit: RunCommit) -> [CIPipeline] {
        var seen = Set<String>()
        return commit.runs.filter { seen.insert($0.name).inserted }
    }

    /// GitLab: the pipeline's jobs with the manual ones first, the rest in the server's order (Windows: commitJobs)
    static func jobs(_ jobs: [CIJob]) -> [CIJob] {
        jobs.filter(\.canPlay) + jobs.filter { !$0.canPlay }
    }

    /// The job the sheet starts on: the first manual one, else the first (Windows: defaultCommitJob)
    static func defaultJob(_ jobs: [CIJob]) -> CIJob? {
        jobs.first(where: \.canPlay) ?? jobs.first
    }

    /// A manual or delayed job is pressed, a finished one retried, a running one left alone (Windows: commitJobAction)
    static func jobAction(_ status: CIStatus) -> JobAction {
        switch status {
        case .manual, .scheduled: return .play
        case .success, .failed, .canceled: return .retry
        case .created, .waiting, .pending, .running: return .busy
        case .skipped, .neutral, .unknown: return .unavailable
        }
    }

    /// GitHub: a run still going is not re-run a second time (Windows: commitRunBusy)
    static func runBusy(_ status: CIStatus) -> Bool { status.isActive }

    /// `log --format=%H%x1f%s` output as subjects by SHA (Windows: parseCommitSubjects)
    static func subjects(_ output: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].count >= 7 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }
}
