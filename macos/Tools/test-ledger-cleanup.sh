#!/usr/bin/env bash
# The one-time cleanup after the Ledger's removal (Services/LedgerCleanup.swift), run against a fake ledger command and
# fake clients in a temporary folder: what it asks of them, and when the command's copy may be deleted. Nothing outside
# the temporary folder is read or changed.
#   macos/Tools/test-ledger-cleanup.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
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

/// One fake home: the ledger command's copy, what each client still has, and every command that ran
struct Fixture {
    let root: URL
    var state: URL { root.appendingPathComponent("state") }
    var stable: URL { LedgerCleanup.stableCommand(support: root.appendingPathComponent("Application Support")) }
    var database: URL { root.appendingPathComponent("Application Support/Gitrochi/ledger/ledger.sqlite3") }

    init(_ parent: URL, name: String, copy: Bool = true) {
        root = parent.appendingPathComponent(name)
        let manager = FileManager.default
        try! manager.createDirectory(at: state, withIntermediateDirectories: true)
        try! manager.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("ledger".utf8).write(to: database)
        for client in LedgerCleanup.Client.allCases { set(client, hooks: 0, mcp: false) }
        if copy {
            script(stable, #"""
            echo "ledger $*" >> "$FAKE_STATE/calls"
            case "$*" in
            "--json integrate "*" --status")
                [ -f "$FAKE_STATE/unreadable" ] && exit 1
                printf '{"client":"%s","ownedHookCount":%s,"mcp":{"registered":%s,"command":null}}\n' "$3" "$(cat "$FAKE_STATE/$3.hooks")" "$(cat "$FAKE_STATE/$3.mcp")" ;;
            "integrate "*" --remove") echo 0 > "$FAKE_STATE/$2.hooks" ;;
            "browser-host remove") echo '{"installed":false}' ;;
            *) exit 2 ;;
            esac
            """#)
        }
    }

    func script(_ file: URL, _ body: String) {
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func set(_ client: LedgerCleanup.Client, hooks: Int, mcp: Bool) {
        try! "\(hooks)".write(to: state.appendingPathComponent(client.rawValue + ".hooks"), atomically: true, encoding: .utf8)
        try! "\(mcp)".write(to: state.appendingPathComponent(client.rawValue + ".mcp"), atomically: true, encoding: .utf8)
    }

    /// A client's own command: `mcp remove … gitrochi-ledger` drops the server
    func client(_ client: LedgerCleanup.Client) -> String {
        let file = root.appendingPathComponent("clients/" + client.rawValue)
        script(file, #"""
        echo "\#(client.rawValue) $*" >> "$FAKE_STATE/calls"
        [ "$1 $2" = "mcp remove" ] && echo false > "$FAKE_STATE/\#(client.rawValue).mcp"
        exit 0
        """#)
        return file.path
    }

    var calls: [String] {
        ((try? String(contentsOf: state.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func run(program: @escaping (LedgerCleanup.Client) -> String? = { _ in nil }) async -> Bool {
        let state = state.path, home = root
        return await LedgerCleanup.run(stable: stable, program: program) { executable, arguments in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = home
            process.environment = ["FAKE_STATE": state, "PATH": "/usr/bin:/bin"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
}

@main struct LedgerCleanupTests {
    static func main() async {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1])
        let manager = FileManager.default
        typealias Registration = LedgerCleanup.Registration

        // the status the ledger command prints, as its last version wrote it
        let status = #"{"action":"status","client":"claude","installed":true,"ownedHookCount":8,"otherHookCount":1,"health":"ok","mcp":{"command":null,"configPath":"/Users/me/.claude.json","registered":true}}"#
        check(LedgerCleanup.registration(status) == Registration(hooks: 8, mcp: true), "hooks and the MCP server from the status")
        check(LedgerCleanup.registration(#"{"ownedHookCount":0,"mcp":{"registered":false}}"#) == Registration(hooks: 0, mcp: false), "nothing left")
        check(LedgerCleanup.registration(#"{"ownedHookCount":2}"#) == Registration(hooks: 2, mcp: false), "a command from before it reported the MCP server")
        for text in ["", "not json", "[]", #"{"error":{"code":"INVALID_ARGUMENT","message":"Settings are not valid JSON; nothing was changed"}}"#] {
            check(LedgerCleanup.registration(text) == nil, "not a status: \(text)")
        }
        check(LedgerCleanup.statusArguments(.codex) == ["--json", "integrate", "codex", "--status"], "status arguments")
        check(LedgerCleanup.hookArguments(.claude) == ["integrate", "claude", "--remove"], "hook arguments")
        check(LedgerCleanup.mcpArguments(.claude) == ["mcp", "remove", "--scope", "user", "gitrochi-ledger"], "Claude Code's user-level server")
        check(LedgerCleanup.mcpArguments(.codex) == ["mcp", "remove", "gitrochi-ledger"], "Codex's server")
        let empty = Registration(hooks: 0, mcp: false)
        check(LedgerCleanup.canDelete([empty, empty]), "nothing names the copy")
        check(!LedgerCleanup.canDelete([empty, Registration(hooks: 1, mcp: false)]), "a hook still runs the copy")
        check(!LedgerCleanup.canDelete([Registration(hooks: 0, mcp: true), empty]), "an MCP server still runs the copy")
        check(!LedgerCleanup.canDelete([empty, nil]), "an unreadable status decides nothing")

        // no copy: a person who never connected an agent, and every launch after the cleanup
        let never = Fixture(parent, name: "never", copy: false)
        check(!(await never.run(program: never.client)) && never.calls.isEmpty, "without the copy nothing runs")

        // nothing registered any more: only the copy is left to delete
        let clean = Fixture(parent, name: "clean")
        check(await clean.run(), "a copy nothing names is deleted")
        check(clean.calls == ["ledger --json integrate claude --status", "ledger --json integrate codex --status", "ledger browser-host remove"],
              "asks only for the status and the browser host: \(clean.calls)")
        check(!manager.fileExists(atPath: clean.stable.path) && !manager.fileExists(atPath: clean.stable.deletingLastPathComponent().path), "the copy and its empty folder are gone")
        check((try? Data(contentsOf: clean.database)) == Data("ledger".utf8), "the database is left as it is")

        // connected: hooks through the copy, the MCP server through the client itself, then the copy
        let connected = Fixture(parent, name: "connected")
        connected.set(.claude, hooks: 8, mcp: true)
        connected.set(.codex, hooks: 7, mcp: false)
        check(await connected.run(program: connected.client), "everything was unregistered")
        check(connected.calls == [
            "ledger --json integrate claude --status", "ledger integrate claude --remove", "claude mcp remove --scope user gitrochi-ledger",
            "ledger --json integrate claude --status",
            "ledger --json integrate codex --status", "ledger integrate codex --remove", "ledger --json integrate codex --status",
            "ledger browser-host remove",
        ], "each client in turn: \(connected.calls)")
        check(!manager.fileExists(atPath: connected.stable.path), "the copy is deleted once nothing names it")
        check((try? Data(contentsOf: connected.database)) == Data("ledger".utf8), "the database is left as it is")

        // the client's command cannot be found: its MCP server would lose its command, so the copy stays for the next launch
        let later = Fixture(parent, name: "later")
        later.set(.codex, hooks: 7, mcp: true)
        check(!(await later.run()), "an MCP server nobody could remove keeps the copy")
        check(manager.isExecutableFile(atPath: later.stable.path) && later.calls.contains("ledger integrate codex --remove"), "its hooks are removed all the same")
        check(await later.run(program: later.client) && !manager.fileExists(atPath: later.stable.path), "the next launch finishes it")
        check(later.calls.filter { $0 == "ledger integrate codex --remove" }.count == 1, "hooks already gone are not removed again")

        // settings the command cannot read: nothing is known, so nothing is deleted
        let unreadable = Fixture(parent, name: "unreadable")
        try! Data().write(to: unreadable.state.appendingPathComponent("unreadable"))
        check(!(await unreadable.run(program: unreadable.client)) && manager.isExecutableFile(atPath: unreadable.stable.path), "an unreadable status keeps the copy")
        check(!unreadable.calls.contains { $0.contains("--remove") || $0.contains("mcp remove") }, "and removes nothing: \(unreadable.calls)")

        // the folder is deleted only when the copy was all it held
        let shared = Fixture(parent, name: "shared")
        let other = shared.stable.deletingLastPathComponent().appendingPathComponent("other-tool")
        try! Data("x".utf8).write(to: other)
        check(await shared.run() && !manager.fileExists(atPath: shared.stable.path) && manager.fileExists(atPath: other.path), "another file in the folder stays")

        print("PASS: \(checks) checks — status parsing, the commands asked of the copy and the clients, and the copy deleted only once nothing names it")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" -module-cache-path "$TASK_TMP/module-cache" \
    "$ROOT/Sources/Services/LedgerCleanup.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/ledger-cleanup-tests"
mkdir -p "$TASK_TMP/homes"
"$TASK_TMP/ledger-cleanup-tests" "$TASK_TMP/homes"
