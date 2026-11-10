import Foundation

/// The demo's local connections, one in each state the Connections list draws: Claude Code delivering activity without an
/// MCP entry until it is set up, Codex running an outdated command until it is repaired, the browser extension not set up.
/// Nothing outside the demo is read or written.
/// (Windows: entities/ledger/api/demo-connections.ts)
final class LedgerDemoConnections {
    private struct Hooks {
        var installed: Bool
        var command: String
        var schema: Int
        var observedAt: LedgerMs?
    }

    private static let stablePath = "demo/bin/gitrochi-ledger"
    private var stable = true
    private var hooks: [String: Hooks]
    private var registered: Set<String> = []

    init(now: LedgerMs) {
        hooks = [
            "claude": Hooks(installed: true, command: Self.stablePath, schema: 8, observedAt: now - 5 * 60_000),
            "codex": Hooks(installed: true, command: "demo/old/gitrochi-ledger", schema: 1, observedAt: nil),
        ]
    }

    func call(_ method: String, _ args: LedgerJSON) -> LedgerJSON {
        switch method {
        case "browser_status":
            return .object(["installed": .bool(false), "hostName": .string("com.gitrochi.ledger"), "manifestPath": .string("demo/browser-host.json")])
        case "integration_command":
            let create = args["create"].bool == true
            let created = create && !stable
            if create { stable = true }
            return .object(["path": .string(Self.stablePath), "exists": .bool(stable), "current": .bool(stable),
                            "refreshed": .bool(created), "held": .bool(false)])
        default:
            let client = args["client"].string == "codex" ? "codex" : "claude"
            var current = hooks[client]!
            if method == "integration_install" {
                stable = true
                current = Hooks(installed: true, command: Self.stablePath, schema: 8, observedAt: current.observedAt)
            } else if method == "integration_remove" {
                current.installed = false
            } else if method == "integration_mcp" {
                if args["action"].string == "remove" {
                    registered.remove(client)
                } else {
                    stable = true
                    registered.insert(client)
                }
            }
            hooks[client] = current
            return status(client, current)
        }
    }

    private func status(_ client: String, _ hooks: Hooks) -> LedgerJSON {
        let canWrite = hooks.schema >= 8
        let command: LedgerJSON = hooks.installed
            ? .object(["path": .string(hooks.command), "exists": .bool(true), "executable": .bool(true), "writesSchema": .number(Double(hooks.schema)),
                       "canWrite": .bool(canWrite), "sameDatabase": .bool(true)])
            : .null
        let mcp = registered.contains(client)
        let health = !hooks.installed ? (mcp ? "ok" : "not_installed") : !canWrite ? "outdated_command" : hooks.observedAt == nil ? "no_data_yet" : "ok"
        let expected = client == "claude" ? 8 : 7
        return .object([
            "client": .string(client), "installed": .bool(hooks.installed), "ownedHookCount": .number(Double(hooks.installed ? expected : 0)),
            "requiresClientTrust": .bool(client == "codex"), "hooksDisabled": .bool(false), "hookCommand": command,
            "mcp": .object(["configPath": .string(client == "claude" ? "demo/.claude.json" : "demo/.codex/config.toml"),
                            "registered": .bool(mcp), "command": .null]),
            "databaseSchema": .number(8),
            "lastObservedAt": hooks.installed ? hooks.observedAt.map { .number(Double($0)) } ?? .null : .null,
            "lastReportAt": .null, "health": .string(health),
        ])
    }
}
