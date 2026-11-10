#!/usr/bin/env bash
# The copied setup status command must never uninstall tracking, and the Connections rows map each connection health
# to the same states and actions as Windows (windows/tests/ledger-connections.test.ts).
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

let binary = "/Applications/Team's $Tools/Gitrochi.app/Contents/MacOS/gitrochi-ledger"
for client in LedgerSetupClient.allCases {
    let status = client.status(binary: binary)
    let remove = client.remove(binary: binary)
    expect(status.hasSuffix(" integrate \(client.rawValue) --status"), "Status must inspect the chosen client")
    expect(!status.contains("--remove") && !status.contains("\n"), "Copying Status must never remove tracking")
    expect(remove.hasSuffix(" integrate \(client.rawValue) --remove"), "Remove must remove only the chosen client's owned hooks")
    expect(!remove.contains("--status") && !remove.contains("\n"), "Remove must have its own copy block")
    expect(status.contains("Team'\\''s $Tools"), "Paths must remain literal shell arguments")
}
print("PASS: separate status and removal commands for both Ledger clients")

func status(_ fields: String) -> LedgerIntegrationStatus {
    let base = #"""
        {"client":"claude","installed":true,"ownedHookCount":8,"requiresClientTrust":false,"hooksDisabled":false,
        "hookCommand":{"path":"/data/bin/gitrochi-ledger","exists":true,"executable":true,"writesSchema":8,"canWrite":true,"sameDatabase":true},
        "mcp":{"configPath":"/c","registered":false,"command":null},"databaseSchema":8,"lastObservedAt":1000,"lastReportAt":2000,"health":"ok"}
        """#
    var value = try! JSONSerialization.jsonObject(with: Data(base.utf8)) as! [String: Any]
    for (key, item) in try! JSONSerialization.jsonObject(with: Data(fields.utf8)) as! [String: Any] { value[key] = item }
    return try! JSONDecoder().decode(LedgerIntegrationStatus.self, from: JSONSerialization.data(withJSONObject: value))
}
let connected = LedgerConnectionLook.agent(status("{}"), stableExists: true)
expect(connected.state == .connected && connected.lastDataAt == 2000 && connected.actions == [.setUp, .remove, .copy], "Hooks without the MCP entry still offer Set up")
let registered = #""mcp":{"configPath":"/c","registered":true,"command":{"path":"/data/bin/gitrochi-ledger","exists":true,"executable":true,"writesSchema":8,"canWrite":true,"sameDatabase":true}}"#
expect(connected.explanation.contains("cannot report yet") && connected.explanation.contains("Set up"), "Hooks without the MCP entry bring activity, not reports, and say what to do")
let complete = LedgerConnectionLook.agent(status("{\(registered)}"), stableExists: true)
expect(complete.explanation == "Activity and reports reach this Ledger." && complete.actions == [.remove, .copy], "Only hooks with the MCP entry claim reports, and nothing is left to set up")
let toolsOnly = LedgerConnectionLook.agent(status(#"{"ownedHookCount":0,"hookCommand":null,"lastObservedAt":null,\#(registered)}"#), stableExists: true)
expect(toolsOnly.state == .connected && toolsOnly.actions == [.setUp, .remove, .copy], "Remove also takes away a registration without hooks")
let waiting = LedgerConnectionLook.agent(status(#"{"health":"no_data_yet"}"#), stableExists: true)
expect(waiting.state == .noData && waiting.explanation == "Set up registers the Ledger tools. Then start or restart %@." && waiting.actions == [.setUp, .remove, .copy],
       "A connection without the MCP entry names that step before the restart")
expect(LedgerConnectionLook.agent(status(#"{"health":"no_data_yet",\#(registered)}"#), stableExists: true).explanation == "Start or restart %@ to send activity.", "With the MCP entry only the restart is left")
let missing = LedgerConnectionLook.agent(status(#"{"health":"not_installed","ownedHookCount":0,"hookCommand":null}"#), stableExists: false)
expect(missing.state == .notSetUp && missing.actions == [.setUp], "No hooks and no MCP entry is Not set up")
let stale = LedgerConnectionLook.agent(status(#"{"health":"outdated_command","hookCommand":{"path":"/old","exists":true,"executable":true,"canWrite":false}}"#), stableExists: true)
expect(stale.state == .repair && !stale.repairsMcp && stale.actions == [.repair, .remove, .copy], "An outdated hook command needs repair")
let mcp = LedgerConnectionLook.agent(status(#"{"health":"missing_command","ownedHookCount":0,"hookCommand":null,"mcp":{"configPath":"/c","registered":true,"command":{"path":"/moved","exists":false,"executable":false}}}"#), stableExists: false)
expect(mcp.state == .missing && mcp.repairsMcp && mcp.actions == [.repair, .remove], "A moved MCP command is repaired without adding hooks")
expect(mcp.explanation == "The MCP command no longer exists.", "Repair fixes it, so the row asks for nothing by hand")
let codex = LedgerConnectionLook.agent(status(#"{"client":"codex","requiresClientTrust":true,"health":"no_data_yet"}"#), stableExists: false)
expect(codex.state == .noData && codex.explanation.contains("/hooks"), "Codex says its hooks need trust")
expect(LedgerConnectionLook.browser(installed: false, hostExists: false, lastDataAt: nil).state == .missing, "A moved browser host needs repair")
expect(LedgerConnectionLook.browser(installed: true, hostExists: true, lastDataAt: 5).lastDataAt == 5, "Browser data time is shown")
expect(LedgerSetupClient.codex.mcpCommand(stable: "/a b", registered: true) == "codex mcp remove gitrochi-ledger; codex mcp add gitrochi-ledger -- '/a b' mcp",
       "An existing registration is replaced")
expect(LedgerSetupClient.claude.mcpCommand(stable: "/a", registered: false) == "claude mcp add --scope user gitrochi-ledger -- '/a' mcp", "A new registration is added")
print("PASS: Connections states, actions and MCP commands")
SWIFT
swiftc -module-cache-path "$TASK_TMP/cache" "$TASK_ROOT/macos/Sources/Services/LedgerConnectionSetup.swift" \
    "$TASK_ROOT/macos/Sources/Services/LedgerConnections.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
