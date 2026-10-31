import Foundation

/// What starting an agent hands it: its arguments, its environment and the hooks file Claude Code reads with
/// `--settings`. Free of side effects, so macos/Tools/test-agent-launch.sh can show that with Track agents I start
/// off every launch is byte for byte the one Gitrochi made before the Ledger. (Windows: entities/agent/model/agents.ts)
enum AgentLaunch {
    /// What a tracked Claude Code launch adds (DESIGN.md §5, §9.1); only while Track agents I start is on
    struct Ledger: Equatable {
        /// GITROCHI_LEDGER_SESSION: the session `track` created for this agent
        var session: String
        /// The bundled gitrochi-ledger
        var command: String
        /// The session's auto-continue wait in seconds; the hooks that wait time out 10 s after it
        var wait: Int
        /// GITROCHI_LEDGER_DB when the app itself uses another database, so the hooks write where the app reads
        var database: String?
    }

    /// The events hook.sh records for the agent center
    static let statusEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]

    /// hooks.json: hook.sh on every status event with `timeout: 5`, as it has always been. With `ledger`, the ledger's
    /// entries follow in matcher groups of their own, so the existing groups keep their exact content.
    static func hooks(script: String, ledger: Ledger? = nil) -> Data? {
        var hooks: [String: [[String: Any]]] = [:]
        for e in statusEvents {
            hooks[e] = [["matcher": "", "hooks": [["type": "command", "command": "\"\(script)\" \(e)", "timeout": 5]]]]
        }
        if let ledger {
            for (event, group) in ledgerEntries(ledger) { hooks[event, default: []].append(group) }
        }
        return try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
    }

    /// `gitrochi-ledger hook <event>` for activity (SessionStart, UserPromptSubmit, Stop, SessionEnd) and for
    /// auto-continue: Stop in the background so the terminal stays usable, PreToolUse for the question tools only, and
    /// PermissionRequest, which time out at the wait plus 10 s; PostToolUse and PostToolUseFailure tell the handler which
    /// permission answer applied. Matches gitrochi-autocontinue's hook_settings, plus SessionStart and SessionEnd.
    static func ledgerEntries(_ ledger: Ledger) -> [(event: String, group: [String: Any])] {
        let waiting = min(max(ledger.wait, 10), 300) + 10
        func entry(_ event: String, matcher: String = "", timeout: Int, background: Bool = false) -> (event: String, group: [String: Any]) {
            var hook: [String: Any] = ["type": "command", "command": "\"\(ledger.command)\" hook \(event)", "timeout": timeout]
            if background {
                hook["async"] = true
                hook["asyncRewake"] = true
            }
            return (event, ["matcher": matcher, "hooks": [hook]])
        }
        return [
            entry("SessionStart", timeout: 10),
            entry("UserPromptSubmit", timeout: 10),
            entry("Stop", timeout: waiting, background: true),
            entry("PreToolUse", matcher: "AskUserQuestion|ExitPlanMode", timeout: waiting),
            entry("PermissionRequest", timeout: waiting),
            entry("PostToolUse", timeout: 10),
            entry("PostToolUseFailure", timeout: 10),
            entry("SessionEnd", timeout: 10),
        ]
    }

    static func environment(agent: String, ledger: Ledger? = nil) -> [String: String] {
        var env = ["GITROCHI_AGENT_ID": agent]
        if let ledger {
            env["GITROCHI_LEDGER_SESSION"] = ledger.session
            if let database = ledger.database { env["GITROCHI_LEDGER_DB"] = database }
        }
        return env
    }

    /// The agent's arguments. A tracked Claude Code launch may also read the ledger's MCP server from `mcpConfig`; the flag
    /// takes several files, so it goes first, where the next word is an option and never the task.
    static func arguments(_ kind: AgentKind, hooks: String, task: String, mode: String?, mcpConfig: String? = nil) -> [String] {
        let args = kind.arguments(hooks: hooks, task: task, mode: mode)
        guard let mcpConfig, kind == .claude else { return args }
        return ["--mcp-config", mcpConfig] + args
    }

    /// The `--mcp-config` file: the bundled `gitrochi-ledger mcp`, told its session in its own environment
    static func mcpConfig(_ ledger: Ledger) -> Data? {
        var env = ["GITROCHI_LEDGER_SESSION": ledger.session]
        if let database = ledger.database { env["GITROCHI_LEDGER_DB"] = database }
        let server: [String: Any] = ["type": "stdio", "command": ledger.command, "args": ["mcp"], "env": env]
        return try? JSONSerialization.data(withJSONObject: ["mcpServers": ["gitrochi-ledger": server]], options: [.prettyPrinted, .sortedKeys])
    }
}
