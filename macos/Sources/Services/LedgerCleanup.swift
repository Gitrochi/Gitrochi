import Foundation

/// Gitrochi no longer has a Ledger. A person who connected Claude Code or Codex to it still has its hooks and MCP server
/// in those clients' settings, and they run the copy of the ledger command under Application Support/Gitrochi/bin. While
/// that copy exists, this has it take out its own hooks and browser host, has each client drop the MCP server, and
/// deletes the copy once nothing names it any more. The ledger's database is left where it is.
/// Older installs ran the command inside the app itself, so no copy exists and nothing above runs: `removeOrphans` then
/// takes the owned hooks out of the clients' settings files and has each client drop the MCP server, every launch, until
/// nothing names the Ledger any more.
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

    // MARK: Hooks and servers left without the command

    /// The settings file each client keeps its hooks in, under the home folder
    static func hookFile(_ client: Client, home: URL) -> URL {
        client == .claude ? home.appendingPathComponent(".claude/settings.json") : home.appendingPathComponent(".codex/hooks.json")
    }

    /// A handler the Ledger installed: its command runs the ledger command and carries the flag it marked its own with
    static func isOwnedHook(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        return command.contains(server) && command.contains("--managed-hook")
    }

    /// The settings without the Ledger's handlers; a group or event left empty goes too, and so does an empty `hooks`.
    /// Everything else stays as it was.
    static func withoutOwnedHooks(_ settings: [String: Any]) -> (settings: [String: Any], removed: Int) {
        guard let hooks = settings["hooks"] as? [String: Any] else { return (settings, 0) }
        var removed = 0
        var kept: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { kept[event] = value; continue }
            var left: [[String: Any]] = []
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { left.append(group); continue }
                let rest = handlers.filter { !isOwnedHook($0) }
                removed += handlers.count - rest.count
                if rest.count == handlers.count { left.append(group) } else if !rest.isEmpty {
                    var copy = group
                    copy["hooks"] = rest
                    left.append(copy)
                }
            }
            if !left.isEmpty { kept[event] = left }
        }
        guard removed > 0 else { return (settings, 0) }
        var result = settings
        if kept.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = kept }
        return (result, removed)
    }

    /// Whether a client's user settings still register the MCP server: Claude Code's `~/.claude.json` `mcpServers`,
    /// Codex's `[mcp_servers.gitrochi-ledger]` table in `~/.codex/config.toml`
    static func mcpRegistered(_ client: Client, text: String) -> Bool {
        switch client {
        case .claude:
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            return (object?["mcpServers"] as? [String: Any])?[server] != nil
        case .codex:
            return text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "[mcp_servers.\(server)]" || trimmed == "[mcp_servers.\"\(server)\"]"
            }
        }
    }

    static func mcpFile(_ client: Client, home: URL) -> URL {
        client == .claude ? home.appendingPathComponent(".claude.json") : home.appendingPathComponent(".codex/config.toml")
    }

    /// Takes the Ledger's handlers out of one settings file, keeping the bytes it had next to it, and writes only when
    /// the file has not changed meanwhile. Answers how many handlers went.
    @discardableResult
    static func removeOwnedHooks(at file: URL) -> Int {
        guard let before = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: before)) as? [String: Any] else { return 0 }
        let (cleaned, removed) = withoutOwnedHooks(settings)
        guard removed > 0,
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? Data(contentsOf: file)) == before else { return 0 }
        let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".before-ledger-removal")
        if !FileManager.default.fileExists(atPath: backup.path) { try? before.write(to: backup, options: .atomic) }
        guard (try? (data + Data("\n".utf8)).write(to: file, options: .atomic)) != nil else { return 0 }
        return removed
    }

    /// Hooks and MCP servers that still name the Ledger once its command is gone. Cheap when there are none: it reads
    /// four small files.
    static func removeOrphans(home: URL, program: (Client) -> String?, runner: Runner) async {
        for client in Client.allCases {
            removeOwnedHooks(at: hookFile(client, home: home))
            guard let text = try? String(contentsOf: mcpFile(client, home: home), encoding: .utf8),
                  mcpRegistered(client, text: text), let program = program(client) else { continue }
            _ = await runner(program, mcpArguments(client))
        }
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
