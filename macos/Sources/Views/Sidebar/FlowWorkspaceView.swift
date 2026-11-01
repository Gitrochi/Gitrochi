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
    var requestedFlow: String? = nil
    var onCreate: () -> Void = {}
    @ViewState private var selectedFlow: String?
    @ViewState private var selectedNode: String?
    @ViewState private var page = 0
    @ViewState private var plan: FlowPlan?
    @ViewState private var planError: String?
    @ViewState private var revision = 0
    @ViewState private var search = ""
    @ViewState private var loadingPlan = false
    @ViewState private var createdFlowNotice: String?

    private var flow: FlowList.Flow? { list.flows.first { $0.name == selectedFlow } ?? list.flows.first }
    private var request: String { (flow?.name ?? "") + ":" + String(affected) + ":" + String(revision) }
    private var matchingFlows: [FlowList.Flow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return list.flows.filter { query.isEmpty || ($0.name + " " + ($0.description ?? "")).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 780 {
                VStack(spacing: 0) {
                    compactSelector
                    Divider()
                    workspace
                }
            } else {
                FlowSplitView(initialFraction: 0.22, minimumLeading: 190, minimumTrailing: 560, maximumLeading: 250) {
                    selector
                } trailing: { workspace }
            }
        }
        .task(id: request) { await loadPlan() }
        .onChange(of: flows.loading) { _, loading in if !loading { revision += 1 } }
        .onChange(of: selectedNode) { _, _ in onSelection?(flow?.name, selectedNode) }
        .onChange(of: selectedFlow) { _, _ in onSelection?(flow?.name, selectedNode) }
        .onChange(of: list.flows.map(\.name)) { _, names in
            if let selectedFlow, !names.contains(selectedFlow) { self.selectedFlow = names.first }
        }
        .onChange(of: requestedFlow, initial: true) { _, name in
            guard let name else { return }
            search = ""
            chooseFlow(name)
            createdFlowNotice = name
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if page == 2 {
                FlowConnectedCIView(repo: flows.repo)
            } else if page == 1 {
                FlowHistoryView(runs: flows.runs, onOpen: onOpenRun)
            } else if let plan {
                if createdFlowNotice != nil { creationNotice }
                FlowSplitView(initialFraction: 0.69, minimumLeading: 440, minimumTrailing: 240) {
                    FlowGraphView(nodes: graphNodes(plan), selected: $selectedNode, initialFit: true)
                        .id(plan.flow)
                } trailing: { inspector(plan) }
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
                    Button(action: onCreate) { Label("Create flow", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).padding(.bottom, 24)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Flows", systemImage: "arrow.triangle.branch").font(.callout.weight(.semibold))
                Spacer()
                Text("\(list.flows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 4)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find flows", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Find flows")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12)).padding(9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(matchingFlows) { item in flowChoice(item) }
                    if matchingFlows.isEmpty, !search.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.tertiary)
                            Text("No matching flows").font(.caption).foregroundStyle(.secondary)
                            Button("Clear search") { search = "" }.buttonStyle(.borderless).font(.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                }
            }
            Button(action: onCreate) { Label("Create flow", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if !list.trusted, !list.flows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Review required", systemImage: "hand.raised")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    Text("This flow file is new or changed. Review the commands before running it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func flowChoice(_ item: FlowList.Flow) -> some View {
        let isSelected = flow?.name == item.name
        return Button { chooseFlow(item.name) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 25, height: 25).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
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
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).help(item.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var compactSelector: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Picker("Flow", selection: Binding(get: { flow?.name ?? "" }, set: { name in
                chooseFlow(name)
            })) {
                ForEach(list.flows) { Text($0.name).tag($0.name) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            Text("\(list.flows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(action: onCreate) { Label("Create flow", systemImage: "plus") }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func chooseFlow(_ name: String) {
        createdFlowNotice = nil
        if flow?.name != name {
            selectedFlow = name
            selectedNode = nil
        }
        page = 0
    }

    private var creationNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            Text("Flow created. Review its commands, then run it.").font(.caption)
            Spacer(minLength: 0)
            Button { createdFlowNotice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close").accessibilityLabel("Close")
        }
        .padding(12).background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    heading
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    heading
                    actions
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    workspacePicker.frame(width: 270)
                    Spacer(minLength: 0)
                    metadata
                }
                VStack(alignment: .leading, spacing: 10) {
                    workspacePicker.frame(maxWidth: .infinity)
                    metadata
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var heading: some View {
        HStack(spacing: 11) {
            Image(systemName: page == 2 ? "network" : page == 1 ? "clock.arrow.circlepath" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.06)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(page == 2 ? String(localized: "Connected CI") : page == 1 ? String(localized: "Run history") : flow?.name ?? String(localized: "Flows"))
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                if page == 2 {
                    Text("Browse your repository's CI runs and saved connections.").font(.caption).foregroundStyle(.secondary)
                } else if page == 1 {
                    Text("Search recorded flow runs and inspect their results.").font(.caption).foregroundStyle(.secondary)
                } else if let description = flow?.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if page == 0, let flow {
            HStack(spacing: 8) {
                Button(action: onEdit) { Label("Edit flow file…", systemImage: "square.and.pencil") }
                    .buttonStyle(.bordered).help("Edit flow file…")
                Button { if let plan { onReview(plan) } } label: {
                    Image(systemName: "checkmark.shield").frame(width: 23, height: 23)
                }
                .buttonStyle(.borderless).disabled(plan == nil || loadingPlan)
                .help("Review commands…").accessibilityLabel("Review commands…")
                Button { onRun(flow.name) } label: {
                    HStack(spacing: 6) {
                        if starting == flow.name { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "play.fill") }
                        Text("Run flow")
                    }.padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent).disabled(starting != nil || plan == nil || loadingPlan)
                .accessibilityLabel("Run flow")
            }.controlSize(.small).fixedSize()
        }
    }

    private var workspacePicker: some View {
        Picker("View", selection: $page) {
            Text("Flow").tag(0)
            Text("History").tag(1)
            Text("Connected CI").tag(2)
        }.labelsHidden().pickerStyle(.segmented)
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            if page == 0 {
                if let plan {
                    Label(plan.env, systemImage: "square.stack.3d.up")
                        .help("Environment: \(plan.env)").modifier(FlowMetadataStyle())
                }
                if let flow { Text("\(flow.nodes) steps").modifier(FlowMetadataStyle()) }
                if let name = flow?.name, let latest = latestRun(name) {
                    Button { onOpenRun(latest.runId) } label: {
                        HStack(spacing: 5) {
                            FlowStatusBadge(state: FlowRunHistory.presentationState(latest), compact: true)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).help("Show last run").accessibilityLabel("Show last run")
                        .accessibilityValue(FlowFormat.stateTitle(FlowRunHistory.presentationState(latest)))
                }
                if !list.trusted {
                    Label("Review required", systemImage: "hand.raised").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
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
        guard let flow else { plan = nil; loadingPlan = false; return }
        loadingPlan = true
        planError = nil
        if plan?.flow != flow.name { plan = nil }
        defer { if !Task.isCancelled { loadingPlan = false } }
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
