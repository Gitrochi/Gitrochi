import Foundation

/// What the Flows workspace says about a flow before anyone opens a run: the one banner above the graph, the latest
/// run's state on each step, and which connectors belong to the failed path. Every decision the screen makes is here,
/// so the views only draw and both platforms can test the same answers.
/// (Windows: entities/flow/model/workspace.ts)
enum FlowWorkspaceSummary {
    private static let passedStates: Set<String> = ["SUCCEEDED", "PASSED", "CACHED"]
    private static let failedStates: Set<String> = ["FAILED", "INDETERMINATE", "ROLLBACK_FAILED"]
    private static let runningStates: Set<String> = ["RUNNING", "PREFLIGHT", "ROLLING_BACK"]
    private static let heldStates: Set<String> = ["ROLLED_BACK", "REJECTED", "INTERRUPTED"]
    /// What the History tab's "Failures only" keeps: every run that did not end well
    private static let historyFailures: Set<String> = ["FAILED", "REJECTED", "INDETERMINATE", "ROLLBACK_FAILED", "ROLLED_BACK"]

    // MARK: Tone

    /// The status tone a run or step state is drawn in (docs/design.md, Badges)
    enum Tone: Equatable {
        case passed, failed, waiting, neutral
    }

    static func tone(_ state: String?) -> Tone {
        guard let state, !state.isEmpty else { return .neutral }
        if passedStates.contains(state) { return .passed }
        if failedStates.contains(state) { return .failed }
        if runningStates.contains(state) || heldStates.contains(state) { return .waiting }
        return .neutral
    }

    // MARK: Banner

    /// The single strip above the graph. Exactly one applies, in this order.
    enum Banner: Equatable {
        /// A run is going: say which step, and offer the run.
        case running(runId: String, step: String?, startedAt: String?)
        /// The flow file is new or changed: its commands must be read before anything runs.
        case review
        /// The latest run ended: how, where it failed and what it skipped because of that.
        case finished(runId: String, state: String, tone: Tone, failedStep: String?, skipped: [String], durationMs: Int?)
        /// Nothing ran yet: say what Run flow will do.
        case ready
    }

    static func banner(trusted: Bool, latest: FlowRunRow?, view: FlowRunView?) -> Banner {
        // Steps are read only from the latest run's own view, never from another run's.
        let nodes = view.flatMap { $0.runId == latest?.runId ? $0.nodes : nil } ?? []
        if let latest, latest.running == true {
            return .running(runId: latest.runId, step: nodes.first { $0.state == .running }?.id, startedAt: latest.startedAt)
        }
        if !trusted { return .review }
        guard let latest else { return .ready }
        let state = FlowRunHistory.presentationState(latest)
        return .finished(runId: latest.runId, state: state, tone: tone(state),
                         failedStep: nodes.first { failedStates.contains($0.state.rawValue) }?.id,
                         skipped: nodes.filter { $0.state == .skipped }.map(\.id),
                         durationMs: latest.durationMs)
    }

    /// The run the workspace talks about: the one that is going, else the newest (the engine lists runs newest first).
    static func latestRun(of flow: String, in runs: [FlowRunRow]) -> FlowRunRow? {
        let own = runs.filter { $0.flow == flow }
        return own.first { $0.running == true } ?? own.first
    }

    /// The run whose results the graph and the step details show. A changed flow file has no results yet: the old
    /// run's states would describe commands that no longer exist.
    static func resultsView(_ banner: Banner, view: FlowRunView?) -> FlowRunView? {
        banner == .review ? nil : view
    }

    /// How far a running flow is, for the banner's progress line
    static func progress(_ view: FlowRunView?) -> (done: Int, total: Int) {
        let nodes = view?.nodes ?? []
        return (nodes.filter(\.state.isDone).count, nodes.count)
    }

