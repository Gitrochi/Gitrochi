import Foundation
import Observation

/// The state and checks of requests linked to Ledger sessions, read through the open repository's own hosting access
/// (`resolveCollaborationAccess`, `CollaborationAPI`, `RequestChecksAPI`): no other client and no token of its own. One
/// cache for the app, so the Inbox and the inspector share a read; it only reads, and never changes a Ledger status.
/// (Windows: widgets/ledger-workspace/model/request-status.ts)
@MainActor @Observable final class LedgerRequestStatusStore {
    static let shared = LedgerRequestStatusStore()

    private(set) var statuses: [String: LedgerRequestStatus] = [:]
    @ObservationIgnored private var readAt: [String: LedgerMs] = [:]
    /// When a read last failed, so a server that refuses is not asked again sooner than a value would be
    @ObservationIgnored private var failedAt: [String: LedgerMs] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    func status(_ link: LedgerRequestLink?) -> LedgerRequestStatus? { link.flatMap { statuses[$0.key] } }

    /// The session's request, only when the window's repository is the session's and has a host and an account;
    /// otherwise nil and the Ledger shows the chip as it always did
    static func link(_ s: LedgerSession, repository store: RepoStore?, project: String?) -> LedgerRequestLink? {
        guard let store, let target = store.target, store.hostingAccount != nil else { return nil }
        return LedgerRequestRules.link(s, repositoryPath: store.url?.path, repositoryProject: project, host: target.host, path: target.path)
    }

    /// Reads the request unless a value younger than `maxAge` is cached; views asking for one request at once share one read
    func refresh(_ link: LedgerRequestLink, in store: RepoStore, maxAge: LedgerMs = LedgerRequestRules.freshFor) async {
        let key = link.key, now = Self.now()
        if let read = readAt[key], now - read < maxAge { return }
        if let failed = failedAt[key], now - failed < LedgerRequestRules.freshFor { return }
        guard !reading.contains(key), let target = store.target,
              target.host.caseInsensitiveCompare(link.host) == .orderedSame, target.path.caseInsensitiveCompare(link.path) == .orderedSame else { return }
        reading.insert(key)
        defer { reading.remove(key) }
        guard var c = await store.resolveCollaborationAccess() else { return }
        let path = store.url?.path
        c.isCurrent = { [weak store] in store?.url?.path == path && store?.target == target }
        do {
            let request = try await CollaborationAPI.requestState(c, link.number)
            var checks: LedgerRequestChecks?
            if !request.headSHA.isEmpty, let results = try? await RequestChecksAPI.load(c, number: link.number, headSHA: request.headSHA) {
                // GitLab lists the pipeline and its jobs; the jobs are the checks
                let jobs = results.checks.contains { $0.id.hasPrefix("job:") }
                checks = LedgerRequestRules.summary(results.checks.filter { !(jobs && $0.id.hasPrefix("pipeline:")) }
                    .map { (status: $0.status.rawValue, allowFailure: $0.allowFailure) })
            }
            guard !Task.isCancelled, c.isCurrent?() != false else { return }
            let state: LedgerRequestState = request.state == "merged" ? .merged : request.state == "closed" ? .closed : request.draft ? .draft : .open
            let next = LedgerRequestStatus(state: state, checks: checks)
            readAt[key] = Self.now()
            failedAt[key] = nil
            if statuses[key] != next { statuses[key] = next }
        } catch {
            // a closed inspector cancels its read; that is not the server's failure
            if !(error is CancellationError) && !Task.isCancelled { failedAt[key] = Self.now() }
        }
    }

    private static func now() -> LedgerMs { LedgerMs(Date().timeIntervalSince1970 * 1000) }
}
