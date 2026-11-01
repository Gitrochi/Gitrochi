import Foundation
import Observation

/// One per repository: the flows, recent runs and the run being followed. Kept apart from the repository screen (RepoStore)
/// so a run keeps being followed after its tab is closed and reopened.
@MainActor
final class FlowCenter {
    static let shared = FlowCenter()
    private var stores: [String: FlowStore] = [:]

    func store(for repo: URL) -> FlowStore {
        let key = repo.standardizedFileURL.path
        if let s = stores[key] { return s }
        let s = FlowStore(repo: repo)
        stores[key] = s
        return s
    }
}

@MainActor @Observable
final class FlowStore {
    let repo: URL
    /// nil: not read yet, or no flow file
    private(set) var list: FlowList?
    private(set) var hasFlowFile = false
    private(set) var loadError: FlowEngine.Failure?
    private(set) var loading = false
    private(set) var runs: [FlowRunRow] = []
    private(set) var gate: FlowGate?
    /// Run ID → screen state (being followed, or as last seen)
    private(set) var views: [String: FlowRunView] = [:]
    /// Records of finished runs (run.json)
    private(set) var records: [String: FlowJSON] = [:]
    private var tails: [String: Task<Void, Never>] = [:]
    var validationBindings: [ValidationBinding]
    private var validationKey: String { "workValidation:" + repo.standardizedFileURL.path }

    init(repo: URL) {
        self.repo = repo
        validationBindings = UserDefaults.standard.data(forKey: "workValidation:" + repo.standardizedFileURL.path).flatMap { try? JSONDecoder().decode([ValidationBinding].self, from: $0) } ?? []
    }

    private func saveValidation() {
        if let data = try? JSONEncoder().encode(Array(validationBindings.suffix(100))) { UserDefaults.standard.set(data, forKey: validationKey) }
    }

    /// Local trusted plans can bind their actual run to the observed working contents.
    func startVerified(_ flow: String, candidates: [String]) async throws -> String {
        let plan = try await FlowEngine.plan(flow, in: repo)
        guard plan.trust.trusted, plan.outward.isEmpty, plan.gates.isEmpty,
              !plan.nodes.contains(where: { $0.decision == "run" && ($0.destructive == true || $0.outward == true || ($0.executor != nil && $0.executor != "local")) }) else {
            throw FlowEngine.Failure(message: String(localized: "Review and approve this flow in the Flows workspace before running it here."))
        }
        let before = try await WorkStamp.read(in: repo)
        let run = try await FlowEngine.start(flow, in: repo, affected: false, yes: false)
        validationBindings.append(ValidationBinding(runID: run.runId, head: before.head, before: before.stamp, candidates: candidates, observedAt: ISO8601DateFormatter().string(from: Date())))
        saveValidation()
        follow(runId: run.runId, eventsPath: run.eventsPath)
        Task { await refresh() }
        return run.runId
    }

    var engineAvailable: Bool { FlowEngine.executable != nil }

    func refresh() async {
        hasFlowFile = FlowEngine.hasFlowFile(in: repo)
        guard engineAvailable else { return }
        loading = true
        defer { loading = false }
        if hasFlowFile {
            do {
                list = try await FlowEngine.list(in: repo)
                loadError = nil
            } catch let e as FlowEngine.Failure {
                list = nil
                loadError = e
            } catch {
                loadError = FlowEngine.Failure(message: error.localizedDescription)
            }
        } else {
            list = nil
            loadError = nil
        }
        runs = (try? await FlowEngine.runs(in: repo)) ?? []
        gate = try? await FlowEngine.gate(in: repo)
        // After the app reopens, keep following runs that are still going.
        for r in runs where r.running == true && tails[r.runId] == nil {
            if let rec = try? await FlowEngine.record(r.runId, in: repo), let path = rec["eventsPath"].string {
                follow(runId: r.runId, eventsPath: path)
            }
        }
    }

    /// Starts a run and follows its events. Returns the run ID.
    func start(_ flow: String, affected: Bool, yes: Bool) async throws -> String {
        let d = try await FlowEngine.start(flow, in: repo, affected: affected, yes: yes)
        follow(runId: d.runId, eventsPath: d.eventsPath)
        Task { await refresh() }
        return d.runId
    }

