#!/usr/bin/env bash
# What the Flows workspace decides before it draws: the one banner, the latest run laid over the plan, connector
# looks, skip causes, step text, the run sheet's groups, and the card layout. The same cases as
# windows/tests/flow-workspace.test.ts, on the app's own Swift (no engine, no app launch).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cat > "$T/main.swift" <<'SWIFT'
import Foundation

typealias Summary = FlowWorkspaceSummary

func step(_ id: String, _ needs: [String] = [], decision: String = "run", title: String? = nil, run: String? = nil) -> FlowPlan.Node {
    FlowPlan.Node(id: id, title: title, block: "cmd", needs: needs, decision: decision, reason: nil, outward: nil, destructive: nil,
                  branchOf: nil, group: nil, run: run, undo: nil, executor: nil, src: nil)
}
func ran(_ id: String, _ state: FlowNodeState, _ durationMs: Int? = nil) -> FlowRunView.Node {
    var node = FlowRunView.Node(id: id, title: id, block: "cmd", needs: [])
    node.state = state
    node.durationMs = durationMs
    return node
}
func view(_ nodes: [FlowRunView.Node], state: String = "FAILED", done: Bool = true, runId: String = "r24") -> FlowRunView {
    var view = FlowRunView(runId: runId)
    view.flow = "verify"; view.state = state; view.done = done; view.nodes = nodes
    return view
}
func row(runId: String = "r24", state: String = "FAILED", running: Bool? = false, startedAt: String? = nil, flow: String = "verify") -> FlowRunRow {
    FlowRunRow(runId: runId, flow: flow, env: nil, state: state, code: nil, running: running, startedAt: startedAt, durationMs: 152_000, signed: nil)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { fatalError("line \(line): \(message)") }
}

