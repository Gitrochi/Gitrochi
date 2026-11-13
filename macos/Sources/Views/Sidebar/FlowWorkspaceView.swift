import SwiftUI

/// The Flows workspace, left to right: the list of flows, the selected flow (its name and actions, then Flow /
/// History / Connected CI), and the selected step. The Flow tab shows one banner about the latest run and the steps
/// as a graph in which a connector means "needs". This view only composes: what the banner says, each step's state
/// and the step to open on are FlowWorkspaceSummary's answers. (Windows: FlowWorkspace.tsx)
struct FlowWorkspaceView: View {
    let flows: FlowStore
    let list: FlowList
    /// Run only the steps the working changes affect
    let affected: Bool
    /// The flow whose run is being prepared, if any
    let starting: String?
    /// A flow to select from outside, such as the one just created
    var requestedFlow: String? = nil
    let onCreate: () -> Void
    let onRun: (String) -> Void
    let onStop: (String) -> Void
    let onOpenRun: (String) -> Void
    /// Opens the editor on a flow and, when one is given, on that step
    let onEdit: (_ flow: String?, _ step: String?) -> Void
    let onReview: (String) -> Void
    /// The "More flow actions" menu for the selected flow
    let moreActions: (FlowList.Flow) -> FlowMoreActionsMenu

    @ViewState private var selectedFlow: String?
    @ViewState private var selectedStep: String?
    /// The flow whose step the person chose themselves, so the workspace stops moving the selection for it
    @ViewState private var pickedBy: String?
    @ViewState private var search = ""
    @ViewState private var tab = FlowWorkspaceTab.graph
    @ViewState private var justCreated: String?
    @ViewState private var plan: FlowPlan?
    @ViewState private var planError: String?
    @ViewState private var loadingPlan = false
    /// Bumped after every refresh of the store, so the plan is read again when the flow file may have changed
    @ViewState private var revision = 0

    private var flow: FlowList.Flow? { list.flows.first { $0.name == selectedFlow } ?? list.flows.first }
    /// The latest run of the selected flow, whose result the banner, the graph and the step details show
    private var latest: FlowRunRow? { flow.flatMap { FlowWorkspaceSummary.latestRun(of: $0.name, in: flows.runs) } }
    private var banner: FlowWorkspaceSummary.Banner {
        FlowWorkspaceSummary.banner(trusted: list.trusted, latest: latest, view: latest.flatMap { flows.view($0.runId) })
    }
    private var results: FlowRunView? {
        FlowWorkspaceSummary.resultsView(banner, view: latest.flatMap { flows.view($0.runId) })
    }
    private var planRequest: String { (flow?.name ?? "") + ":" + String(affected) + ":" + String(revision) }