    func cancel(_ runId: String) async throws {
        try await FlowEngine.cancel(runId, in: repo)
    }

    func trust() async throws {
        try await FlowEngine.trust(in: repo)
        await refresh()
    }

    func setGate(_ on: Bool, flow: String) async throws {
        try await FlowEngine.setGate(on, flow: flow, in: repo)
        gate = try? await FlowEngine.gate(in: repo)
    }

    func view(_ runId: String) -> FlowRunView? { views[runId] }

    func record(_ runId: String) -> FlowJSON? { records[runId] }

    /// Final records remain readable even when the event stream is missing or ends before run.done.
    func open(_ runId: String) async {
        guard let rec = try? await FlowEngine.record(runId, in: repo) else { return }
        records[runId] = rec
        guard tails[runId] == nil else { return }
        var view = views[runId] ?? FlowRunView(runId: runId)
        if views[runId] == nil, let path = rec["eventsPath"].string,
           let data = await Task.detached(operation: { FileManager.default.contents(atPath: path) }).value {
            _ = view.consume(data)
        }
        let plan = await Self.savedPlan(rec)
        let observedRunning = runs.first(where: { $0.runId == runId })?.running
        views[runId] = FlowRunHistory.recover(view, record: rec, savedPlan: plan, observedRunning: observedRunning)
        if views[runId]?.done != true, FlowRunHistory.isRunning(rec, observedRunning: observedRunning), let path = rec["eventsPath"].string {
            follow(runId: runId, eventsPath: path)
        }
    }

    private nonisolated static func savedPlan(_ record: FlowJSON) async -> FlowJSON? {
        let directory = record["runDir"].string.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? record["eventsPath"].string.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard let directory else { return nil }
        return await Task.detached {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("plan.json")) else { return nil }
            return try? JSONDecoder().decode(FlowJSON.self, from: data)
        }.value
    }

    private func follow(runId: String, eventsPath: String) {
        guard tails[runId] == nil else { return }
        if views[runId] == nil { views[runId] = FlowRunView(runId: runId) }
        tails[runId] = Task { [weak self] in
            var offset: UInt64 = 0
            var quiet = 0
            while !Task.isCancelled {
                let chunk = await Task.detached { FlowStore.read(eventsPath, from: offset) }.value
                guard let self else { return }
                if let chunk, !chunk.isEmpty {
                    var v = self.views[runId] ?? FlowRunView(runId: runId)
                    offset += UInt64(v.consume(chunk))
                    self.views[runId] = v
                    quiet = 0
                    if v.done { break }
                } else {
                    quiet += 1
                    // After a long silence, check that the engine is alive (a killed engine or a power cut stops without run.done).
                    if quiet % 20 == 0, let row = (try? await FlowEngine.runs(in: self.repo))?.first(where: { $0.runId == runId }), row.running != true {
                        var v = self.views[runId] ?? FlowRunView(runId: runId)
                        v.state = row.state
                        v.code = row.code
                        v.done = true
                        self.views[runId] = v
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let self else { return }
            self.tails[runId] = nil
            if let rec = try? await FlowEngine.record(runId, in: self.repo) {
                self.records[runId] = rec
                self.views[runId] = FlowRunHistory.recover(self.views[runId] ?? FlowRunView(runId: runId), record: rec, savedPlan: await Self.savedPlan(rec))
            }
            if !Task.isCancelled, let record = self.records[runId], record["finishedAt"].string != nil,
               ["SUCCEEDED", "FAILED", "REJECTED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED"].contains(record["state"].string ?? ""),
               let index = self.validationBindings.firstIndex(where: { $0.runID == runId && $0.after == nil }),
               let current = try? await WorkStamp.read(in: self.repo) {
                self.validationBindings[index].after = current.stamp
                self.saveValidation()
            }
            await self.refresh()
        }
    }

    /// The events file from offset to the end (nil when missing)
    nonisolated static func read(_ path: String, from offset: UInt64) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: offset)
            return try h.readToEnd()
        } catch {
            return nil
        }
    }
}
