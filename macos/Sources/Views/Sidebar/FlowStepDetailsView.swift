import SwiftUI

/// The right column: everything about the selected step in reading order. First how it did in the latest run and
/// why, then what it runs, then what it needs and where it is written. (Windows: FlowStepDetails.tsx)
struct FlowStepDetailsView: View {
    /// How many lines of output show before "Show N earlier lines"
    private static let outputLines = 8

    let step: FlowWorkspaceSummary.Step?
    /// Every step of the flow, to name the step a skipped one was waiting for
    let steps: [FlowWorkspaceSummary.Step]
    /// The step in the latest run: its reason and the end of its output
    var run: FlowRunView.Node? = nil
    /// The latest run's record (run.json), which holds the engine's verdicts
    var record: FlowJSON? = nil
    let onEdit: () -> Void
    /// Left out when no run has this step
    var onOpenRun: (() -> Void)? = nil

    var body: some View {
        Group {
            if let step {
                VStack(spacing: 0) {
                    FlowStepHeader(id: step.id, block: step.node.block) {
                        Button("Edit step…", action: onEdit).buttonStyle(HostedListTextButtonStyle())
                    }
                    ScrollView { content(step).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                }
            } else {
                Text("Choose a step to inspect its script and dependencies.")
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption).multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.vertical, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(StudioStyle.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step details")
    }

    private func content(_ step: FlowWorkspaceSummary.Step) -> some View {
        let recorded = FlowStepRecord(record, step: step.id)
        let node = step.node
        return VStack(alignment: .leading, spacing: 16) {
            if let summary = FlowWorkspaceSummary.stepSummary(id: step.id, title: node.title) {
                Text(verbatim: summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            FlowStepOutcome(step: step, steps: steps, reason: recorded.reason ?? run?.reason, action: recorded.action, onOpenRun: onOpenRun)
            FlowStepVerdicts(verdicts: recorded.verdicts)
            if let run, !run.tail.isEmpty { FlowStepOutput(lines: run.tail, shown: Self.outputLines).id(step.id) }
            if let script = node.run { FlowStepSection(title: "Command") { FlowScriptBox(text: script) } }
            if let undo = node.undo { FlowStepSection(title: "Undo script") { FlowScriptBox(text: undo) } }
            facts(node)
            notes(node)
        }
    }

    /// What the step needs, where it runs and where it is written
    private func facts(_ node: FlowPlan.Node) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(StudioStyle.border).frame(height: 1).padding(.bottom, 8)
            fact("Needs") {
                if node.needs.isEmpty {
                    Text("None").font(.system(size: 13)).foregroundStyle(HostedList.caption)
                } else {
                    WorkbenchFlow(spacing: 4) {
                        ForEach(node.needs, id: \.self) { id in
                            Text(verbatim: id).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                .padding(.horizontal, 8).frame(height: 20)
                                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.Tone.neutral.fill))
                        }
                    }
                }
            }
            fact("Runs on") {
                if let executor = node.executor, executor != "local" {
                    Text(verbatim: executor).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text("This computer").font(.system(size: 13))
                }
            }
            if let source = node.src {
                fact("Source") { Text(verbatim: source).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
            }
        }
    }

    private func fact<Value: View>(_ name: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).font(.system(size: 12)).foregroundStyle(HostedList.caption).frame(width: 72, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }

    /// Why the plan decided what it did, and what a person should know before running the step
    @ViewBuilder
    private func notes(_ node: FlowPlan.Node) -> some View {
        if let reason = node.reason?.message, !reason.isEmpty {
            Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true)
        }
        if node.outward == true { caution("Acts outside this computer") }
        if node.destructive == true { caution("hard to undo") }
    }

    private func caution(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SymbolIcon("exclamationmark.triangle").font(.system(size: 12)).accessibilityHidden(true)
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(StudioStyle.Tone.waiting.text)
    }
}

/// What the run's record (run.json) says about one step, read once for the views that show it
struct FlowStepRecord {
    let node: FlowJSON

    init(_ record: FlowJSON?, step: String) {
        node = record?["nodes"].array.first { $0["id"].string == step } ?? .null
    }

