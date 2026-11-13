import AppKit
import SwiftUI
import Vision

private func workspaceRequire(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        fatalError(message)
    }
}

@MainActor private func workspaceSettle(_ seconds: Double = 0.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor private final class WorkspaceShot {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    init<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, dark: Bool) {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light)))
        window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -6000, y: 0))
        window.contentView = host
        host.frame = bounds
        window.orderBack(nil)
    }
    func png() -> Data {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No workspace bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No workspace PNG") }
        return data
    }
    func close() { window.orderOut(nil) }
}

private func workspaceRecognize(_ png: Data) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(data: png).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

/// The engine's timestamp for a moment before now, so the list's "25m ago" stays true whenever the fixture runs
private func workspaceStamp(minutesAgo: Double) -> String {
    ISO8601DateFormatter.flow.string(from: Date().addingTimeInterval(-minutesAgo * 60))
}

private func workspaceNode(_ id: String, _ state: FlowNodeState, needs: [String] = [], title: String? = nil, durationMs: Int? = nil,
                           tests: (passed: Int, executed: Int)? = nil, reason: String? = nil, tail: [String] = []) -> FlowRunView.Node {
    var node = FlowRunView.Node(id: id, title: title ?? id, block: "cmd", needs: needs)
    node.state = state; node.durationMs = durationMs; node.reason = reason; node.tail = tail
    node.testsPassed = tests?.passed; node.testsExecuted = tests?.executed
    return node
}

/// What the engine records for the failed run (run.json): why the step failed, its verdicts and the failed test
private let workspaceRecord = """
{"flow":"verify","state":"FAILED","code":"TEST-01","nodes":[
 {"id":"install","verdicts":[{"rule":"exit","title":"The command exits with 0","result":"PASS","observed":"0"}]},
 {"id":"ui-tests","failure":{"description":"1 of 12 interface tests failed.","action":"Open the run to read the output, fix the test and run the flow again."},
  "verdicts":[{"rule":"exit","title":"The command exits with 0","result":"FAIL","observed":"1"}],
  "failures":[{"name":"Settings saves the form","file":"tests/ui/settings.test.ts","line":42,"message":"expected the Save button to be enabled"}]}
]}
"""

@MainActor private func workspaceStore(repo: URL, trusted: Bool) throws -> (flows: FlowStore, list: FlowList, runId: String) {
    let flows = FlowStore(repo: repo)
    let runId = "run-0024"
    let last = FlowList.Flow.Last(runId: runId, state: "FAILED", finishedAt: workspaceStamp(minutesAgo: 23), durationMs: 152_000, signed: true)
    let list = FlowList(project: "demo", trusted: trusted, flows: [
        .init(name: "verify", description: "Build and check this repository before sharing changes.", trigger: ["manual"], env: "local", nodes: 4, last: last),
        .init(name: "release", description: "Tag and publish a build.", trigger: ["manual"], env: "local", nodes: 1, last: nil),
    ], suites: [])
    flows.list = list
    flows.runs = [
        FlowRunRow(runId: runId, flow: "verify", env: "local", state: "FAILED", code: "TEST-01", running: false, startedAt: workspaceStamp(minutesAgo: 25), durationMs: 152_000, signed: true),
        FlowRunRow(runId: "run-0023", flow: "verify", env: "local", state: "SUCCEEDED", code: nil, running: false, startedAt: workspaceStamp(minutesAgo: 60 * 26), durationMs: 141_000, signed: true),
        FlowRunRow(runId: "run-0022", flow: "verify", env: "local", state: "CANCELLED", code: nil, running: false, startedAt: workspaceStamp(minutesAgo: 60 * 24 * 6), durationMs: 38_000, signed: false),
    ]
    var view = FlowRunView(runId: runId)
    view.flow = "verify"; view.state = "FAILED"; view.code = "TEST-01"; view.done = true
    let output = (1...11).map { "ok \($0) - screen \($0) renders" } + ["not ok 12 - Settings saves the form", "  expected the Save button to be enabled", "1 of 12 tests failed"]
    view.nodes = [
        workspaceNode("install", .passed, title: "Install dependencies", durationMs: 22_000, tail: ["added 412 packages in 21s"]),
        workspaceNode("lint", .passed, needs: ["install"], durationMs: 14_000),
        workspaceNode("ui-tests", .failed, needs: ["install"], title: "Run the interface tests", durationMs: 130_000, tests: (11, 12), reason: "exit status 1", tail: output),
        workspaceNode("package", .skipped, needs: ["lint", "ui-tests"]),
    ]
    flows.views = [runId: view]
    flows.records = [runId: try JSONDecoder().decode(FlowJSON.self, from: Data(workspaceRecord.utf8))]
    return (flows, list, runId)
}

