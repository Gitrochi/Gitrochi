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
    var onSelection: ((String?, String?) -> Void)? = nil
    @ViewState private var selectedFlow: String?
    @ViewState private var selectedNode: String?
    @ViewState private var page = 0
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
                if page == 2 {
                    FlowConnectedCIView(repo: flows.repo)
                } else if page == 1 {
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
                    VStack(spacing: 12) {
                        ContentUnavailableView("No flows", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Add a script to create your first flow."))
                        Button("Set up flows…", action: onEdit).padding(.bottom, 24)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: request) { await loadPlan() }
        .onChange(of: flows.loading) { _, loading in if !loading { revision += 1 } }
        .onChange(of: selectedNode) { _, _ in onSelection?(flow?.name, selectedNode) }
        .onChange(of: selectedFlow) { _, _ in onSelection?(flow?.name, selectedNode) }
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
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                                    .frame(width: 25, height: 25).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                                Text(item.name).font(.callout.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            if let description = item.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            HStack {
                                Text("\(item.nodes) steps").font(.caption2).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                if let state = latestRun(item.name).map(FlowRunHistory.presentationState) ?? item.last?.state {
                                    FlowStatusBadge(state: state, compact: true)
                                }
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(flow?.name == item.name ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(flow?.name == item.name ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(flow?.name == item.name ? [.isSelected] : [])
                }
                if !list.trusted {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Review required", systemImage: "hand.raised")
                            .font(.caption.weight(.medium)).foregroundStyle(.orange)
                        Text("This flow file is new or changed. Review the commands before running it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.top, 6)
                }
                Button(action: onEdit) { Label("Edit flow file…", systemImage: "square.and.pencil") }
                    .buttonStyle(.bordered).controlSize(.small).font(.caption).padding(.top, 6)
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(flow?.name ?? String(localized: "Flows")).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if let description = flow?.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let flow {
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            Button(action: onEdit) { Image(systemName: "square.and.pencil").frame(width: 24, height: 24) }
                                .help("Edit flow file…")
                            if let latest = latestRun(flow.name) {
                                Button { onOpenRun(latest.runId) } label: {
                                    Image(systemName: latest.running == true ? "waveform.path" : "clock.arrow.circlepath").frame(width: 24, height: 24)
                                }.help("Show last run")
                            }
                            Button { if let plan { onReview(plan) } } label: {
                                Image(systemName: "checkmark.shield").frame(width: 24, height: 24)
                            }.disabled(plan == nil).help("Review commands…")
                        }
                        .buttonStyle(.borderless)
                        .padding(3)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07)))
                        Button { onRun(flow.name) } label: {
                            if starting == flow.name { ProgressView().controlSize(.mini).frame(width: 48) }
                            else { Label("Run", systemImage: "play.fill").padding(.horizontal, 5) }
                        }
                        .buttonStyle(.borderedProminent).disabled(starting != nil || plan == nil)
                    }.controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Picker("View", selection: $page) {
                    Text("Flow").tag(0)
                    Text("History").tag(1)
                    Text("Connected CI").tag(2)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 270)
                Spacer(minLength: 8)
                if let plan {
                    Label(plan.env, systemImage: "square.stack.3d.up")
                        .help("Environment: \(plan.env)")
                        .modifier(FlowMetadataStyle())
                }
                if let flow { Text("\(flow.nodes) steps").modifier(FlowMetadataStyle()) }
                if !list.trusted {
                    Label("Review required", systemImage: "hand.raised").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func latestRun(_ name: String) -> FlowRunRow? { flows.runs.first { $0.flow == name } }

    private var activeRun: FlowRunRow? {
        guard let name = flow?.name else { return nil }
        return flows.runs.first { $0.flow == name && $0.running == true }
    }

    @ViewBuilder
    private func inspector(_ plan: FlowPlan) -> some View {
        if let activeRun, let view = flows.view(activeRun.runId), !view.done, !view.nodes.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path").font(.system(size: 17)).foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live run").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Text(selectedNode ?? plan.flow).font(.headline).lineLimit(2)
                    }
                }
                if let node = view.nodes.first(where: { $0.id == selectedNode }) {
                    HStack {
                        FlowStatusBadge(state: node.state.rawValue)
                        Spacer()
                        if let duration = node.durationMs { Text(FlowFormat.duration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
                Divider()
                Text("This graph follows the running flow. Open the run for step output.").font(.caption).foregroundStyle(.secondary)
                    .padding(12).background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                Button { onOpenRun(activeRun.runId) } label: {
                    Label("Show run details", systemImage: "text.alignleft").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.small)
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

private struct FlowMetadataStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.06)))
    }
}
