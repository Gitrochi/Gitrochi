import Foundation

/// One row of the Connections list: Claude Code, Codex and the browser extension in the same five states. Text is
/// English, the translation key. (Windows: features/connect-ledger-mcp/lib/connections.ts)
struct LedgerConnectionLook: Equatable {
    enum State: Hashable { case notSetUp, connected, noData, repair, missing }
    enum Action: Hashable { case setUp, repair, remove, copy }

    let state: State
    /// When data from this connection last arrived (epoch milliseconds), for "Connected · last data …"
    let lastDataAt: Int?
    /// One line; `%@` is the client's name
    let explanation: String
    let actions: [Action]
    /// Repair re-registers the MCP server (by copying its command) rather than only the hooks
    var repairsMcp = false

    private static let repairText: [String: (hook: String, mcp: String)] = [
        "outdated_command": ("The hook command is older than this Ledger and cannot write to it.",
                             "The MCP command is older than this Ledger and cannot write to it. Copy the MCP command and run it."),
        "missing_command": ("The hook command no longer exists.", "The MCP command no longer exists. Copy the MCP command and run it."),
        "other_database": ("The hooks write to a different Ledger database.",
                           "The MCP server uses a different Ledger database. Copy the MCP command and run it."),
    ]

    /// Which command a problem comes from: the hooks unless only the MCP entry has it
    private static func fromHooks(_ status: LedgerIntegrationStatus) -> Bool {
        func bad(_ command: LedgerIntegrationStatus.Command?) -> Bool {
            guard let command else { return false }
            switch status.health {
            case "missing_command": return !command.exists || !command.executable
            case "outdated_command": return command.canWrite == false
            default: return command.sameDatabase == false
            }
        }
        return bad(status.hookCommand) || !bad(status.mcp.command)
    }

    /// A local agent's row: Repair when the connection cannot deliver, Remove while hooks are installed, Set up
    /// otherwise. The MCP command can be copied once the stable command exists, since it names that file.
    static func agent(_ status: LedgerIntegrationStatus, stableExists: Bool) -> LedgerConnectionLook {
        let hooks = status.ownedHookCount > 0
        let last = max(status.lastObservedAt ?? 0, status.lastReportAt ?? 0)
        let state: State
        let explanation: String
        var repairsMcp = false
        switch status.health {
        case "not_installed":
            state = .notSetUp
            explanation = "Not connected. Set up installs activity hooks that run Gitrochi's stable Ledger command."
        case "missing_command", "outdated_command", "other_database":
            state = status.health == "missing_command" ? .missing : .repair
            let text = repairText[status.health] ?? ("", "")
            repairsMcp = !fromHooks(status)
            explanation = repairsMcp ? text.mcp : text.hook
        case "incomplete":
            state = .repair
            explanation = "Some activity hooks are missing."
        case "no_data_yet":
            state = .noData
            explanation = status.hooksDisabled ? "Hooks are turned off in this client's settings."
                : status.requiresClientTrust ? "Start or restart Codex, then review and trust the Ledger hooks in /hooks."
                : "Start or restart %@ to send activity."
        default:
            state = .connected
            explanation = status.hooksDisabled ? "Hooks are turned off in this client's settings."
                : hooks ? "Activity and reports reach this Ledger." : "The MCP server is registered. Set up also records activity."
        }
        let broken = state == .repair || state == .missing
        var actions: [Action] = broken ? [.repair] : hooks ? [] : [.setUp]
        if hooks { actions.append(.remove) }
        if stableExists { actions.append(.copy) }
        return LedgerConnectionLook(state: state, lastDataAt: state == .connected && last > 0 ? last : nil,
                                    explanation: explanation, actions: actions, repairsMcp: repairsMcp)
    }

    /// The browser extension's row: its host registration, and when its last question arrived
    static func browser(installed: Bool, hostExists: Bool?, lastDataAt: Int?) -> LedgerConnectionLook {
        // A registration whose host moved with the app is repaired, not set up again
        if !installed, hostExists == false {
            return LedgerConnectionLook(state: .missing, lastDataAt: nil,
                                        explanation: "The browser host is missing. Repair registers this copy of Gitrochi.", actions: [.repair, .remove])
        }
        if !installed {
            return LedgerConnectionLook(state: .notSetUp, lastDataAt: nil,
                                        explanation: "Not connected. Load the extension in Chrome and allow it to connect.", actions: [.setUp])
        }
        if let lastDataAt {
            return LedgerConnectionLook(state: .connected, lastDataAt: lastDataAt,
                                        explanation: "Questions from paired ChatGPT conversations reach this Ledger.", actions: [.remove])
        }
        return LedgerConnectionLook(state: .noData, lastDataAt: nil,
                                    explanation: "Pair a conversation from the extension's popup to send questions.", actions: [.remove])
    }
}

extension LedgerSetupClient {
    /// The MCP registration to copy, naming the stable command. A registration that already exists is removed first,
    /// since `mcp add` does not replace one. (Windows: connections.ts mcpCommand)
    func mcpCommand(stable: String, registered: Bool) -> String {
        let scope = self == .claude ? "--scope user " : ""
        let add = registration(binary: stable)
        return registered ? "\(rawValue) mcp remove \(scope)gitrochi-ledger; \(add)" : add
    }
}
