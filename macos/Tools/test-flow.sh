#!/usr/bin/env bash
# The engine JSON contract the Flows screen reads: runs the real gitch-flow in a temporary repository and HOME,
# and reads list, plan, run (detached), events, status, init, gate and the error envelope with the app's Swift models (FlowModels.swift).
#   macos/Tools/test-flow.sh [path to gitch-flow]   (default: the app bundle, then tools/gitch-flow/target)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
ENGINE="${1:-}"
if [[ -z "$ENGINE" ]]; then
    for e in "$ROOT/build/Gitrochi.app/Contents/MacOS/gitch-flow" "$REPO_ROOT/tools/gitch-flow/target/release/gitch-flow" "$REPO_ROOT/tools/gitch-flow/target/debug/gitch-flow"; do
        [[ -x "$e" ]] && { ENGINE="$e"; break; }
    done
fi
[[ -x "$ENGINE" ]] || { echo "gitch-flow not found (run macos/build.sh, or cd tools/gitch-flow && cargo build)" >&2; exit 1; }
ENGINE="$(cd "$(dirname "$ENGINE")" && pwd)/$(basename "$ENGINE")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/repo/.gitch" "$T/repo/tests" "$T/empty"
printf '[user]\n\tname = Flow Test\n\temail = flow-test@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$T/home/gitconfig"
# Leaves user settings and the keychain alone, and calls the engine the way the app does, for actions a person clicked.
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache"
export GIT_CONFIG_GLOBAL="$T/home/gitconfig" GIT_CONFIG_NOSYSTEM=1 GITCH_FLOW_NO_KEYSTORE=1 GITSW_ACTOR=gitrochi-app GITCH_FLOW_LANG=en
unset CLAUDECODE CODEX_SANDBOX CODEX_THREAD_ID CODEX_CI CURSOR_AGENT GEMINI_CLI AI_AGENT || true

cat > "$T/repo/tests/r.sh" <<'R'
#!/bin/sh
if [ "${1:-pass}" = pass ]; then printf '<testsuite><testcase classname="m" name="a"/><testcase classname="m" name="b"/></testsuite>' > "$GITCH_FLOW_OUT/junit.xml"; exit 0; fi
printf '<testsuite><testcase classname="m" name="a"><failure message="expected 1 to be 2">at src/a.test.ts:3:1</failure></testcase></testsuite>' > "$GITCH_FLOW_OUT/junit.xml"; exit 1
R
cat > "$T/repo/.gitch/flow.yml" <<'F'
version: 1
project: { name: demo }
suites:
  unit: { use: test.junit, with: { run: "sh tests/r.sh pass", report: "${{ node.out }}/junit.xml" } }
  broken: { use: test.junit, with: { run: "sh tests/r.sh fail", report: "${{ node.out }}/junit.xml" } }
flows:
  ok:
    description: Quick checks
    nodes:
      lint: echo lint
      unit: { needs: [lint], suite: unit }
  bad:
    rollback: { scope: flow, onCheckFailure: true }
    nodes:
      deploy: { run: "echo deployed", undo: "echo undone" }
      broken: { needs: [deploy], suite: broken }
F
(cd "$T/repo" && git init -q && git add -A && git commit -qm init)
printf '{"name":"x","devDependencies":{"vitest":"^2"}}' > "$T/empty/package.json"
(cd "$T/empty" && git init -q)

cd "$T/repo"
"$ENGINE" list --json > "$T/list.json"
"$ENGINE" plan bad --json > "$T/plan.json"
"$ENGINE" trust --yes --json > /dev/null
"$ENGINE" gate status --json > "$T/gate.json"
"$ENGINE" plan nope --json 2> "$T/error.json" > /dev/null || true
wait_done() {   # $1 events file; waits for run.done (at most 60 seconds)
    for _ in $(seq 1 240); do grep -q '"type":"run.done"' "$1" 2>/dev/null && return 0; sleep 0.25; done
    echo "no run.done in $1" >&2; return 1
}
"$ENGINE" run ok --detach --json > "$T/detached-ok.json"
events_ok=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["eventsPath"])' "$T/detached-ok.json")
"$ENGINE" run bad --detach --json > "$T/detached-bad.json"
events_bad=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["eventsPath"])' "$T/detached-bad.json")
wait_done "$events_ok"
wait_done "$events_bad"
cp "$events_ok" "$T/events-ok.ndjson"
cp "$events_bad" "$T/events-bad.ndjson"
sleep 0.5
"$ENGINE" status --all --json > "$T/runs.json"
bad_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runId"])' "$T/detached-bad.json")
"$ENGINE" status "$bad_id" --json > "$T/record-bad.json" || true
(cd "$T/empty" && "$ENGINE" init --dry-run --json > "$T/init.json")
python3 - "$T" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
source = "# Keep this explanation\nversion: 1\nx-custom: {retained: true}\nflows:\n  verify:\n    nodes:\n      check: {run: 'echo checked'}\n"
(folder / "design-source.yml").write_text(source)
(folder / "inspect-request.json").write_text(json.dumps({"yaml": source}))
(folder / "invalid-request.json").write_text(json.dumps({"yaml": "flows: ["}))
PY
"$ENGINE" design inspect --json < "$T/inspect-request.json" > "$T/inspect.json"
"$ENGINE" design inspect --json < "$T/invalid-request.json" > "$T/invalid-design.json"
python3 - "$T" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
inspection = json.loads((folder / "inspect.json").read_text())
(folder / "render-request.json").write_text(json.dumps({"document": inspection["document"], "originalYaml": inspection["yaml"]}))
PY
"$ENGINE" design render --json < "$T/render-request.json" > "$T/render.json"
"$ENGINE" blocks --json > "$T/blocks.json"

