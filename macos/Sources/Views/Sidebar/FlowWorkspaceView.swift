import SwiftUI

/// Flow selection, dependency preview, commands and a searchable run history in one workspace.
struct FlowWorkspaceView: View {
    let flows: FlowStore
    let list: FlowList
    let affected: Bool
    let starting: String?
    let onRun: (String) -> Void
    let onReview: (FlowPlan) -> Void
    let onEdit: () -> Void
    let onOpenRun: (String) -> Void
    @ViewState private var selectedFlow: String?
    @ViewState private var selectedNode: String?
    @ViewState private var history = false
    @ViewState private var plan: FlowPlan?
    @ViewState private var planError: String?
    @ViewState private var revision = 0

    private var flow: FlowList.Flow? { list.flows.first { $0.name == selectedFlow } ?? list.flows.first }
    private var request: String { (flow?.name ?? "") + ":" + String(affected) + ":" + String(revision) }

    var body: some View {
        HSplitView {
            selector.frame(minWidth: 170, idealWidth: 205, maxWidth: 230)
            VStack(spacing: 0) {
                toolbar
                Divider()
                if history {
                    FlowHistoryView(runs: flows.runs, onOpen: onOpenRun)
                } else if let plan {
                    HSplitView {
                        FlowGraphView(nodes: graphNodes(plan), selected: $selectedNode).frame(minWidth: 280)
                        inspector(plan)
                            .frame(minWidth: 210, idealWidth: 250, maxWidth: 280)
                    }
                    if !plan.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(plan.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let planError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                        Text(planError).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Edit flow file…", action: onEdit)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if flow == nil {
                    ContentUnavailableView("No flows", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Add a script to create your first flow."))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: request) { await loadPlan() }
        .onChange(of: flows.loading) { _, loading in if !loading { revision += 1 } }
        .onChange(of: list.flows.map(\.name)) { _, names in
            if let selectedFlow, !names.contains(selectedFlow) { self.selectedFlow = names.first }
        }
    }

    private var selector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Flows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(list.flows.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }.padding(.horizontal, 5)
                ForEach(list.flows) { item in
                    Button {
                        selectedFlow = item.name
                        selectedNode = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                FlowStateIcon(state: latestRun(item.name).map(FlowRunHistory.presentationState) ?? item.last?.state, size: 14)
                                Text(item.name).font(.callout.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            if let description = item.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Text("\(item.nodes) steps").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(flow?.name == item.name ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(flow?.name == item.name ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(flow?.name == item.name ? [.isSelected] : [])
                }
                if !list.trusted {
                    Label("Review required", systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.orange).padding(.top, 8)
                    Text("This flow file is new or changed. Review the commands before running it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(action: onEdit) { Label("Edit flow file…", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderless).font(.caption).padding(.top, 8)
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flow?.name ?? String(localized: "Flows")).font(.headline).lineLimit(1)
                if let plan { Text("Environment: \(plan.env)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Picker("View", selection: $history) {
                Text("Flow").tag(false)
                Text("History").tag(true)
            }
            .pickerStyle(.segmented).frame(width: 150)
            if let flow {
                if let latest = latestRun(flow.name) {
                    Button { onOpenRun(latest.runId) } label: {
                        Image(systemName: latest.running == true ? "waveform.path" : "clock.arrow.circlepath")
                    }
                    .help("Show last run")
                }
                Button {
                    if let plan { onReview(plan) }
                } label: { Image(systemName: "checkmark.shield") }
                .disabled(plan == nil).help("Review commands…")
                Button { onRun(flow.name) } label: {
                    if starting == flow.name { ProgressView().controlSize(.mini) }
                    else { Label("Run", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent).disabled(starting != nil || plan == nil)
            }
        }
        .controlSize(.small).padding(12)
    }

    private func latestRun(_ name: String) -> FlowRunRow? { flows.runs.first { $0.flow == name } }

    private var activeRun: FlowRunRow? {
        guard let name = flow?.name else { return nil }
        return flows.runs.first { $0.flow == name && $0.running == true }
    }

    @ViewBuilder
    private func inspector(_ plan: FlowPlan) -> some View {
        if let activeRun, let view = flows.view(activeRun.runId), !view.done, !view.nodes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Live run", systemImage: "waveform.path").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(selectedNode ?? plan.flow).font(.headline)
                if let node = view.nodes.first(where: { $0.id == selectedNode }) {
                    Label(FlowFormat.stateTitle(node.state.rawValue), systemImage: FlowStateIcon.look(node.state.rawValue).0)
                        .foregroundStyle(FlowStateIcon.look(node.state.rawValue).1)
                    if let duration = node.durationMs { Text(FlowFormat.duration(duration)).font(.caption.monospacedDigit()) }
                }
                Text("This graph follows the running flow. Open the run for step output.").font(.caption).foregroundStyle(.secondary)
                Button("Show run details") { onOpenRun(activeRun.runId) }.controlSize(.small)
                Spacer()
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        } else {
            FlowCommandInspector(node: plan.nodes.first { $0.id == selectedNode }, onEdit: onEdit)
        }
    }

    private func graphNodes(_ plan: FlowPlan) -> [FlowGraphView.Node] {
        if let id = activeRun?.runId, let view = flows.view(id), !view.done, !view.nodes.isEmpty {
            return view.nodes.map(FlowGraphView.Node.init)
        }
        return plan.nodes.map(FlowGraphView.Node.init)
    }

    private func loadPlan() async {
        guard let flow else { plan = nil; return }
        if plan?.flow != flow.name { plan = nil }
        do {
            let value = try await FlowEngine.plan(flow.name, in: flows.repo, affected: affected)
            guard !Task.isCancelled else { return }
            plan = value
            planError = nil
            let rendered = graphNodes(value)
            if !rendered.contains(where: { $0.id == selectedNode }) { selectedNode = rendered.first?.id }
        } catch {
            guard !Task.isCancelled else { return }
            plan = nil
            planError = error.localizedDescription
        }
    }
}

private struct FlowCommandInspector: View {
    let node: FlowPlan.Node?
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node {
                    Label("Step details", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(node.id).font(.headline).textSelection(.enabled)
                    if let title = node.title, title != node.id { Text(title).font(.callout).foregroundStyle(.secondary) }
                    Text(node.block).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !node.needs.isEmpty { field("Dependencies", node.needs.joined(separator: ", ")) }
                    field("Executor", node.executor ?? "local")
                    if let source = node.src { field("Source", source) }
                    if let command = node.run { field("Script", command, code: true) }
                    if let undo = node.undo { field("Undo", undo, code: true) }
                    if let reason = node.reason?.message { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if node.outward == true { Label("outward", systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(.orange) }
                    if node.destructive == true { Label("hard to undo", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Button("Edit scripts…", action: onEdit).controlSize(.small)
                } else {
                    Text("Choose a step to inspect its script.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func field(_ title: LocalizedStringKey, _ text: String, code: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(code ? 10 : 0)
                .background(code ? Color(nsColor: .textBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// Saved runs remain browsable independently of the command inspector.
struct FlowHistoryView: View {
    let runs: [FlowRunRow]
    let onOpen: (String) -> Void
    @ViewState private var search = ""
    @ViewState private var failuresOnly = false
    @ViewState private var selectedFlow = ""

    private var filtered: [FlowRunRow] {
        runs.filter {
            (selectedFlow.isEmpty || $0.flow == selectedFlow) &&
            (!failuresOnly || ["FAILED", "REJECTED", "INDETERMINATE", "ROLLBACK_FAILED", "ROLLED_BACK"].contains($0.state)) &&
            (search.isEmpty || ($0.flow + $0.runId + $0.state).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search runs", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 240)
                Picker("Flow", selection: $selectedFlow) {
                    Text("All flows").tag("")
                    ForEach(Array(Set(runs.map(\.flow))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 130)
                Toggle("Failures only", isOn: $failuresOnly).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Text("\(filtered.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(14)
            if filtered.isEmpty {
                ContentUnavailableView("No runs yet", systemImage: "clock.arrow.circlepath", description: Text("Run a flow to see its steps, output and results here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { run in
                            Button { onOpen(run.runId) } label: {
                                HStack(spacing: 12) {
                                    FlowStateIcon(state: FlowRunHistory.presentationState(run), size: 19)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(run.flow).font(.callout.weight(.semibold))
                                        Text(run.runId).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(FlowFormat.stateTitle(FlowRunHistory.presentationState(run))).font(.caption).foregroundStyle(.secondary)
                                    if let time = run.startedAt, let date = ISO8601DateFormatter.flow.date(from: time) {
                                        Text(Fmt.short(date)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let duration = run.durationMs { Text(FlowFormat.duration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing) }
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain).help("Show run details")
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
