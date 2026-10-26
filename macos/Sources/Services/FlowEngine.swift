import Foundation

/// 흐름 엔진(gitch-flow, tools/gitch-flow) 부르기. 앱에 든 엔진(Contents/MacOS/gitch-flow)을 먼저 쓰고,
/// 없으면 셸 명령 gitch 옆 · ~/.local/share/gitch 의 것을 쓴다.
/// 앱이 보내는 것은 사람이 누른 동작뿐이라 실행 주체를 gitrochi-app 으로 밝힌다 — 엔진의 신뢰 · 확인 규칙은 그대로다
/// (AI 가 부르는 gitch flow 는 신뢰 승인 · 게이트 · 잠금 해제를 할 수 없다).
enum FlowEngine {
    struct Failure: LocalizedError, Equatable {
        let message: String
        /// 엔진의 실패 코드(TRUST-01 · SPEC-02 …). 없으면 nil
        var code: String? = nil
        /// 엔진이 알려 준 조치
        var action: String? = nil
        var errorDescription: String? { message }
    }

    /// 쓸 엔진 경로. 하나도 없으면 nil
    static var executable: String? {
        let fm = FileManager.default
        var candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gitch-flow").path]
        if let link = Bundle.main.path(forResource: "gitch-flow", ofType: nil) { candidates.append(link) }
        if let g = Gitch.installed { candidates.append((g as NSString).deletingLastPathComponent + "/gitch-flow") }
        candidates.append(NSHomeDirectory() + "/.local/share/gitch/gitch-flow")
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static var environment: [String: String] {
        var env = Gitch.environment
        env["GITSW_ACTOR"] = "gitrochi-app"
        env["GITCH_FLOW_LANG"] = AppLanguage.current.hasPrefix("ko") ? "ko" : "en"
        // 엔진이 영향 그래프 · gitch 블록에서 gitch 를 되부를 때
        if let g = Gitch.bundled ?? Gitch.installed { env["GITCH_PATH"] = g }
        env["GITCH_BASH"] = "/bin/bash"
        return env
    }

    @discardableResult
    static func run(_ args: [String], in repo: URL, timeout: TimeInterval = 120) async throws -> GitResult {
        guard let exe = executable else {
            throw Failure(message: String(localized: "The flow engine (gitch-flow) isn't in this Gitrochi. Update Gitrochi, or build it with tools/gitch-flow/build.sh."), code: "ENGINE-03")
        }
        return try await Shell.run(exe, args, cwd: repo, env: environment, timeout: timeout)
    }

    /// JSON 을 내는 명령. 실패하면 엔진의 오류 봉투(표준오류의 마지막 JSON 줄)로 던진다.
    static func json<T: Decodable>(_ args: [String], in repo: URL, ok: Set<Int32> = [0], timeout: TimeInterval = 120) async throws -> T {
        let r = try await run(args + ["--json"], in: repo, timeout: timeout)
        if ok.contains(r.status), let v = try? JSONDecoder().decode(T.self, from: r.data) { return v }
        throw failure(r)
    }

    static func failure(_ r: GitResult) -> Failure {
        for line in r.stderr.split(separator: "\n").reversed() {
            if let env = try? JSONDecoder().decode(FlowErrorEnvelope.self, from: Data(line.utf8)) {
                return Failure(message: env.error.message, code: env.error.flowCode ?? env.error.code, action: env.error.action)
            }
        }
        let text = (r.stderr.isEmpty ? r.output : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return Failure(message: text.isEmpty ? "exit \(r.status)" : String(text.prefix(2000)))
    }

    /// 흐름 파일이 있는지(엔진을 부르기 전에 빨리)
    static func hasFlowFile(in repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(".gitch/flow.yml").path)
    }

    static func list(in repo: URL) async throws -> FlowList { try await json(["list"], in: repo) }

    static func plan(_ flow: String, in repo: URL, affected: Bool = false) async throws -> FlowPlan {
        try await json(["plan", flow] + (affected ? ["--affected=worktree"] : []), in: repo)
    }

    /// 사람이 신뢰 확인 화면에서 승인했을 때만 부른다.
    static func trust(in repo: URL) async throws {
        let r = try await run(["trust", "--yes", "--json"], in: repo)
        guard r.status == 0 else { throw failure(r) }
    }

    /// 분리 실행: 엔진이 뒤에서 돌고 앱은 이벤트 파일을 따라 읽는다(앱을 닫아도 실행은 끝까지 간다).
    static func start(_ flow: String, in repo: URL, affected: Bool, yes: Bool) async throws -> FlowDetached {
        var args = ["run", flow, "--detach", "--trigger", "app"]
        if affected { args.append("--affected=worktree") }
        if yes { args.append("--yes") }
        return try await json(args, in: repo)
    }

    static func cancel(_ runId: String, in repo: URL) async throws {
        let r = try await run(["cancel", runId, "--json"], in: repo)
        guard r.status == 0 else { throw failure(r) }
    }

    static func runs(in repo: URL) async throws -> [FlowRunRow] {
        struct All: Decodable { let runs: [FlowRunRow] }
        let all: All = try await json(["status", "--all"], in: repo)
        return all.runs
    }

    /// 끝난 실행의 기록 전체(run.json — 노드별 판정 · 실패 위치 · 되돌림)
    static func record(_ runId: String, in repo: URL) async throws -> FlowJSON {
        try await json(["status", runId], in: repo, ok: [0, 1])
    }

    /// 사람 · AI 에게 붙여 넣기 좋은 Markdown 요약
    static func markdown(_ runId: String, in repo: URL) async throws -> String {
        let r = try await run(["report", runId, "--format", "md"], in: repo)
        guard r.status == 0 else { throw failure(r) }
        return r.output
    }

    static func proposeInit(in repo: URL) async throws -> FlowInitProposal { try await json(["init", "--dry-run"], in: repo) }

    static func writeInit(in repo: URL) async throws {
        let r = try await run(["init", "--yes", "--json"], in: repo)
        guard r.status == 0 else { throw failure(r) }
    }

    static func gate(in repo: URL) async throws -> FlowGate { try await json(["gate", "status"], in: repo) }

    static func setGate(_ on: Bool, flow: String, in repo: URL) async throws {
        let r = try await run(["gate", on ? "on" : "off"] + (on ? ["--flow", flow] : []) + ["--json"], in: repo)
        guard r.status == 0 else { throw failure(r) }
    }
}