@main struct FlowWorkspaceTests {
    static func main() {
        let plan = [step("install"), step("lint", ["install"]), step("ui-tests", ["install"]), step("package", ["lint", "ui-tests"])]
        let failedRun = view([ran("install", .passed, 22_000), ran("lint", .passed, 14_000), ran("ui-tests", .failed, 130_000), ran("package", .skipped)])

        // Banner
        expect(Summary.banner(trusted: true, latest: row(), view: failedRun)
               == .finished(runId: "r24", state: "FAILED", tone: .failed, failedStep: "ui-tests", skipped: ["package"], durationMs: 152_000),
               "names the failed step and what was skipped because of it")
        expect(Summary.banner(trusted: false, latest: row(), view: failedRun) == .review, "asks for a review once the flow file changed")
        expect(Summary.banner(trusted: false, latest: nil, view: nil) == .review, "asks for a review before any run")
        let live = view([ran("install", .passed), ran("lint", .running)], state: "RUNNING", done: false)
        expect(Summary.banner(trusted: false, latest: row(state: "RUNNING", running: true, startedAt: "2026-10-30T00:00:00Z"), view: live)
               == .running(runId: "r24", step: "lint", startedAt: "2026-10-30T00:00:00Z"), "follows a running flow even when the file changed under it")
        expect(Summary.banner(trusted: true, latest: nil, view: nil) == .ready, "says nothing ran yet instead of inventing a state")
        expect(Summary.banner(trusted: true, latest: row(runId: "r25", state: "SUCCEEDED"), view: failedRun)
               == .finished(runId: "r25", state: "SUCCEEDED", tone: .passed, failedStep: nil, skipped: [], durationMs: 152_000),
               "reports a passed run and never reads steps from another run's view")
        expect(Summary.banner(trusted: true, latest: row(state: "RUNNING", running: false), view: nil)
               == .finished(runId: "r24", state: "INTERRUPTED", tone: .waiting, failedStep: nil, skipped: [], durationMs: 152_000),
               "presents a run whose engine stopped as interrupted, not as running")

        // What the workspace shows around the banner
        let runs = [row(runId: "r30", flow: "other"), row(runId: "r26", state: "SUCCEEDED"), row(runId: "r25", state: "RUNNING", running: true), row()]
        expect(Summary.latestRun(of: "verify", in: runs)?.runId == "r25", "prefers the run that is going")
        expect(Summary.latestRun(of: "verify", in: runs.filter { $0.running != true })?.runId == "r26", "else takes the newest run of the flow")
        expect(Summary.latestRun(of: "missing", in: runs) == nil, "has no latest run for a flow that never ran")
        expect(Summary.resultsView(.review, view: failedRun) == nil, "shows no results while the flow file waits for a review")
        expect(Summary.resultsView(.ready, view: failedRun) == failedRun, "keeps the run's results otherwise")
        expect(Summary.progress(live) == (1, 2) && Summary.progress(nil) == (0, 0), "counts the steps that are done")
        expect(Summary.attentionStep(failedRun) == "ui-tests" && Summary.attentionStep(live) == "lint", "opens on the failed step, else the running one")
        expect(Summary.attentionStep(view([ran("install", .passed)])) == nil && Summary.attentionStep(nil) == nil, "leaves the selection alone when nothing needs attention")

        // Steps with the latest run laid over the plan
        let steps = Summary.steps(plan, view: failedRun)
        expect(steps.map(\.id) == ["install", "lint", "ui-tests", "package"]
               && steps.map(\.state) == ["PASSED", "PASSED", "FAILED", "SKIPPED"]
               && steps.map(\.durationMs) == [22_000, 14_000, 130_000, nil], "shows each step's recorded state and duration")
        let extended = Summary.steps(plan + [step("docs"), step("deploy", decision: "skip"), step("release", decision: "rejected")], view: failedRun)
        expect(extended.first { $0.id == "docs" }?.state == nil, "gives a step the run never saw no state")
        expect(extended.first { $0.id == "deploy" }?.state == "SKIPPED" && extended.first { $0.id == "release" }?.state == "REJECTED", "keeps what the plan already decided")
        expect(Summary.steps(plan).allSatisfy { $0.state == nil }, "has no states before any run")
        let unfinished = [ran("install", .passed), ran("lint", .running), ran("ui-tests", .pending)]
        expect(Summary.steps(plan, view: view(unfinished, state: "RUNNING", done: true)).map(\.state) == ["PASSED", nil, nil, nil],
               "drops running and waiting marks once the run has ended without them finishing")
        expect(Summary.steps(plan, view: view(unfinished, state: "RUNNING", done: false)).map(\.state) == ["PASSED", "RUNNING", "PENDING", nil],
               "keeps them while the run is going")
        expect(Summary.skipCause(steps[3], in: steps) == "ui-tests" && Summary.skipCause(steps[2], in: steps) == nil, "names the step a skipped one was waiting for")
        let plannedSkip = Summary.steps([step("deploy", decision: "skip")])
        expect(Summary.skipCause(plannedSkip[0], in: plannedSkip) == nil, "gives no cause for a skip the plan decided")

        // The step details' one line about the latest run
        expect(Summary.outcome(steps[2], in: steps) == .failed(afterMs: 130_000), "says how long a failed step ran")
        expect(Summary.outcome(steps[0], in: steps) == .passed(inMs: 22_000), "says how long a passed step took")
        expect(Summary.outcome(steps[3], in: steps) == .skipped(because: "ui-tests"), "says why a step was skipped")
        expect(Summary.outcome(plannedSkip[0], in: plannedSkip) == .state("SKIPPED"), "falls back to the state's own name")
        expect(Summary.outcome(Summary.steps(plan)[0], in: Summary.steps(plan)) == nil, "says nothing before a step has a state")

        // Graph and step text
        expect(Summary.edgeLook(from: "PASSED", to: "FAILED") == .init(failed: true, dashed: false), "colours the failed path")
        expect(Summary.edgeLook(from: "FAILED", to: "SKIPPED") == .init(failed: true, dashed: true), "dashes the failed path into a skipped step")
        expect(Summary.edgeLook(from: "PASSED", to: "PASSED") == .init(failed: false, dashed: false), "leaves passed connectors neutral")
        expect(Summary.edgeLook(from: nil, to: nil) == .init(failed: false, dashed: false), "leaves planned connectors neutral")
        expect(Summary.edgeLook(from: "PASSED", to: "SKIPPED") == .init(failed: false, dashed: true), "dashes connectors into skipped steps")
        expect(["SUCCEEDED", "PASSED", "CACHED"].map(Summary.tone) == [.passed, .passed, .passed], "passed tone")
        expect(["FAILED", "INDETERMINATE", "ROLLBACK_FAILED"].map(Summary.tone) == [.failed, .failed, .failed], "failed tone")
        expect(["RUNNING", "ROLLED_BACK", "REJECTED", "INTERRUPTED"].map(Summary.tone) == [.waiting, .waiting, .waiting, .waiting], "waiting tone")
        expect([nil, "", "SKIPPED", "CANCELLED", "PENDING"].map(Summary.tone) == [.neutral, .neutral, .neutral, .neutral, .neutral], "neutral tone")
        expect(Summary.stepSummary(id: "install", title: "Install dependencies") == "Install dependencies", "uses a step's own words")
        expect(Summary.stepSummary(id: "install", title: "install") == nil && Summary.stepSummary(id: "install", title: "Command") == nil
               && Summary.stepSummary(id: "install", title: nil) == nil, "only when the flow file gives any")
        expect(Summary.stepSummary(id: "install", title: "명령") == nil, "knows the engine's own name for a step in Korean too")
        expect(Summary.stepCommand("\n# set up\n  npm ci\nnpm test") == "npm ci" && Summary.stepCommand(nil) == nil, "shows the first real line of a script as the command")
        let lines = (1...20).map { "line \($0)" }
        let folded = Summary.logTail(lines, shown: 8), short = Summary.logTail(Array(lines.prefix(3)), shown: 8)
        expect(folded.hidden == 12 && folded.lines == Array(lines.suffix(8)), "folds earlier output lines and counts them")
        expect(short.hidden == 0 && short.lines == Array(lines.prefix(3)), "shows short output whole")

        // One run: groups in the order a person needs them
        let mixed = [ran("install", .passed), ran("lint", .cached), ran("ui-tests", .failed), ran("docs", .cancelled), ran("build", .running),
                     ran("deploy", .pending), ran("package", .skipped)]
        let groups = Summary.runGroups(mixed)
        expect(groups.map(\.state) == ["FAILED", "RUNNING", "PENDING", "SKIPPED", "PASSED"], "orders the groups: failed, running, waiting, skipped, passed")
        expect(groups.map { $0.nodes.map(\.id) } == [["ui-tests", "docs"], ["build"], ["deploy"], ["package"], ["install", "lint"]], "puts each step in one group")
        expect(groups.map(\.folds) == [false, false, false, false, true], "folds only the passed group")
        expect(Summary.runGroups([ran("install", .passed)]).map(\.state) == ["PASSED"], "leaves out groups without steps")
        expect(!Summary.passedOpenByDefault(mixed) && Summary.passedOpenByDefault([ran("install", .passed), ran("lint", .cached)]),
               "opens the passed group only when every step passed")
        expect(Summary.runFocus(mixed) == "build" && Summary.runFocus(failedRun.nodes) == "ui-tests"
               && Summary.runFocus([ran("install", .passed)]) == "install" && Summary.runFocus([]) == nil, "shows the running step, else the failed one, else the first")
        var needy = ran("package", .skipped)
        needy.needs = ["lint", "ui-tests"]
        let runSteps = (failedRun.nodes.dropLast() + [needy]).map(Summary.step)
        expect(runSteps[3].node.decision == "run" && Summary.skipCause(runSteps[3], in: runSteps) == "ui-tests", "names what a skipped step of a run needed")

        // Lists
        let flows = [FlowList.Flow(name: "verify", description: "Build and check", trigger: [], env: nil, nodes: 4,
                                   last: .init(runId: "r1", state: "SUCCEEDED", finishedAt: "2026-10-29T00:00:00Z", durationMs: 10, signed: true)),
                     FlowList.Flow(name: "release", description: nil, trigger: [], env: nil, nodes: 2, last: nil)]
        expect(Summary.matchingFlows(flows, search: " CHECK ").map(\.name) == ["verify"] && Summary.matchingFlows(flows, search: "").count == 2, "searches names and descriptions")
        let recorded = Summary.libraryStatus(flows[0], latest: nil), fresh = Summary.libraryStatus(flows[0], latest: row(state: "RUNNING", startedAt: "2026-10-30T00:00:00Z"))
        expect(recorded.state == "SUCCEEDED" && recorded.at == "2026-10-29T00:00:00Z", "falls back to the flow's last recorded run")
        expect(fresh.state == "INTERRUPTED" && fresh.at == "2026-10-30T00:00:00Z", "prefers the latest run row, as it is presented")
        let never = Summary.libraryStatus(flows[1], latest: nil)
        expect(never.state == nil && never.at == nil, "has nothing to say about a flow that never ran")
        let history = [row(runId: "r3", state: "SUCCEEDED"), row(runId: "r2", state: "ROLLED_BACK"), row(runId: "r1", state: "RUNNING", running: false)]
        let title: (String) -> String = { ["SUCCEEDED": "Succeeded", "ROLLED_BACK": "Failed and rolled back", "INTERRUPTED": "Interrupted"][$0] ?? $0 }
        expect(Summary.historyRuns(history, search: "", failuresOnly: true, title: title).map(\.runId) == ["r2"], "keeps only runs that did not end well")
        expect(Summary.historyRuns(history, search: "interr", failuresOnly: false, title: title).map(\.runId) == ["r1"], "searches the state as the screen words it")
        expect(Summary.historyRuns(history, search: "R3", failuresOnly: false, title: title).map(\.runId) == ["r3"], "searches run IDs")

        // Card layout: the same coordinates as FLOW_CARD in windows/src/entities/flow/model/graph.ts
        expect(FlowGraphLayout.cardWidth == 192 && FlowGraphLayout.cardHeight == 80 && FlowGraphLayout.columnGap == 40
               && FlowGraphLayout.rowGap == 14 && FlowGraphLayout.margin == 24, "card constants")
        expect(FlowGraphLayout.columnPitch == 232 && FlowGraphLayout.rowPitch == 94, "pitches")
        let layout = FlowGraphLayout.make(plan.map { .init(id: $0.id, needs: $0.needs) })
        expect(layout.items.map { [$0.x, $0.y] } == [[24, 24], [256, 24], [256, 118], [488, 24]], "lays the plan out on the card grid")
        expect(layout.width == 704 && layout.height == 222, "sizes the canvas around the cards")
        let empty = FlowGraphLayout.make([])
        expect(empty.width == 240 && empty.height == 128, "keeps room for one card when there is none")
        expect(FlowGraphLayout.fit(layout, viewport: CGSize(width: 728, height: 246)) == 1, "fits at full size when there is room")
        expect(abs(FlowGraphLayout.fit(layout, viewport: CGSize(width: 376, height: 400)) - 0.5) < 0.0001, "keeps 24 pt around a fitted graph")

        // Columns by the width of the workspace
        let wide = Summary.Columns(width: 1440), medium = Summary.Columns(width: 1000), narrow = Summary.Columns(width: 860), compact = Summary.Columns(width: 700)
        expect(wide.library == 312 && wide.details == 340 && !wide.detailsBelow && wide.inset == 24, "wide window")
        expect(medium.library == 240 && medium.details == 296 && !medium.detailsBelow && medium.inset == 16, "narrower window")
        expect(narrow.library == 240 && narrow.detailsBelow, "the step details go below the graph")
        expect(compact.library == nil && compact.detailsBelow, "the list becomes a picker")
        print("Flow workspace passed: banner, steps over the plan, outcomes, connectors, step text, run groups, lists, card layout and columns")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
    "$ROOT/Sources/Core/FlowModels.swift" "$ROOT/Sources/Core/FlowRunHistory.swift" "$ROOT/Sources/Core/FlowGraphLayout.swift" \
    "$ROOT/Sources/Core/FlowWorkspaceSummary.swift" "$T/main.swift" -o "$T/test-flow-workspace"
"$T/test-flow-workspace"
