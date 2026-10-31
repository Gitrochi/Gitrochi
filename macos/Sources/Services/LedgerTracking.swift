import Foundation

/// Settings › Ledger › Track agents I start, and what a tracked launch does before Claude Code starts (DESIGN.md §7.11):
/// the ledger session from the core's `track`, the wait its hooks allow for, and whether to hand it the Ledger tools.
/// Off unless the Ledger is shown and a person turned it on, so every other launch stays as it is on main.
/// (Windows: entities/agent/model/agents.ts)
enum LedgerTracking {
    static let trackKey = "ledgerTrackAgents"
    static let toolsKey = "ledgerAgentTools"

    /// Track agents I start: off until a person turns it on, and only while the Ledger is shown
    static var isOn: Bool { isOn(defaults: .standard, ledgerShown: WorkspaceDestination.ledgerPreview) }
    static func isOn(defaults: UserDefaults, ledgerShown: Bool) -> Bool { ledgerShown && defaults.bool(forKey: trackKey) }
    /// Give them the Ledger tools: on unless a person turned it off
    static var givesTools: Bool { UserDefaults.standard.object(forKey: toolsKey) as? Bool ?? true }

    struct Launch {
        var ledger: AgentLaunch.Ledger
        /// Pass `--mcp-config` for the bundled MCP server
        var tools: Bool
    }

    /// Creates the session for an agent about to start in `folder` of `repository`. The hooks wait as long as the session's
    /// auto-continue wait (its repository's, else the default), so a later, longer wait reaches the agent at its next start.
    static func prepare(agent: String, folder: String, repository: String?, claude: String, client: LedgerClient) async throws -> Launch {
        let command = LedgerCommandLine.bundled
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            throw LedgerFailure(code: "NOT_FOUND", message: String(localized: "The ledger command is missing from this copy of Gitrochi: \(command.path)"))
        }
        let session = try await client.track(cwd: folder, repository: repository, agent: agent)
        var wait = session.autoContinue?.delaySec ?? 0
        if session.autoContinue == nil { wait = try await client.settings().autoContinueDefault.delaySec }
        let database = ProcessInfo.processInfo.environment["GITROCHI_LEDGER_DB"].flatMap { $0.isEmpty ? nil : $0 }
        let tools = givesTools ? await !hasLedgerServer(claude: claude, folder: folder) : false
        return Launch(ledger: .init(session: session.id, command: command.path, wait: wait, database: database), tools: tools)
    }

    /// `claude mcp get gitrochi-ledger` in the folder: a server of that name in the person's own configuration (user,
    /// project or local scope) would be shadowed by a per-launch one, so the launch leaves it alone (#171). A check that
    /// does not finish in time counts as found, for the same reason.
    static func hasLedgerServer(claude: String, folder: String, timeout: TimeInterval = 10) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["mcp", "get", "gitrochi-ledger"]
            process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            process.waitUntilExit()
            killer.cancel()
            return process.terminationReason == .uncaughtSignal || process.terminationStatus == 0
        }.value
    }
}

/// Tells the hooks that a person can answer in Gitrochi: while the app runs with the Ledger shown, it sets the modification
/// time of `app.alive` next to the ledger's database every 5 s. Synchronous hooks wait for an answer only while the file is
/// under 15 s old (DESIGN.md §9.1, D10). Nothing is created before the ledger has a folder. (Windows: src-tauri/src/ledger.rs)
@MainActor
final class LedgerHeartbeat {
    static let shared = LedgerHeartbeat()
    private var timer: Timer?

    func start() {
        guard timer == nil, WorkspaceDestination.ledgerPreview, ProcessInfo.processInfo.environment["GITROCHI_LEDGER"] != "0" else { return }
        let file = Self.file()
        Self.beat(file)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { LedgerHeartbeat.beat(file) }
        }
    }

    /// `app.alive` in the database's folder: GITROCHI_LEDGER_DB's when it is set, else Application Support/Gitrochi/ledger
    nonisolated static func file(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let db = environment["GITROCHI_LEDGER_DB"], !db.isEmpty {
            return URL(fileURLWithPath: db).deletingLastPathComponent().appendingPathComponent("app.alive")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gitrochi/ledger/app.alive")
    }

    /// Sets the time explicitly, so a file that already exists gets a new one too
    nonisolated static func beat(_ file: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: Data()) }
        try? manager.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
}
