#!/usr/bin/env bash
# What starting an agent hands it (Services/AgentLaunch.swift), checked without starting one: the arguments for every
# agent, mode and task, the environment and hooks.json must be byte for byte the ones in fixtures/agent-launch, captured
# from main 827f6098's AgentKind.arguments and AgentCenter.installHooks.
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

@main struct AgentLaunchTests {
    static let script = "/Gitrochi/agents/hook.sh"

    static func main() throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
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
        print("PASS: \(checks) checks — the launch is the fixtures' byte for byte (38 argument cases, environment, hooks.json)")
    }
}
SWIFT
SOURCES=()
while IFS= read -r -d '' file; do
    case "$file" in */App/App.swift) continue ;; esac
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' -print0)
cp "$(bash "$ROOT/../tools/build-core-native.sh" "$ARCH")" "$TASK_TMP/core.a"
swiftc -whole-module-optimization -Onone -parse-as-library -swift-version 5 -target "$ARCH-apple-macos15.0" -I "$ST" \
    -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/main.swift" "$TASK_TMP/core.a" -o "$TASK_TMP/agent-launch-tests"
"$TASK_TMP/agent-launch-tests" "$ROOT/Tools/fixtures/agent-launch"
