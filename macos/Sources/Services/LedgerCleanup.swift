import Foundation

/// Gitrochi no longer has a Ledger. A person who connected Claude Code or Codex to it still has its hooks and MCP server
/// in those clients' settings, and they run the copy of the ledger command under Application Support/Gitrochi/bin. While
/// that copy exists, this has it take out its own hooks and browser host, has each client drop the MCP server, and
/// deletes the copy once nothing names it any more. The ledger's database is left where it is.
/// Free of the app's own types, so macos/Tools/test-ledger-cleanup.sh runs it against a fake command.
/// (Windows: entities/agent/lib/ledger-cleanup.ts)
enum LedgerCleanup {
    enum Client: String, CaseIterable { case claude, codex }

    /// What the ledger command's `integrate <client> --status` says a client still has
    struct Registration: Equatable {
        var hooks: Int
        var mcp: Bool
        var isEmpty: Bool { hooks == 0 && !mcp }
    }

    /// Runs a program and answers its exit status and standard output, or nil when it did not start or finish
    typealias Runner = (_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)?

    /// The MCP server name both clients registered
    static let server = "gitrochi-ledger"

    static func stableCommand(support: URL) -> URL {
        support.appendingPathComponent("Gitrochi/bin/gitrochi-ledger")
    }

    static func statusArguments(_ client: Client) -> [String] { ["--json", "integrate", client.rawValue, "--status"] }
    /// Removes only the handlers the ledger command installed; it keeps a backup of the settings next to them
    static func hookArguments(_ client: Client) -> [String] { ["integrate", client.rawValue, "--remove"] }
    static let browserArguments = ["browser-host", "remove"]
    /// The client's own command, as the Ledger's Remove ran it: its settings are its own to rewrite
    static func mcpArguments(_ client: Client) -> [String] {
        ["mcp", "remove"] + (client == .claude ? ["--scope", "user"] : []) + [server]
    }

    /// Nil when the answer is not the status: the settings could not be read, so nothing is known
    static func registration(_ output: String) -> Registration? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let hooks = object["ownedHookCount"] as? Int else { return nil }
        let mcp = (object["mcp"] as? [String: Any])?["registered"] as? Bool ?? false
        return Registration(hooks: hooks, mcp: mcp)
    }

    /// The copy goes only when every client is known to have nothing left: a hook whose command is missing fails on
    /// every event, so a copy something still names stays, and the next launch tries again.
    static func canDelete(_ left: [Registration?]) -> Bool {
        left.allSatisfy { $0?.isEmpty == true }
    }

    /// True when the copy was deleted. `program` is where a client's own command is, when it is installed.
    @discardableResult
    static func run(stable: URL, program: (Client) -> String?, runner: Runner) async -> Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: stable.path) else { return false }
        func status(_ client: Client) async -> Registration? {
            guard let result = await runner(stable.path, statusArguments(client)), result.status == 0 else { return nil }
            return registration(result.output)
        }
        var left: [Registration?] = []
        for client in Client.allCases {
            var found = await status(client)
            if let before = found, !before.isEmpty {
                if before.hooks > 0 { _ = await runner(stable.path, hookArguments(client)) }
                if before.mcp, let program = program(client) { _ = await runner(program, mcpArguments(client)) }
                found = await status(client)
            }
            left.append(found)
        }
        // the Chrome host registration names a command inside the app, not this copy, so its result decides nothing
        _ = await runner(stable.path, browserArguments)
        guard canDelete(left) else { return false }
        try? manager.removeItem(at: stable)
        // the folder held only this command; one with anything else in it stays
        if let rest = try? manager.contentsOfDirectory(atPath: stable.deletingLastPathComponent().path), rest.isEmpty {
            try? manager.removeItem(at: stable.deletingLastPathComponent())
        }
        return true
    }
}
