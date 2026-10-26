import Foundation
import Observation

/// 저장소마다 하나: 흐름 목록 · 최근 실행 · 지금 따라 읽는 실행. 저장소 화면(RepoStore)과 따로 두어
/// 탭을 닫았다 열어도 돌던 실행을 계속 따라 읽는다.
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
    /// nil: 아직 읽지 않았거나 흐름 파일이 없음
    private(set) var list: FlowList?
    private(set) var hasFlowFile = false
    private(set) var loadError: FlowEngine.Failure?
    private(set) var loading = false
    private(set) var runs: [FlowRunRow] = []
    private(set) var gate: FlowGate?
    /// 실행 ID → 화면 상태(따라 읽는 중이거나 마지막에 본 것)
    private(set) var views: [String: FlowRunView] = [:]
    /// 끝난 실행의 기록(run.json)
    private(set) var records: [String: FlowJSON] = [:]
    private var tails: [String: Task<Void, Never>] = [:]

    init(repo: URL) { self.repo = repo }

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
        // 앱을 다시 열었을 때도 돌고 있는 실행을 이어서 따라 읽는다.
        for r in runs where r.running == true && tails[r.runId] == nil {
            if let rec = try? await FlowEngine.record(r.runId, in: repo), let path = rec["eventsPath"].string {
                follow(runId: r.runId, eventsPath: path)
            }
        }
    }

    /// 실행을 시작하고 이벤트를 따라 읽는다. 실행 ID 를 돌려준다.
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

    /// 끝난 실행을 열면 기록에서 노드 상태를 채운다(따라 읽지 않은 실행).
    func open(_ runId: String) async {
        if views[runId] == nil || records[runId] == nil, let rec = try? await FlowEngine.record(runId, in: repo) {
            records[runId] = rec
            if views[runId] == nil, let path = rec["eventsPath"].string {
                if rec["state"].string.map({ ["RUNNING", "PENDING", "PREFLIGHT", "ROLLING_BACK"].contains($0) }) == true {
                    follow(runId: runId, eventsPath: path)
                } else if let data = FileManager.default.contents(atPath: path) {
                    var v = FlowRunView(runId: runId)
                    _ = v.consume(data)
                    views[runId] = v
                }
            }
        }
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
                    // 오래 조용하면 엔진이 살아 있는지 본다(강제 종료 · 전원 꺼짐이면 run.done 없이 멈춘다).
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
            if let rec = try? await FlowEngine.record(runId, in: self.repo) { self.records[runId] = rec }
            await self.refresh()
        }
    }

    /// 이벤트 파일의 offset 부터 끝까지(없으면 nil)
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