    /// The engine's description of the failure, when it wrote one
    var reason: String? { node["failure"]["description"].string }
    /// What the engine says to do about it
    var action: String? { node["failure"]["action"].string }
    var verdicts: [FlowJSON] { node["verdicts"].array }
    var failedTests: [FlowJSON] { node["failures"].array }
}

/// The 44 pt header of a step, in the workspace and in a run: its id, what kind of step it is, and one action
struct FlowStepHeader<Action: View>: View {
    let id: String
    let block: String
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: id).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                StatusPill(title: FlowBlockStyle.look(block).title, symbol: nil, tone: .neutral)
                Spacer(minLength: 8)
                action
            }
            .padding(.leading, 16).padding(.trailing, 12)
            .frame(height: 43)
            Rectangle().fill(StudioStyle.border).frame(height: 1)
        }
    }
}

/// The outcome in one line ("Failed after 2m 10s") in its status tone, the engine's reason below it, and the way
/// into the run. Nothing before the step has a state.
struct FlowStepOutcome: View {
    let step: FlowWorkspaceSummary.Step
    let steps: [FlowWorkspaceSummary.Step]
    /// The engine's own words for why
    var reason: String? = nil
    var action: String? = nil
    var onOpenRun: (() -> Void)? = nil

    var body: some View {
        if let outcome = FlowWorkspaceSummary.outcome(step, in: steps) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    FlowStateIcon(state: step.state, size: 14, spins: true)
                    Text(verbatim: line(outcome)).font(.system(size: 12))
                        .foregroundStyle(FlowWorkspaceSummary.tone(step.state).style.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason, !reason.isEmpty { detail(reason) }
                if let action, !action.isEmpty { detail(action) }
                if let onOpenRun {
                    Button("Open run…", action: onOpenRun).buttonStyle(HostedListButtonStyle()).padding(.top, 4)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func line(_ outcome: FlowWorkspaceSummary.Outcome) -> String {
        switch outcome {
        case .failed(let took): return String(localized: "Failed after \(FlowFormat.duration(took))")
        case .passed(let took): return String(localized: "Passed in \(FlowFormat.duration(took))")
        case .skipped(let cause): return String(localized: "Skipped because \(cause) did not pass")
        case .state(let state): return FlowFormat.stateTitle(state)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(HostedList.caption)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .padding(.leading, 22)
    }
}

/// The engine's own checks for a step, exactly as it judged them
struct FlowStepVerdicts: View {
    let verdicts: [FlowJSON]

    var body: some View {
        if !verdicts.isEmpty {
            FlowStepSection(title: "Verdicts") {
                ForEach(Array(verdicts.enumerated()), id: \.offset) { _, verdict in
                    HStack(spacing: 8) {
                        FlowStateIcon(state: verdict["result"].string == "PASS" ? "PASSED" : "FAILED", size: 12)
                        Text(verbatim: verdict["rule"].string ?? "").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HostedList.caption).fixedSize()
                        Text(verbatim: verdict["title"].string ?? "").font(.system(size: 13)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let observed = verdict["observed"].string {
                            Text(verbatim: observed).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HostedList.caption).lineLimit(1)
                        }
                    }
                    .frame(minHeight: 24)
                }
            }
        }
    }
}

/// A titled part of the step details: a 12 pt semibold grey title, then its content
struct FlowStepSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The end of the step's output; earlier lines stay folded until asked for
private struct FlowStepOutput: View {
    let lines: [String]
    let shown: Int
    @ViewState private var all = false

    var body: some View {
        let tail = FlowWorkspaceSummary.logTail(lines, shown: all ? lines.count : shown)
        FlowStepSection(title: "Output") {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if tail.hidden > 0 {
                        Button("Show \(tail.hidden) earlier lines") { all = true }.buttonStyle(HostedListTextButtonStyle())
                    }
                    ForEach(Array(tail.lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced))
                            .fixedSize().frame(height: 20).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // short output starts at the leading edge instead of the middle of the box
            .defaultScrollAnchor(.topLeading)
            // as tall as its lines, up to 260 pt: a scroll view would otherwise take all the height it is offered
            .frame(height: min(260, CGFloat(tail.lines.count) * 20 + 12 + (tail.hidden > 0 ? 24 : 0)))
            .flowCodeBox()
            .accessibilityLabel("Output")
        }
    }
}

/// A script exactly as the flow file has it
private struct FlowScriptBox: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(.system(size: 12, design: .monospaced)).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flowCodeBox()
    }
}

extension View {
    /// The box scripts and output sit in: a faint neutral surface with a hairline
    func flowCodeBox() -> some View {
        background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
