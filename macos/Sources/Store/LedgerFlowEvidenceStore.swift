import Foundation
import Observation

/// The Checks row's evidence: Flow results recorded for a session's branch head, read the way the Flows workspace reads
/// them (`FlowEngine.runs`, `FlowEngine.record`, which only read run records) and `git rev-parse` for the head. It never
/// starts a run or touches flow files, trust or records. Finished records never change, so each is read once.
/// (Windows: widgets/ledger-workspace/model/flow-evidence.ts)
@MainActor @Observable final class LedgerFlowEvidenceStore {
    static let shared = LedgerFlowEvidenceStore()

    /// What the row shows for one branch in one repository
    struct Evidence: Equatable {
        let head: String
        let results: [LedgerFlowResult]
    }

    /// How many of each folder's newest runs are looked at: the Flows history lists at most 50
    static let runsRead = 20

    private(set) var evidence: [String: Evidence] = [:]
    @ObservationIgnored private var records: [String: LedgerFlowRun] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    /// One entry per repository and branch
    static func key(repository: String, branch: String) -> String { repository + "\0" + branch }

    /// The folders whose run records can hold the branch's results: the repository, and its worktrees that have the
    /// branch checked out or that the session names (runs are recorded per worktree)
    static func folders(repository: URL, worktrees: [Worktree], branch: String, sessionWorktree: String?) -> [URL] {
        let short = { (b: String) in b.hasPrefix("refs/heads/") ? String(b.dropFirst("refs/heads/".count)) : b }
        let same = { (a: String, b: String) in URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path }
        let others = worktrees.filter { w in
            !w.prunable && !same(w.path, repository.path) && (w.branch.map(short) == short(branch) || sessionWorktree.map { same($0, w.path) } == true)
        }
        return [repository] + others.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    func evidence(repository: String, branch: String) -> Evidence? { evidence[Self.key(repository: repository, branch: branch)] }

    /// Reads the branch's head and the newest run records of each folder; without the engine or the branch, nothing
    func refresh(repository: URL, branch: String, folders: [URL]) async {
        let key = Self.key(repository: repository.path, branch: branch)
        guard !reading.contains(key) else { return }
        reading.insert(key)
        defer { reading.remove(key) }
        guard FlowEngine.executable != nil, !branch.isEmpty,
              let head = try? await Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch + "^{commit}"], in: repository).output.trimmed,
              !head.isEmpty else {
            if evidence[key] != nil { evidence[key] = nil }
            return
        }
        var runs: [LedgerFlowRun] = []
        for folder in folders {
            guard !Task.isCancelled, let rows = try? await FlowEngine.runs(in: folder) else { continue }
            for row in rows.prefix(Self.runsRead) where row.running != true {
                let id = folder.standardizedFileURL.path + "\0" + row.runId
                if let known = records[id] { runs.append(known); continue }
                guard !Task.isCancelled, let record = try? await FlowEngine.record(row.runId, in: folder) else { continue }
                let finished = record["finishedAt"].string.flatMap { ISO8601DateFormatter.flow.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                let run = LedgerFlowRun(runId: row.runId, flow: record["flow"].string ?? row.flow, state: record["state"].string ?? row.state,
                                        sha: record["git"]["sha"].string ?? "", finishedAt: finished.map { LedgerMs($0.timeIntervalSince1970 * 1000) })
                if run.finishedAt != nil { records[id] = run }
                runs.append(run)
            }
        }
        guard !Task.isCancelled else { return }
        let next = Evidence(head: head, results: LedgerFlowEvidence.latest(runs, head: head))
        if evidence[key] != next { evidence[key] = next }
    }
}