    /// The step a flow opens on until the person picks one themselves: the one that failed, else the one running.
    static func attentionStep(_ view: FlowRunView?) -> String? {
        let nodes = view?.nodes ?? []
        return nodes.first { $0.state.isBad }?.id ?? nodes.first { $0.state == .running }?.id
    }

    // MARK: Steps

    /// One step as the graph and the step details show it: the plan's step with the latest run's outcome laid over it.
    struct Step: Identifiable, Equatable {
        let node: FlowPlan.Node
        /// The engine's state in the latest run, or what the plan already decided (skip, rejected); nil before any run
        let state: String?
        let durationMs: Int?
        var id: String { node.id }
    }

    /// Lays the latest run over the plan. A step the run never saw (added since) keeps no state, so the graph never
    /// claims a result the engine did not record.
    static func steps(_ plan: [FlowPlan.Node], view: FlowRunView? = nil) -> [Step] {
        let ran = Dictionary((view?.nodes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.map { node in
            guard let run = ran[node.id] else {
                let planned = node.decision == "skip" ? "SKIPPED" : node.decision == "rejected" ? "REJECTED" : nil
                return Step(node: node, state: planned, durationMs: nil)
            }
            // Once the run has ended, a step still marked waiting or running never finished: it has no result to show.
            let unfinished = view?.done == true && !run.state.isDone
            return Step(node: node, state: unfinished ? nil : run.state.rawValue, durationMs: run.durationMs)
        }
    }

    /// How a connector is drawn
    struct EdgeLook: Equatable {
        /// On the failed path, the one coloured connector
        let failed: Bool
        let dashed: Bool
    }

    /// A connector is red only on the failed path, and dashed into a step that was skipped.
    static func edgeLook(from: String?, to: String?) -> EdgeLook {
        EdgeLook(failed: failedStates.contains(to ?? "") || failedStates.contains(from ?? ""), dashed: to == "SKIPPED")
    }

    /// Why a step was skipped, when the reason is on the graph: the first step it needs that did not pass.
    static func skipCause(_ step: Step, in steps: [Step]) -> String? {
        guard step.state == "SKIPPED" else { return nil }
        let states = Dictionary(steps.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        return step.node.needs.first { id in
            guard let state = states[id] ?? nil else { return false }
            return !passedStates.contains(state)
        }
    }

    /// The one line the step details say about the latest run
    enum Outcome: Equatable {
        case failed(afterMs: Int)
        case passed(inMs: Int)
        case skipped(because: String)
        /// Nothing more specific to say than the state's own name
        case state(String)
    }

    static func outcome(_ step: Step, in steps: [Step]) -> Outcome? {
        guard let state = step.state else { return nil }
        if tone(state) == .failed, let took = step.durationMs { return .failed(afterMs: took) }
        if state == "PASSED", let took = step.durationMs { return .passed(inMs: took) }
        if let cause = skipCause(step, in: steps) { return .skipped(because: cause) }
        return .state(state)
    }

    // MARK: One run

    /// A run's step in the shape the step details draw: the run is its own plan.
    static func step(_ node: FlowRunView.Node) -> Step {
        Step(node: FlowPlan.Node(id: node.id, title: node.title, block: node.block, needs: node.needs, decision: "run",
                                 reason: nil, outward: nil, destructive: nil, branchOf: node.branchOf, group: nil,
                                 run: nil, undo: nil, executor: nil, src: nil),
             state: node.state.rawValue, durationMs: node.durationMs)
    }

    /// The steps of a run that ended the same way, under the state that names them
    struct RunGroup: Identifiable, Equatable {
        let state: String
        let nodes: [FlowRunView.Node]
        var id: String { state }
        /// Passed steps can be folded away; the others are what a person came to read
        var folds: Bool { state == "PASSED" }
    }

    /// A run's steps in the order a person needs them: what failed, what is going, what waits, what was left out,
    /// what passed. A group without steps is left out.
    static func runGroups(_ nodes: [FlowRunView.Node]) -> [RunGroup] {
        let groups: [(String, (FlowNodeState) -> Bool)] = [
            ("FAILED", { $0.isBad }),
            ("RUNNING", { $0 == .running }),
            ("PENDING", { $0 == .pending }),
            ("SKIPPED", { $0 == .skipped }),
            ("PASSED", { $0 == .passed || $0 == .cached }),
        ]
        return groups.compactMap { state, has in
            let members = nodes.filter { has($0.state) }
            return members.isEmpty ? nil : RunGroup(state: state, nodes: members)
        }
    }

    /// Passed steps fold away while something else needs reading; a run where everything passed shows them.
    static func passedOpenByDefault(_ nodes: [FlowRunView.Node]) -> Bool {
        nodes.allSatisfy { $0.state == .passed || $0.state == .cached }
    }

    /// The step a run shows until the person chooses one: the one running, else the first that failed, else the first.
    static func runFocus(_ nodes: [FlowRunView.Node]) -> String? {
        (nodes.first { $0.state == .running } ?? nodes.first { $0.state.isBad } ?? nodes.first)?.id
    }

    // MARK: Step text

    /// What the engine calls a step that has no description: its block's name, in the language the engine was asked
    /// for (tools/gitch-flow/src/blocks/cmd.rs). Those are not the step's own words.
    private static let engineStepTitles: Set<String> = ["Command", "명령"]

    /// A step's own words, when the flow file gives it any beyond its name
    static func stepSummary(id: String, title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              title != id, !engineStepTitles.contains(title) else { return nil }
        return title
    }

    /// The first line a person would recognise from the step's script
    static func stepCommand(_ run: String?) -> String? {
        run?.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The end of a step's output, with how many earlier lines are folded away
    static func logTail(_ lines: [String], shown: Int) -> (hidden: Int, lines: [String]) {
        let start = max(0, lines.count - max(0, shown))
        return (start, Array(lines[start...]))
    }

    // MARK: Layout

    /// The columns for a width of the workspace, as flow-workspace.css draws them
    struct Columns: Equatable {
        /// The list column; nil when the window is too narrow for it and a picker above the flow stands in
        let library: CGFloat?
        /// The step details column
        let details: CGFloat
        /// Too narrow for the graph and the step side by side: the step details go below the graph
        let detailsBelow: Bool
        /// The side padding of the flow's header and tabs
        let inset: CGFloat

        init(width: CGFloat) {
            let roomy = width > 1180
            library = width < 780 ? nil : roomy ? 312 : 240
            details = roomy ? 340 : 296
            detailsBelow = width <= 900
            inset = roomy ? 24 : 16
        }
    }

    // MARK: Lists

    /// The flows the list column shows for a search over names and descriptions
    static func matchingFlows(_ flows: [FlowList.Flow], search: String) -> [FlowList.Flow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return flows }
        return flows.filter { ($0.name + " " + ($0.description ?? "")).localizedCaseInsensitiveContains(query) }
    }

    /// What a list row says about a flow's latest run: its state, and when it ran. Both nil before any run.
    static func libraryStatus(_ flow: FlowList.Flow, latest: FlowRunRow?) -> (state: String?, at: String?) {
        (latest.map(FlowRunHistory.presentationState) ?? flow.last?.state, latest?.startedAt ?? flow.last?.finishedAt)
    }

    /// The History tab's rows: a search over run IDs and state names (as the screen words them), and failures only.
    static func historyRuns(_ runs: [FlowRunRow], search: String, failuresOnly: Bool, title: (String) -> String) -> [FlowRunRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return runs.filter { run in
            let state = FlowRunHistory.presentationState(run)
            return (!failuresOnly || historyFailures.contains(state))
                && (query.isEmpty || run.runId.localizedCaseInsensitiveContains(query) || title(state).localizedCaseInsensitiveContains(query))
        }
    }
}
