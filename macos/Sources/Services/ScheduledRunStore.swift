import AppKit

/// Every repository's runs scheduled for later, and the clock that starts them while the app is open: at launch, on
/// wake and every 30 seconds, whether or not the repository is open. Kept in the user defaults, without tokens.
/// (Windows: entities/ci/model/scheduled-run-store.ts)
@MainActor @Observable
final class ScheduledRunStore {
    static let shared = ScheduledRunStore()
    private static let key = "scheduledRuns"

    private(set) var runs: [ScheduledRun] = []
    /// Runs being started now, so a check meanwhile does not start one twice
    private(set) var starting: Set<String> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private init() {
        runs = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([ScheduledRun].self, from: $0) } ?? []
    }

    /// Called once at launch
    func start() {
        guard timer == nil else { return }
        check()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ScheduledRuns.interval))
                self?.check()
            }
        }
    }

    /// The repository's runs, soonest first
    func runs(for repoPath: String) -> [ScheduledRun] {
        runs.filter { RepoStore.samePath($0.repoPath, repoPath) }.sorted { $0.runAt < $1.runAt }
    }

    func add(_ run: ScheduledRun) {
        runs.append(run)
        save()
    }

    func remove(_ id: String) {
        runs.removeAll { $0.id == id }
        save()
    }

    /// Run now on a missed or failed run: starts it at once
    func runNow(_ id: String) {
        if let run = runs.first(where: { $0.id == id }) { begin(run) }
    }

    /// Starts the runs that are due and marks the ones found too late as missed (ScheduledRuns.action)
    func check(now: Date = Date()) {
        for run in runs where !starting.contains(run.id) {
            switch ScheduledRuns.action(run, now: now) {
            case .wait: break
            case .start: begin(run)
            case .miss: update(run.id) { $0.state = .missed; $0.message = nil }
            }
        }
    }

    private func begin(_ run: ScheduledRun) {
        guard starting.insert(run.id).inserted else { return }
        Task {
            defer { starting.remove(run.id) }
            do {
                try await Self.dispatch(run)
                remove(run.id)
                refresh(run)
            } catch {
                update(run.id) { $0.state = .failed; $0.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    /// The same calls as the run sheet, with the saved account's token read now
    private static func dispatch(_ run: ScheduledRun) async throws {
        let accounts = AccountStore.shared
        guard let account = accounts.accounts.first(where: { $0.id == run.accountID }) else {
            throw Failure(errorDescription: String(localized: "The account for this run is no longer connected."))
        }
        guard let token = await accounts.loadToken(for: account) else {
            throw Failure(errorDescription: String(localized: "Couldn't read the account's token."))
        }
        switch run.provider {
        case .gitlab:
            try await CIAPI.runPipeline(run.target, token: token, apiBase: account.apiBase, ref: run.ref,
                                        variables: run.variables.map { ($0.key, $0.value) })
        case .github:
            guard let workflow = run.workflowID else { throw Failure(errorDescription: String(localized: "This branch has no workflow with 'Run workflow' (workflow_dispatch).")) }
            try await CIAPI.dispatch(run.target, token: token, apiBase: account.apiBase, workflow: workflow, ref: run.ref, inputs: run.inputs)
        }
    }

    /// An open repository shows the new run; a dispatched workflow takes a few seconds to appear in the list
    private func refresh(_ run: ScheduledRun) {
        for store in Workspace.shared.openRepositories where store.url.map({ RepoStore.samePath($0.path, run.repoPath) }) == true {
            Task {
                try? await Task.sleep(for: .milliseconds(run.provider == .github ? 4000 : 700))
                await store.loadCI(silent: true)
            }
        }
    }

    private func update(_ id: String, _ change: (inout ScheduledRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[i])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(runs) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }
}
