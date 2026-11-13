import Foundation

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum AIError: LocalizedError {
    case notConfigured(String)
    var errorDescription: String? { if case .notConfigured(let value) = self { return value }; return nil }
}
enum AgentKind: String {
    case claude, codex, gemini
    var title: String { rawValue }
    var tool: Int { 0 }
}
@MainActor enum PlacementPreference { static var place = AgentCenter.Place.terminal }
@MainActor final class ToolStore {
    static let shared = ToolStore()
    func path(_ tool: Int) -> String? { "/fixture/agent" }
}
@MainActor final class TerminalSession {
    struct Command {
        let program: String
        let args: [String]
        let env: [String: String]
        let title: String
        let pidFile: String
    }
}
@MainActor final class RepoStore {
    var url: URL? = URL(fileURLWithPath: "/fixture/repository")
    var fail = false
    var launches: [TerminalSession.Command] = []
    var errorMessage: String?
    var sessions: [TerminalSession] = []
    func newTerminal(in path: String, command: TerminalSession.Command) -> TerminalSession? {
        if fail { return nil }
        launches.append(command)
        let session = TerminalSession()
        sessions.append(session)
        return session
    }
}
@MainActor enum Launcher {
    static var calls = 0
    static func run(_ executable: String, args: [String], in path: String, env: [String: String], pidFile: String) throws {
        calls += 1
    }
}

/// Argument and hook generation have their own regression suite; these boundaries only record placement.
@MainActor enum AgentLaunch {
    static func arguments(_ kind: AgentKind, hooks: String, task: String, mode: String?) -> [String] {
        [task, mode ?? ""]
    }
    static func environment(agent: String) -> [String: String] { ["GITROCHI_AGENT_ID": agent] }
}

/// The temporary copy inserts the actual start and launch methods here.
@MainActor final class AgentCenter {
    enum Place {
        case app, terminal
        @MainActor static var current: Place { PlacementPreference.place }
    }
    private final class TerminalLink {
        let session: TerminalSession
        let store: RepoStore
        init(_ session: TerminalSession, _ store: RepoStore) { self.session = session; self.store = store }
    }
    private var inApp: [String: TerminalLink] = [:]
    let directory: URL
    var loads = 0
    var lastAgent = ""
    var hooksFile: URL { file("hooks.json") }
    var hookScript: URL { file("hook.sh") }

    init(root: URL) throws {
        directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func load() { loads += 1 }
    func metadataCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".meta") }.count
    }

    /* AGENT_PLACEMENT_METHODS */
}

@main struct AgentPlacementTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func reset() {
            PlacementPreference.place = .terminal
            Launcher.calls = 0
        }

        for kind in [AgentKind.codex, .claude] {
            reset()
            let center = try AgentCenter(root: root), host = RepoStore()
            try center.start(kind, in: "/fixture/repository", task: "Reviewed task", permissionMode: "read-only", host: host, place: .app)
            check(host.launches.count == 1 && Launcher.calls == 0, "Explicit app placement never uses an external terminal")
            check(PlacementPreference.place == .terminal, "Explicit app placement does not change the saved preference")
            check(host.launches[0].args[0] == "Reviewed task", "The reviewed task is preserved")

            reset()
            let missing = try AgentCenter(root: root)
            do {
                try missing.start(kind, in: "/fixture/repository", task: "Task", host: nil, place: .app)
                preconditionFailure("A missing explicit app host was accepted")
            } catch is AIError { checks += 1 }
            check(missing.metadataCount() == 0 && Launcher.calls == 0, "A missing explicit app host fails before metadata")

            reset()
            let failed = try AgentCenter(root: root), failingHost = RepoStore()
            failingHost.fail = true
            do {
                try failed.start(kind, in: "/fixture/repository", task: "Task", host: failingHost, place: .app)
                preconditionFailure("A failed explicit app launch was accepted")
            } catch is AIError { checks += 1 }
            check(Launcher.calls == 0, "A failed explicit app launch cannot fall back externally")

            reset()
            let normal = try AgentCenter(root: root), normalHost = RepoStore()
            try normal.start(kind, in: "/fixture/repository", task: "Task", host: normalHost)
            check(Launcher.calls == 1 && normalHost.launches.isEmpty, "A nil override retains the external preference")

            reset()
            PlacementPreference.place = .app
            let external = try AgentCenter(root: root), externalHost = RepoStore()
            try external.start(kind, in: "/fixture/repository", task: "Task", host: externalHost, place: .terminal)
            check(Launcher.calls == 1 && externalHost.launches.isEmpty && PlacementPreference.place == .app,
                  "An explicit external override preserves the app preference")
        }
        print("Agent placement: \(checks) checks passed without an agent or external terminal")
    }
}
