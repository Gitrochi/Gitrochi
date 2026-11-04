#!/usr/bin/env bash
# What starting an agent hands it (Services/AgentLaunch.swift), checked without starting one. With Track agents I start
# off, the arguments for every agent, mode and task, the environment and hooks.json must be byte for byte the ones main
# made before the Ledger: fixtures/agent-launch holds them, captured from main 827f6098's AgentKind.arguments and
# AgentCenter.installHooks. With it on, the existing hook entries stay first and unchanged, and the ledger's entries match
# gitrochi-autocontinue's hook_settings for the longest wait, 310 s (DESIGN.md §5, §9.1). Also the switch, the MCP check
# and the heartbeat file.
#   macos/Tools/test-agent-launch.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
ARCH="$(uname -m)"
ST="${GITROCHI_SWIFTTERM_DIR:-$ROOT/.build/swiftterm/$ARCH}"
if [[ ! -f "$ST/libSwiftTerm.a" ]]; then
    echo 'Run macos/build.sh once to build SwiftTerm.' >&2
    exit 1
fi
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

var checks = 0
func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !condition {
        FileHandle.standardError.write(Data("FAIL (line \(line)): \(message())\n".utf8))
        exit(1)
    }
}

func object(_ data: Data?) -> [String: Any] { (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
func same(_ a: Any?, _ b: Any?) -> Bool { NSDictionary(dictionary: ["v": a ?? NSNull()]).isEqual(to: ["v": b ?? NSNull()]) }

@main struct AgentLaunchTests {
    static let script = "/Gitrochi/agents/hook.sh"
    static let command = "/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger"

    static func main() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let rust = URL(fileURLWithPath: CommandLine.arguments[2])
        let tools = URL(fileURLWithPath: CommandLine.arguments[3])
        try untracked(fixtures)
        try tracked(fixtures, rust: rust)
        await serverCheck(tools)
        heartbeat(tools)
        print("PASS: \(checks) checks — the untracked launch is main's byte for byte (38 argument cases, environment, hooks.json); "
              + "tracked hooks keep the existing entries and match hook_settings; the switch, the MCP check and the heartbeat")
    }

    static func untracked(_ fixtures: URL) throws {
        let hooks = try Data(contentsOf: fixtures.appendingPathComponent("hooks.json"))
        check(AgentLaunch.hooks(script: script) == hooks, "hooks.json is byte for byte main's")
        let launch = object(try Data(contentsOf: fixtures.appendingPathComponent("launch.json")))
        let hooksPath = launch["hooks"] as! String
        let cases = launch["cases"] as! [[String: Any]]
        check(cases.count == 38, "every agent, mode and task: \(cases.count)")
        for c in cases {
            let kind = AgentKind(rawValue: c["kind"] as! String)!
            let mode = c["mode"] as? String, task = c["task"] as! String
            let expected = c["args"] as! [String]
            check(AgentLaunch.arguments(kind, hooks: hooksPath, task: task, mode: mode) == expected, "arguments for \(c)")
            check(kind.arguments(hooks: hooksPath, task: task, mode: mode) == expected, "AgentKind.arguments for \(c)")
        }
        check(AgentLaunch.environment(agent: "agent-1") == launch["environment"] as! [String: String], "environment")

        // Track agents I start is off until a person turns it on, and then the switch alone decides: no environment needed
        let suite = "gitrochi-agent-launch-test-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(!LedgerTracking.isOn(defaults: defaults), "off by default")
        defaults.set(true, forKey: LedgerTracking.trackKey)
        check(LedgerTracking.isOn(defaults: defaults), "on with the switch alone")
        defaults.set(false, forKey: LedgerTracking.trackKey)
        check(!LedgerTracking.isOn(defaults: defaults), "off again")
    }

    static func tracked(_ fixtures: URL, rust: URL) throws {
        let plain = object(try Data(contentsOf: fixtures.appendingPathComponent("hooks.json")))["hooks"] as! [String: [[String: Any]]]
        let ledger = AgentLaunch.Ledger(session: "S1031-07", command: command, database: nil)
        let with = object(AgentLaunch.hooks(script: script, ledger: ledger))["hooks"] as! [String: [[String: Any]]]
        for (event, groups) in plain {
            check(same(Array(with[event]!.prefix(groups.count)), groups), "\(event): the existing entries stay first, unchanged")
        }
        check(Set(with.keys) == Set(plain.keys).union(["PostToolUse", "PostToolUseFailure"]), "events: \(with.keys.sorted())")
        func added(_ event: String) -> [[String: Any]] { Array(with[event]!.dropFirst(plain[event]?.count ?? 0)) }
        func hook(_ event: String) -> [String: Any] { (added(event).first?["hooks"] as? [[String: Any]])?.first ?? [:] }
        // the events gitrochi-autocontinue's hook_settings covers, exactly as it writes them for the same command and the
        // longest wait: a person may lengthen a session's wait while its agent runs
        let expected = object(try Data(contentsOf: rust)) as! [String: [[String: Any]]]
        for (event, groups) in expected {
            check(same(added(event), groups), "\(event) is hook_settings' entry: \(added(event)) vs \(groups)")
        }
        for event in ["SessionStart", "SessionEnd"] {
            check(added(event).count == 1 && same(hook(event), ["type": "command", "command": "\"\(command)\" hook \(event)", "timeout": 10]),
                  "\(event): activity, timeout 10")
        }
        check(hook("Stop")["async"] as? Bool == true && hook("Stop")["asyncRewake"] as? Bool == true && hook("Stop")["timeout"] as? Int == 310,
              "Stop waits in the background and wakes the session; the longest wait plus 10 s")
        check(added("PreToolUse").first?["matcher"] as? String == "AskUserQuestion|ExitPlanMode" && hook("PermissionRequest")["timeout"] as? Int == 310
              && hook("PreToolUse")["timeout"] as? Int == 310, "the question tools only; every waiting hook may run as long")
        check(AgentLaunch.waitingTimeout == 310, "5 minutes, the longest wait, plus a 10 s margin")

        check(AgentLaunch.environment(agent: "agent-1", ledger: ledger) == ["GITROCHI_AGENT_ID": "agent-1", "GITROCHI_LEDGER_SESSION": "S1031-07"],
              "GITROCHI_LEDGER_SESSION next to GITROCHI_AGENT_ID")
        let elsewhere = AgentLaunch.Ledger(session: "S1031-07", command: command, database: "/tmp/test.sqlite3")
        check(AgentLaunch.environment(agent: "a", ledger: elsewhere)["GITROCHI_LEDGER_DB"] == "/tmp/test.sqlite3", "the app's own database override")
        let base = AgentKind.claude.arguments(hooks: "/h.json", task: "Fix it", mode: "default")
        check(AgentLaunch.arguments(.claude, hooks: "/h.json", task: "Fix it", mode: "default", mcpConfig: "/m.json") == ["--mcp-config", "/m.json"] + base,
              "the MCP config goes first, before an option, never right before the task")
        check(AgentLaunch.arguments(.codex, hooks: "/h.json", task: "t", mode: nil, mcpConfig: "/m.json") == AgentKind.codex.arguments(hooks: "/h.json", task: "t", mode: nil),
              "only Claude Code takes it")
        let mcp = object(AgentLaunch.mcpConfig(elsewhere))["mcpServers"] as? [String: Any]
        check(same(mcp?["gitrochi-ledger"], ["type": "stdio", "command": command, "args": ["mcp"],
                                             "env": ["GITROCHI_LEDGER_SESSION": "S1031-07", "GITROCHI_LEDGER_DB": "/tmp/test.sqlite3"]]),
              "the bundled MCP server, told its session: \(String(describing: mcp))")
    }

    /// `claude mcp get gitrochi-ledger`, played by small scripts: found, not found, and one that hangs
    static func serverCheck(_ folder: URL) async {
        func fake(_ name: String, _ body: String) -> String {
            let file = folder.appendingPathComponent(name)
            try! ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        let found = fake("found", #"[ "$1 $2 $3" = "mcp get gitrochi-ledger" ] && exit 0; exit 3"#)
        let missing = fake("missing", "echo 'No MCP server found with name: gitrochi-ledger' >&2; exit 1")
        let hangs = fake("hangs", "sleep 30")
        check(await LedgerTracking.hasLedgerServer(claude: found, folder: folder.path), "a server of that name is found")
        check(!(await LedgerTracking.hasLedgerServer(claude: missing, folder: folder.path)), "none: the launch adds its own")
        let started = Date()
        check(await LedgerTracking.hasLedgerServer(claude: hangs, folder: folder.path, timeout: 1) && Date().timeIntervalSince(started) < 10,
              "a check that does not finish counts as found, so nothing is shadowed")
        check(!(await LedgerTracking.hasLedgerServer(claude: folder.appendingPathComponent("absent").path, folder: folder.path)), "no claude to ask")
    }

    /// The heartbeat follows Track agents I start alone, never on GITROCHI_LEDGER=0 or the demo; app.alive gets a new
    /// modification time each beat, and nothing is created where the ledger has no folder
    static func heartbeat(_ folder: URL) {
        check(!LedgerHeartbeat.runs(tracking: false, environment: [:]), "no heartbeat with tracking off")
        check(LedgerHeartbeat.runs(tracking: true, environment: [:]), "the switch alone starts it, without a preview environment")
        check(LedgerHeartbeat.runs(tracking: true, environment: ["GITROCHI_LEDGER_PREVIEW": "0"]), "a leftover preview variable changes nothing")
        check(!LedgerHeartbeat.runs(tracking: true, environment: ["GITROCHI_LEDGER": "0"]), "GITROCHI_LEDGER=0 still turns the ledger off")
        check(!LedgerHeartbeat.runs(tracking: true, environment: ["GITROCHI_LEDGER_DEMO": "standard"]), "not on the demo")
        check(!LedgerHeartbeat.runs(tracking: false, environment: ["GITROCHI_LEDGER_PREVIEW": "1"]), "nor with the old preview variable alone")
        let file = folder.appendingPathComponent("ledger/app.alive")
        LedgerHeartbeat.beat(file)
        check(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), "no ledger folder: nothing is created")
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let past = Date(timeIntervalSinceNow: -600)
        LedgerHeartbeat.beat(file, now: past)
        LedgerHeartbeat.beat(file)
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? past
        check(abs(modified.timeIntervalSinceNow) < 5, "an existing file gets a new time: \(modified)")
        check(LedgerHeartbeat.file(environment: ["GITROCHI_LEDGER_DB": "/x/y/ledger.sqlite3"]).path == "/x/y/app.alive", "next to the database")
        check(LedgerHeartbeat.file(environment: [:]).path.hasSuffix("Application Support/Gitrochi/ledger/app.alive"), "the default place")
    }
}
SWIFT
SOURCES=()
while IFS= read -r -d '' file; do
    case "$file" in */App/App.swift) continue ;; esac
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' -print0)
cp "$(bash "$ROOT/../tools/build-core-native.sh" "$ARCH")" "$TASK_TMP/core.a"
# what gitrochi-autocontinue's hook_settings writes for the same command and the longest wait
cargo run -q --locked --manifest-path "$ROOT/../crates/Cargo.toml" -p gitrochi-autocontinue --bin gitrochi-autocontinue -- \
    settings '"/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger" hook' --delay 300 > "$TASK_TMP/hook-settings.json"
swiftc -whole-module-optimization -Onone -parse-as-library -swift-version 5 -target "$ARCH-apple-macos15.0" -I "$ST" \
    -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/main.swift" "$TASK_TMP/core.a" -o "$TASK_TMP/agent-launch-tests"
mkdir -p "$TASK_TMP/plain" "$TASK_TMP/leftover"
"$TASK_TMP/agent-launch-tests" "$ROOT/Tools/fixtures/agent-launch" "$TASK_TMP/hook-settings.json" "$TASK_TMP/plain"
# again with the old preview variable left in the environment: it no longer changes anything
GITROCHI_LEDGER_PREVIEW=1 "$TASK_TMP/agent-launch-tests" "$ROOT/Tools/fixtures/agent-launch" "$TASK_TMP/hook-settings.json" "$TASK_TMP/leftover" > /dev/null
