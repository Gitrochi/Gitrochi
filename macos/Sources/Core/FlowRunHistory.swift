import Foundation

/// Recovery from the engine's final record, mirrored by Windows entities/flow/model/history.ts.
enum FlowRunHistory {
    private static let activeStates: Set<String> = ["RUNNING", "PENDING", "PREFLIGHT", "ROLLING_BACK"]
    private static let terminalStates: Set<String> = ["SUCCEEDED", "FAILED", "REJECTED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED"]

    /// Single-run status only checks the PID for RUNNING; other active states need the all-runs status.
    static func isRunning(_ record: FlowJSON, observedRunning: Bool? = nil) -> Bool {
        let state = record["state"].string ?? ""
        if terminalStates.contains(state) || record["finishedAt"].string != nil { return false }
        if let observedRunning { return observedRunning }
        return activeStates.contains(state) && (state != "RUNNING" || record["running"].bool != false)
    }

    /// A stopped process is presentation information, never a replacement for an engine verdict.
    static func presentationState(_ view: FlowRunView) -> String {
        view.done && activeStates.contains(view.state) ? "INTERRUPTED" : view.state
    }

    static func presentationState(_ run: FlowRunRow) -> String {
        run.running == false && activeStates.contains(run.state) ? "INTERRUPTED" : run.state
    }

    /// Preserve event output, recover final node metadata and read edges only from the run's saved plan.
    static func recover(_ view: FlowRunView, record: FlowJSON, savedPlan: FlowJSON? = nil, observedRunning: Bool? = nil) -> FlowRunView {
        var result = view
        let finalRecord = terminalStates.contains(record["state"].string ?? "") || record["finishedAt"].string != nil
        let planned = savedPlan?["nodes"].array ?? []
        let recorded = record["nodes"].array
        let plans = Dictionary(planned.compactMap { node in node["id"].string.map { ($0, node) } }, uniquingKeysWith: { first, _ in first })
        let records = Dictionary(recorded.compactMap { node in node["id"].string.map { ($0, node) } }, uniquingKeysWith: { first, _ in first })
        let events = Dictionary(view.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let ids = (planned.compactMap { $0["id"].string } + recorded.compactMap { $0["id"].string } + view.nodes.map(\.id)).filter { seen.insert($0).inserted }
        result.nodes = ids.map { id in
            let plan = plans[id] ?? .null
            let rec = records[id] ?? .null
            var node = events[id] ?? FlowRunView.Node(id: id, title: plan["title"].string ?? id, block: plan["block"].string ?? "", needs: [], branchOf: plan["branchOf"].string)
            node.title = rec["title"].string ?? node.title
            node.block = rec["block"].string ?? node.block
            if plans[id] != nil { node.needs = plan["needs"].array.compactMap(\.string) }
            node.branchOf = rec["branchOf"].string ?? node.branchOf
            if let state = rec["state"].string.flatMap(FlowNodeState.init(rawValue:)) { node.state = state }
            node.code = rec["code"].string ?? node.code
            node.durationMs = rec["durationMs"].int ?? node.durationMs
            node.testsPassed = rec["tests"]["passed"].int ?? node.testsPassed
            node.testsExecuted = rec["tests"]["executed"].int ?? node.testsExecuted
            node.reason = rec["reason"]["message"].string ?? rec["reason"].string ?? node.reason
            node.log = rec["log"].string ?? node.log
            return node
        }
        result.flow = record["flow"].string ?? result.flow
        if finalRecord || result.state == "PENDING" { result.state = record["state"].string ?? result.state }
        if finalRecord { result.code = record["code"].string }
        result.exitCode = record["exitCode"].int ?? result.exitCode
        result.done = result.done || !isRunning(record, observedRunning: observedRunning)
        return result
    }
}