@main struct FlowWorkspaceLayoutFixture {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repo = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let engine = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gitch-flow").path
        workspaceRequire(FlowEngine.executable == engine, "The fixture must use its own bundled current engine")

        let failed = try workspaceStore(repo: repo, trusted: true)
        let changed = try workspaceStore(repo: repo, trusted: false)
        let banner = FlowWorkspaceSummary.banner(trusted: true, latest: FlowWorkspaceSummary.latestRun(of: "verify", in: failed.flows.runs),
                                                 view: failed.flows.view(failed.runId))
        workspaceRequire(banner == .finished(runId: failed.runId, state: "FAILED", tone: .failed, failedStep: "ui-tests", skipped: ["package"], durationMs: 152_000),
                         "Unexpected banner for the fixture run: \(banner)")

        var results: [[String: Any]] = []
        func record(_ shot: WorkspaceShot, name: String, dark: Bool, expect: [String], absent: [String] = []) throws {
            let png = shot.png(), file = "flow-\(name)-\(dark ? "dark" : "light").png"
            try png.write(to: output.appendingPathComponent(file))
            let recognized = try workspaceRecognize(png)
            try recognized.write(to: output.appendingPathComponent(file.replacingOccurrences(of: ".png", with: ".txt")), atomically: true, encoding: .utf8)
            let normalized = recognized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for label in expect {
                workspaceRequire(normalized.localizedCaseInsensitiveContains(label), "\(file): missing \(label)\n\(recognized)")
            }
            for label in absent {
                workspaceRequire(!normalized.localizedCaseInsensitiveContains(label), "\(file): unexpected \(label)\n\(recognized)")
            }
            results.append(["screenshot": file, "theme": dark ? "dark" : "light", "labels": expect])
            shot.close()
        }
        func workspace(_ store: (flows: FlowStore, list: FlowList, runId: String)) -> some View {
            FlowWorkspaceView(flows: store.flows, list: store.list, affected: false, starting: nil,
                              onCreate: {}, onRun: { _ in }, onStop: { _ in }, onOpenRun: { _ in }, onEdit: { _, _ in }, onReview: { _ in },
                              moreActions: { flow in FlowMoreActionsMenu(flows: store.flows, list: store.list, flow: flow, onReview: {}, onSetUp: {}, onError: { _ in }) })
        }
        for dark in [false, true] {
            // three columns: the list, the failed run laid over the plan, and the failed step's details
            let wide = WorkspaceShot(workspace(failed), width: 1440, height: 900, dark: dark)
            workspaceSettle(3)
            try record(wide, name: "workspace-failed", dark: dark,
                       expect: ["verify", "Run flow", "Edit flow file", "Latest run failed at ui-tests", "Skipped: package", "Connected CI",
                                "Failed after 2m 10s", "Run the interface tests", "This computer", "Not run yet", "25m ago"],
                       absent: ["This flow file is new or changed"])

            // a narrower window: the step details go below the graph
            let narrow = WorkspaceShot(workspace(failed), width: 880, height: 900, dark: dark)
            workspaceSettle(3)
            try record(narrow, name: "workspace-narrow", dark: dark, expect: ["Latest run failed at ui-tests", "Run flow", "Failed after 2m 10s"])

            // too narrow for the list: a picker stands in for it
            let compact = WorkspaceShot(workspace(failed), width: 700, height: 900, dark: dark)
            workspaceSettle(3)
            try record(compact, name: "workspace-compact", dark: dark, expect: ["Latest run failed at ui-tests", "New flow"])

            // a changed flow file: the review comes first and the old run's states are not laid over the plan
            let review = WorkspaceShot(workspace(changed), width: 1440, height: 900, dark: dark)
            workspaceSettle(3)
            try record(review, name: "workspace-review", dark: dark, expect: ["This flow file is new or changed", "Review commands", "Run flow"],
                       absent: ["Latest run failed", "Failed after"])

            let sheet = WorkspaceShot(FlowRunSheet(flows: failed.flows, runId: failed.runId), width: 1120, height: 780, dark: dark)
            workspaceSettle(2)
            try record(sheet, name: "run-failed", dark: dark,
                       expect: ["verify", "2 passed", "Failed after 2m 10s", "Failed tests", "Copy summary"])

            let history = WorkspaceShot(FlowHistoryView(runs: failed.flows.runs.filter { $0.flow == "verify" }, onOpen: { _ in }), width: 760, height: 320, dark: dark)
            workspaceSettle(0.8)
            try record(history, name: "history", dark: dark, expect: ["Failures only", "Succeeded", "Canceled"])
        }
        let report: [String: Any] = ["screenshots": results, "count": results.count, "engine": "bundled gitch-flow (plan only)", "productionViews": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("flow-workspace-result.json"))
        print("PASS: \(results.count) production flow workspace screenshots on a failed fixture run; nothing was trusted or run.")
    }
}
