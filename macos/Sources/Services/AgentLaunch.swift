import Foundation

/// What starting an agent hands it: its arguments, its environment and the hooks file Claude Code reads with
/// `--settings`. Free of side effects, so macos/Tools/test-agent-launch.sh can check every launch against its fixtures.
/// (Windows: entities/agent/model/agents.ts)
enum AgentLaunch {
    /// The events hook.sh records for the agent center
    static let statusEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]

    /// hooks.json: hook.sh on every status event with `timeout: 5`
    static func hooks(script: String) -> Data? {
        var hooks: [String: [[String: Any]]] = [:]
        for e in statusEvents {
            hooks[e] = [["matcher": "", "hooks": [["type": "command", "command": "\"\(script)\" \(e)", "timeout": 5]]]]
        }
        return try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
    }

    static func environment(agent: String) -> [String: String] {
        ["GITROCHI_AGENT_ID": agent]
    }

    static func arguments(_ kind: AgentKind, hooks: String, task: String, mode: String?) -> [String] {
        kind.arguments(hooks: hooks, task: task, mode: mode)
    }
}