cat > "$T/main.swift" <<'SWIFT'
import Foundation
@main struct FlowContract {
    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        func data(_ n: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(n)) }
        let dec = JSONDecoder()
        let list = try dec.decode(FlowList.self, from: data("list.json"))
        precondition(list.project == "demo" && list.flows.map(\.name) == ["ok", "bad"] && !list.trusted, "list: \(list)")
        let plan = try dec.decode(FlowPlan.self, from: data("plan.json"))
        precondition(plan.nodes.first { $0.id == "deploy" }?.run == "echo deployed", "plan run")
        precondition(plan.nodes.first { $0.id == "deploy" }?.undo == "echo undone", "plan undo")
        precondition(plan.trust.changed == [".gitch/flow.yml"], "plan trust")
        let gate = try dec.decode(FlowGate.self, from: data("gate.json"))
        precondition(gate.gate == "OFF")
        let errLine = String(decoding: try data("error.json"), as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        let env = try dec.decode(FlowErrorEnvelope.self, from: Data(errLine.utf8))
        precondition(env.error.flowCode == "PLAN-01", "error envelope: \(env)")
        let d = try dec.decode(FlowDetached.self, from: data("detached-ok.json"))
        precondition(!d.runId.isEmpty && d.eventsPath.hasSuffix("events.ndjson"))
        var ok = FlowRunView(runId: d.runId)
        // Feeding it cut mid-line (as when following a run) must give the same result.
        let all = try data("events-ok.ndjson")
        let cut = all.count / 2
        let used = ok.consume(all.prefix(cut))
        _ = ok.consume(all.dropFirst(used))
        precondition(ok.done && ok.state == "SUCCEEDED", "ok run: \(ok.state)")
        precondition(ok.nodes.map(\.id) == ["lint", "unit"] && ok.nodes.allSatisfy { $0.state == .passed }, "ok nodes")
        precondition(ok.nodes[1].testsExecuted == 2 && ok.nodes[1].log == "logs/unit.log", "ok tests/log")
        precondition(ok.nodes[0].tail.contains("lint"), "log tail: \(ok.nodes[0].tail)")
        var bad = FlowRunView(runId: "bad")
        _ = bad.consume(try data("events-bad.ndjson"))
        precondition(bad.done && bad.state == "ROLLED_BACK", "bad run: \(bad.state)")
        precondition(bad.nodes.first { $0.id == "broken" }?.state == .failed && bad.nodes.first { $0.id == "broken" }?.code == "TEST-01")
        precondition(bad.steps.contains { $0.state == "UNDONE" && $0.node == "deploy" }, "rollback steps: \(bad.steps)")
        struct All: Decodable { let runs: [FlowRunRow] }
        let runs = try dec.decode(All.self, from: data("runs.json")).runs
        precondition(runs.count == 2 && runs.allSatisfy { $0.running == false }, "runs: \(runs)")
        let rec = try dec.decode(FlowJSON.self, from: data("record-bad.json"))
        let broken = rec["nodes"].array.first { $0["id"].string == "broken" }
        precondition(broken?["failures"].array.first?["file"].string == "src/a.test.ts" && broken?["failures"].array.first?["line"].int == 3, "failure location")
        precondition(rec["rollback"]["state"].string == "ROLLED_BACK" && rec["signature"].string != nil)
        let ip = try dec.decode(FlowInitProposal.self, from: data("init.json"))
        precondition(!ip.exists && ip.valid && ip.findings.contains { $0.kind == "vitest" } && ip.yaml.contains("version: 1"), "init")
        let inspection = try dec.decode(FlowDesignInspection.self, from: data("inspect.json"))
        precondition(inspection.editable && inspection.format == "flow")
        precondition(inspection.document?["x-custom"]["retained"] == .bool(true))
        let rendered = try dec.decode(FlowDesignRendered.self, from: data("render.json"))
        precondition(!rendered.formattingChanged && rendered.yaml == inspection.yaml)
        let invalid = try dec.decode(FlowDesignInspection.self, from: data("invalid-design.json"))
        precondition(!invalid.editable && invalid.diagnostics.contains { $0.severity == "error" })
        let catalog = try dec.decode(FlowBlockCatalog.self, from: data("blocks.json"))
        precondition(catalog.blocks.contains { $0.id == "ci.jenkins.job" && !$0.inputs["properties"].object.isEmpty })
        let edited = inspection.document!.setting(["flows", "verify", "nodes", "check", "run"], to: .string("echo edited"))
        precondition(edited["x-custom"]["retained"] == .bool(true) && edited["flows"]["verify"]["nodes"]["check"]["run"].string == "echo edited")
        var connection = FlowConnection.empty
        connection.name = "build-server"; connection.url = "https://ci.example.com"
        precondition(connection.problem == nil)
        connection.url = "https://user:password@ci.example.com"
        precondition(connection.problem != nil)
        print("Flow contract passed: execution, history, design inspect/render, block forms, retained fields and connection references")
    }
}
SWIFT
swiftc -parse-as-library "$ROOT/Sources/Core/FlowModels.swift" "$ROOT/Sources/Core/FlowDesignModels.swift" "$ROOT/Sources/Core/FlowConnectionModels.swift" "$T/main.swift" -o "$T/test-flow"
"$T/test-flow" "$T"
bash "$ROOT/Tools/test-flow-authoring.sh"