    var body: some View {
        GeometryReader { geometry in
            let columns = FlowWorkspaceSummary.Columns(width: geometry.size.width)
            if let flow {
                HStack(spacing: 0) {
                    if let width = columns.library {
                        FlowLibraryView(flows: list.flows, runs: flows.runs, selected: flow.name, search: $search,
                                        onChoose: chooseFlow, onCreate: onCreate)
                            .frame(width: width)
                        Rectangle().fill(StudioStyle.border).frame(width: 1)
                    }
                    VStack(spacing: 0) {
                        if columns.library == nil { compactSelector(flow) }
                        header(flow, columns: columns)
                        switch tab {
                        case .connectedCI: FlowConnectedCIView(repo: flows.repo)
                        case .history: FlowHistoryView(runs: flows.runs.filter { $0.flow == flow.name }, onOpen: onOpenRun).id(flow.name)
                        case .graph: planTab(flow, columns: columns)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .background(StudioStyle.surface)
        .task(id: planRequest) { await loadPlan() }
        // the run's steps are read once, so the graph can show how each one did
        .task(id: latest?.runId) {
            if let id = latest?.runId, flows.view(id) == nil || flows.record(id) == nil { await flows.open(id) }
        }
        .onChange(of: flows.loading) { _, loading in if !loading { revision += 1 } }
        .onChange(of: FlowWorkspaceSummary.attentionStep(results)) { _, _ in followAttention() }
        .onChange(of: list.flows.map(\.name)) { _, names in
            if let selectedFlow, !names.contains(selectedFlow) { self.selectedFlow = names.first }
        }
        .onChange(of: requestedFlow, initial: true) { _, name in
            guard let name else { return }
            search = ""
            chooseFlow(name)
            justCreated = name
        }
    }

    // MARK: Parts

    private func header(_ flow: FlowList.Flow, columns: FlowWorkspaceSummary.Columns) -> some View {
        FlowHeaderView(flow: flow, running: latest?.running == true ? latest : nil, starting: starting == flow.name,
                       canRun: starting == nil && plan != nil && !loadingPlan && planError == nil,
                       inset: columns.inset, compact: columns.library == nil, tab: $tab,
                       onEdit: { onEdit(flow.name, selectedStep) }, onRun: { onRun(flow.name) }, onStop: onStop,
                       more: moreActions(flow))
    }

    /// The Flow tab: the banner and the graph, with the selected step beside them (below them in a narrow window)
    private func planTab(_ flow: FlowList.Flow, columns: FlowWorkspaceSummary.Columns) -> some View {
        let steps = plan.map { FlowWorkspaceSummary.steps($0.nodes, view: results) } ?? []
        let step = steps.first { $0.id == selectedStep }
        let run = results?.nodes.first { $0.id == selectedStep }
        let runId = latest?.runId
        let details = FlowStepDetailsView(step: step, steps: steps, run: run,
                                          record: results == nil ? nil : runId.flatMap { flows.record($0) },
                                          onEdit: { onEdit(flow.name, step?.id) },
                                          onOpenRun: run == nil ? nil : runId.map { id in { onOpenRun(id) } })
        return GeometryReader { geometry in
            if plan == nil {
                planMain(flow, steps: steps, inset: columns.inset)
            } else if columns.detailsBelow {
                VStack(spacing: 0) {
                    planMain(flow, steps: steps, inset: columns.inset).frame(height: max(240, geometry.size.height * 0.56))
                    Rectangle().fill(StudioStyle.border).frame(height: 1)
                    details
                }
            } else {
                HStack(spacing: 0) {
                    planMain(flow, steps: steps, inset: columns.inset)
                    Rectangle().fill(StudioStyle.border).frame(width: 1)
                    details.frame(width: columns.details)
                }
            }
        }
    }

    private func planMain(_ flow: FlowList.Flow, steps: [FlowWorkspaceSummary.Step], inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let planError {
                NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: String(localized: "Couldn't read this flow"), caption: planError,
                            actions: [NoticeAction(title: String(localized: "Edit flow file…")) { onEdit(flow.name, selectedStep) }])
            } else {
                FlowRunBanner(banner: banner, created: justCreated == flow.name, progress: FlowWorkspaceSummary.progress(results),
                              onOpenRun: onOpenRun, onReview: { onReview(flow.name) })
            }
            if let plan {
                FlowGraphView(nodes: steps.map(FlowGraphView.Node.init), selected: pickedStep, initialFit: true).id(plan.flow)
                if !plan.warnings.isEmpty {
                    Text(verbatim: plan.warnings.joined(separator: "\n")).font(.system(size: 12))
                        .foregroundStyle(StudioStyle.Tone.waiting.text).textSelection(.enabled)
                }
            } else if planError == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(EdgeInsets(top: 16, leading: inset, bottom: inset, trailing: inset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The list column's stand-in when the window is too narrow for it
    private func compactSelector(_ flow: FlowList.Flow) -> some View {
        HStack(spacing: 8) {
            Picker("Flow", selection: Binding(get: { flow.name }, set: chooseFlow)) {
                ForEach(list.flows) { Text($0.name).tag($0.name) }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCreate) { Label("New flow…", symbol: "plus") }.buttonStyle(HostedListButtonStyle())
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    // MARK: Selection

    /// The graph's selection: a step chosen there is the person's own choice, which the workspace then leaves alone
    private var pickedStep: Binding<String?> {
        Binding(get: { selectedStep }, set: { id in
            pickedBy = flow?.name
            selectedStep = id
        })
    }

    private func chooseFlow(_ name: String) {
        if flow?.name != name {
            selectedFlow = name
            selectedStep = nil
            pickedBy = nil
        }
        justCreated = nil
        tab = .graph
    }

    /// Opens on the step that needs attention (failed, else running) until the person picks one themselves
    private func followAttention() {
        guard let plan, pickedBy != flow?.name, let attention = FlowWorkspaceSummary.attentionStep(results),
              plan.nodes.contains(where: { $0.id == attention }) else { return }
        selectedStep = attention
    }

    /// Reads the plan of the selected flow; it is read again when the flow, its file or the affected-only switch changes
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
            // Keep the chosen step across a refresh; otherwise start on the first one so the details are never empty.
            if !value.nodes.contains(where: { $0.id == selectedStep }) { selectedStep = value.nodes.first?.id }
            followAttention()
        } catch {
            guard !Task.isCancelled else { return }
            plan = nil
            planError = error.localizedDescription
        }
    }
}
