import Foundation

/// Calls the flow engine (gitch-flow, tools/gitch-flow). The engine in the app (Contents/MacOS/gitch-flow) comes first,
/// then the one next to the shell's gitch or in ~/.local/share/gitch.
/// The app sends only actions a person clicked, so it identifies itself as gitrochi-app; the engine's trust and confirmation rules still apply
/// (gitch flow called by an AI agent can never approve trust, switch the gate or release a hold).
enum FlowEngine {
    struct Failure: LocalizedError, Equatable {
        let message: String
        /// The engine's failure code (TRUST-01, SPEC-02 …), or nil
        var code: String? = nil
        /// What the engine says to do
        var action: String? = nil
        var errorDescription: String? { message }
    }

    /// The engine to use, or nil when there is none
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
        // For when the engine calls gitch back (the affected graph, gitch blocks)
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

    /// A command that prints JSON. On failure it throws the engine's error envelope (the last JSON line on stderr).
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

    /// Whether a flow file exists (a quick check before calling the engine)
    static func hasFlowFile(in repo: URL) -> Bool {
        configurationFiles(in: repo).contains { $0 == ".gitch/flow.yml" || $0 == ".gitch/flow.yaml" || $0.hasPrefix(".gitch/flows/") }
    }

    static func list(in repo: URL) async throws -> FlowList { try await json(["list"], in: repo) }

    static func plan(_ flow: String, in repo: URL, affected: Bool = false) async throws -> FlowPlan {
        try await json(["plan", flow] + (affected ? ["--affected=worktree"] : []), in: repo)
    }

    /// Called only after a person approved in the trust sheet.
    static func trust(in repo: URL) async throws {
        let r = try await run(["trust", "--yes", "--json"], in: repo)
        guard r.status == 0 else { throw failure(r) }
    }

    /// Detached run: the engine runs in the background and the app follows the events file (the run finishes even if the app quits).
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

    /// The full record of a finished run (run.json: verdict per node, failure locations, rollback)
    static func record(_ runId: String, in repo: URL) async throws -> FlowJSON {
        try await json(["status", runId], in: repo, ok: [0, 1])
    }

    /// A Markdown summary that is easy to paste for people or AI agents
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
