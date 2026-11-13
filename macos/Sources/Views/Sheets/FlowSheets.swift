import SwiftUI
import AppKit

/// One run: the step graph with its states, the steps grouped by how they ended, and the chosen step's result and
/// output. Verdicts are shown exactly as the engine made them. (Windows: FlowRunDialog.tsx)
struct FlowRunSheet: View {
    let flows: FlowStore
    let runId: String
    @Environment(\.dismiss) private var dismiss
    /// The step the person chose; until then the sheet follows the run (see FlowWorkspaceSummary.runFocus)
    @ViewState private var selected: String?
    /// The person's own choice for the passed group; nil follows the run
    @ViewState private var showPassed: Bool?
    @ViewState private var copied = false
    @ViewState private var cancelling = false
    @ViewState private var error: String?

    private var view: FlowRunView? { flows.view(runId) }
    private var record: FlowJSON? { flows.record(runId) }
    private var running: Bool { view.map { !$0.done } ?? false }
    private var nodes: [FlowRunView.Node] { view?.nodes ?? [] }
    private var shown: FlowRunView.Node? {
        nodes.first { $0.id == selected } ?? FlowWorkspaceSummary.runFocus(nodes).flatMap { id in nodes.first { $0.id == id } }
    }

    var body: some View {
        let steps = nodes.map(FlowWorkspaceSummary.step)
        VStack(spacing: 0) {
            header
            Divider()
            FlowSplitView(initialFraction: 0.5, minimumLeading: 380, minimumTrailing: 340) {
                overview(steps)
            } trailing: {
                if let shown {
                    FlowRunStepDetail(node: shown, steps: steps, record: record, repo: flows.repo)
                } else {
                    waiting
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 620, idealHeight: 780)
        .task { await flows.open(runId) }
    }

    /// The flow and how the run ended, then one line of context: the run, the engine's code and the step counts
    private var header: some View {
        let state = view.map(FlowRunHistory.presentationState) ?? record?["state"].string
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(verbatim: view?.flow.isEmpty == false ? view?.flow ?? "" : record?["flow"].string ?? "")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                StatusPill(flowState: state)
            }
            HStack(spacing: 8) {
                Text(verbatim: runId).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if let code = view?.code ?? record?["code"].string { Text(verbatim: code).font(.system(size: 11, design: .monospaced)) }
                if let counts = view?.counts { Text("\(counts.passed) passed · \(counts.failed) failed · \(counts.total) steps").monospacedDigit() }
            }
            .font(.system(size: 12)).foregroundStyle(HostedList.caption).lineLimit(1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Overview

    /// The graph fitted to its panel, then the steps grouped by how they ended
    private func overview(_ steps: [FlowWorkspaceSummary.Step]) -> some View {
        VStack(spacing: 0) {
            if !nodes.isEmpty {
                FlowGraphView(nodes: nodes.map(FlowGraphView.Node.init), selected: Binding(get: { shown?.id }, set: { selected = $0 }), initialFit: true)
                    .padding(12).frame(height: 232)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(FlowWorkspaceSummary.runGroups(nodes)) { group in stepGroup(group, steps: steps) }
                    if let extras = view?.steps, !extras.isEmpty { services(extras) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Steps")
        }
    }

    private func stepGroup(_ group: FlowWorkspaceSummary.RunGroup, steps: [FlowWorkspaceSummary.Step]) -> some View {
        let open = !group.folds || (showPassed ?? FlowWorkspaceSummary.passedOpenByDefault(nodes))
        let title = FlowFormat.stateTitle(group.state) + " \(group.nodes.count)"
        return VStack(alignment: .leading, spacing: 2) {
            if group.folds {
                Button { showPassed = !open } label: {
                    HStack(spacing: 6) {
                        DesignIconImage(icon: open ? .chevronDown : .chevronRight, size: 10)
                        Text(verbatim: title)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).modifier(FlowRunGroupTitle())
            } else {
                Text(verbatim: title).modifier(FlowRunGroupTitle())
            }
            if open {
                ForEach(group.nodes) { node in
                    FlowRunStepRow(node: node, skipCause: steps.first { $0.id == node.id }.flatMap { FlowWorkspaceSummary.skipCause($0, in: steps) },
                                   selected: shown?.id == node.id) { selected = node.id }
                }
            }
        }
    }

    /// Things that happen outside steps: services starting and stopping, and each change undone by a rollback
    private func services(_ steps: [FlowRunView.Step]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Services and rollback").modifier(FlowRunGroupTitle())
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    SymbolIcon(stepIcon(step.state)).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    Text(verbatim: step.node.map { "\($0): \(step.text)" } ?? step.text).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(verbatim: step.state).font(.system(size: 11, design: .monospaced)).foregroundStyle(HostedList.caption)
                }
                .padding(.horizontal, 8).frame(minHeight: 24)
            }
        }
    }

    private func stepIcon(_ s: String) -> String {
        switch s {
        case "READY", "UNDONE", "DONE": return "checkmark"
        case "FAILED": return "xmark"
        case "STARTING", "RUNNING": return "hourglass"
        default: return "circle"
        }
    }

    /// Before any step can be shown: what the rollback did, if there was one, and what the sheet is waiting for
    private var waiting: some View {
        VStack(spacing: 8) {
            rollbackNote
            Text(nodes.isEmpty ? String(localized: "Waiting for the engine…") : String(localized: "Choose a step to see its output."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var rollbackNote: some View {
        if let rb = record?["rollback"], rb != .null {
            VStack(alignment: .leading, spacing: 4) {
                if rb["state"].string == "ROLLBACK_FAILED" {
                    Label("Rollback failed. The environment is on hold until a person checks it and releases it (gitch flow hold release).", symbol: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                } else if rb["state"].string == "ROLLED_BACK" {
                    Label("The changes were undone in reverse order.", symbol: "arrow.uturn.backward.circle")
                        .foregroundStyle(.orange)
                }
                if let why = rb["why"].string, !why.isEmpty { Text(why).font(.caption).foregroundStyle(.secondary) }
                let kept = rb["kept"].array.compactMap(\.string)
                if !kept.isEmpty { Text("Kept as is: \(kept.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(10)
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    // MARK: Footer

    /// Copy summary on the left, Cancel run only while the run is going, and Done as the one filled button
    private var footer: some View {
        HStack(spacing: 10) {
            Button(copied ? String(localized: "Copied") : String(localized: "Copy summary")) {
                Task {
                    if let md = try? await FlowEngine.markdown(runId, in: flows.repo) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(md, forType: .string)
                        copied = true
                    }
                }
            }
            .disabled(running)
            .help("Copy a Markdown summary (failures with file and line) to paste into a PR or an AI chat")
            if running {
                Button(role: .destructive) {
                    cancelling = true
                    Task {
                        do { try await flows.cancel(runId) } catch { cancelling = false; self.error = error.localizedDescription }
                    }
                } label: { Label("Cancel run", symbol: "stop.fill") }
                .disabled(cancelling)
                .help("Stops every step and its child processes, then undoes what was changed")
                ProgressView().controlSize(.small)
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

/// The title of a group in a run's step list: "Failed 1", "Passed 4"
private struct FlowRunGroupTitle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption)
            .padding(.horizontal, 8).frame(minHeight: 24)
    }
}

/// One step of a run: its state, its id, the step a skipped one was waiting for, then its tests and how long it took
private struct FlowRunStepRow: View {
    let node: FlowRunView.Node
    /// The step this one needed that did not pass, when that is why it was skipped
    let skipCause: String?
    let selected: Bool
    let choose: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                FlowStateIcon(state: node.state.rawValue, size: 14, spins: true)
                Text(verbatim: node.branchOf == nil ? node.id : "↳ " + node.id)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if let skipCause {
                    HStack(spacing: 4) {
                        Text("Needs").font(.system(size: 12))
                        Text(verbatim: skipCause).font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(HostedList.secondary(selected: selected)).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                Group {
                    if let executed = node.testsExecuted { Text(verbatim: "\(node.testsPassed ?? 0)/\(executed)") }
                    if let took = node.durationMs { Text(verbatim: FlowFormat.duration(took)) }
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(HostedList.secondary(selected: selected)).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.16) : hovered ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chosen step of a run: the same header, outcome and verdicts as the workspace's step details, then the failed
/// tests with their files and the output, which keeps following a live run
private struct FlowRunStepDetail: View {
    let node: FlowRunView.Node
    let steps: [FlowWorkspaceSummary.Step]
    let record: FlowJSON?
    let repo: URL

    var body: some View {
        let recorded = FlowStepRecord(record, step: node.id)
        VStack(spacing: 0) {
            FlowStepHeader(id: node.id, block: node.block) {
                if let log = node.log, let dir = record?["runDir"].string {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: dir).appendingPathComponent(log)) } label: { SymbolIcon("doc.text.magnifyingglass") }
                        .buttonStyle(PullRequestIconButtonStyle())
                        .help("Open the full log").accessibilityLabel("Open the full log")
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                FlowStepOutcome(step: FlowWorkspaceSummary.step(node), steps: steps, reason: recorded.reason ?? node.reason, action: recorded.action)
                if let detail = recorded.node["failure"]["detail"].string, !detail.isEmpty {
                    Text(verbatim: detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(HostedList.caption)
                        .textSelection(.enabled).lineLimit(8)
                }
                if !recorded.failedTests.isEmpty { failedTests(recorded.failedTests) }
                FlowStepVerdicts(verdicts: recorded.verdicts)
                FlowStepSection(title: "Output") { output(node.tail).id(node.id) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(StudioStyle.surface)
    }

    private func failedTests(_ failures: [FlowJSON]) -> some View {
        FlowStepSection(title: "Failed tests") {
            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: failure["name"].string ?? "").font(.system(size: 13)).lineLimit(2)
                    if let file = failure["file"].string {
                        Button(file + (failure["line"].int.map { ":\($0)" } ?? "")) { openFile(file) }
                            .buttonStyle(.link).font(.system(size: 11, design: .monospaced))
                    }
                    if let message = failure["message"].string {
                        Text(verbatim: message).font(.system(size: 11)).foregroundStyle(HostedList.caption).lineLimit(3)
                    }
                }
            }
        }
    }

    /// The step's output so far; it stays at the end while lines keep arriving
    private func output(_ lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced))
                            .fixedSize().textSelection(.enabled).id(index)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // short output starts at the leading edge instead of the middle of the box
            .defaultScrollAnchor(.topLeading)
            .frame(minHeight: 120)
            .flowCodeBox()
            .onAppear { if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
            .onChange(of: lines.count) { _, count in if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) } }
        }
    }

    /// Opens a failure location: the file in the repository, in the default editor (the file only, since editors take line numbers differently)
    private func openFile(_ relative: String) {
        let url = repo.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }
}

/// Trusting a flow file: it is code, so it runs unattended only after a person has seen what will run and approved it.
struct FlowTrustSheet: View {
    let plan: FlowPlan
    let actionTitle: String
    let onApprove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SharedSheet(title: String(localized: "Review this flow"), context: plan.flow, width: 640,
                    primary: SheetPrimary(title: actionTitle) { dismiss(); onApprove() }, cancel: { dismiss() }) {
            review.padding(.horizontal, 20).padding(.vertical, 16)
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A flow file is code. Approve it only if you would run these commands yourself — changing the file asks again.")
                .font(.callout).foregroundStyle(.secondary)
            if let changed = plan.trust.changed, !changed.isEmpty {
                LabeledContent("New or changed") { Text(changed.joined(separator: ", ")).font(.callout.monospaced()) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.nodes.filter { $0.decision == "run" }) { n in nodeBlock(n) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)
            if !plan.outward.isEmpty {
                Label("Acts outside this computer: \(plan.outward.joined(separator: ", "))", symbol: "arrow.up.forward.app")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !plan.services.isEmpty {
                Label("Starts services: \(plan.services.joined(separator: ", "))", symbol: "shippingbox")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(plan.warnings, id: \.self) { w in Label(w, symbol: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func nodeBlock(_ n: FlowPlan.Node) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(n.id).font(.callout.weight(.semibold))
                Text(n.block).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let e = n.executor, e != "local" { Text(e).font(.caption.monospaced()).foregroundStyle(.blue) }
                if n.outward == true { tag(String(localized: "outward"), .orange) }
                if n.destructive == true { tag(String(localized: "hard to undo"), .red) }
                Spacer()
                if let src = n.src { Text(src).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
            if let run = n.run {
                Text(run)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }
            if let undo = n.undo {
                Text("Undo: \(undo)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().stroke(color.opacity(0.6)))
    }
}

/// Creating a flow file: the engine reads only the repository's files to find tests and tools and proposes one (nothing runs).
struct FlowSetupSheet: View {
    let flows: FlowStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var proposal: FlowInitProposal?
    @ViewState private var error: String?
    @ViewState private var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up flows").font(.title3.weight(.semibold))
            Text("Gitrochi read this repository's files to find its tests and tools. Nothing runs, and nothing is written until you create the file.")
                .font(.callout).foregroundStyle(.secondary)
            if let p = proposal {
                if !p.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(p.findings, id: \.self) { f in
                            HStack(spacing: 6) {
                                SymbolIcon("checkmark.circle").foregroundStyle(.green)
                                Text(f.kind).font(.callout.weight(.medium))
                                Text(f.evidence).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let n = f.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Text("Proposed .gitch/flow.yml").font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(p.yaml).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 300)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                if p.exists {
                    Label("A flow file already exists, so nothing will be written. Merge the proposal by hand.", symbol: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            } else if let e = error {
                Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                if writing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create flow file") { write() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposal == nil || proposal?.exists == true || writing)
            }
        }
        .padding(20)
        .frame(width: 660)
        .task {
            do { proposal = try await FlowEngine.proposeInit(in: flows.repo) } catch { self.error = error.localizedDescription }
        }
    }

    private func write() {
        writing = true
        Task {
            defer { writing = false }
            do {
                try await FlowEngine.writeInit(in: flows.repo)
                await flows.refresh()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
