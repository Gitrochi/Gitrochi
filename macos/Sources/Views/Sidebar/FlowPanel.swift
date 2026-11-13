import SwiftUI
import AppKit

/// Flows (.gitch/flow.yml): the flows that assemble this repository's tests, checks and deploy steps, and the recent runs.
/// The flow engine (gitch-flow) runs, judges and rolls back; this screen sends the actions a person clicks and shows the results.
struct FlowPanel: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        if let url = store.url {
            FlowPanelBody(flows: FlowCenter.shared.store(for: url))
        } else {
            Text("Open a repository to use flows.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum FlowSheet: Identifiable, Equatable {
    case run(String)
    case trust(flow: String, plan: FlowPlan, thenRun: Bool)
    case setup
    /// The editor, opened on a flow and a step when the person came from one
    case edit(flow: String?, node: String?)
    case create

    var id: String {
        switch self {
        case .run(let id): return "run:" + id
        case .trust(let f, _, _): return "trust:" + f
        case .setup: return "setup"
        case .edit: return "edit"
        case .create: return "create"
        }
    }
}

/// The page: why there is no flow to show, or the workspace; and the sheets and questions its actions lead to.
private struct FlowPanelBody: View {
    let flows: FlowStore
    @ViewState private var sheet: FlowSheet?
    @ViewState private var confirm: (flow: String, plan: FlowPlan)?
    @ViewState private var error: String?
    @ViewState private var starting: String?
    @ViewState private var requestedFlow: String?
    @AppStorage("flowAffectedOnly") private var affectedOnly = false

    var body: some View {
        content
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flows")
        .task(id: flows.repo) { await poll() }
        .sheet(item: $sheet) { s in
            switch s {
            case .run(let id): FlowRunSheet(flows: flows, runId: id)
            case .trust(let flow, let plan, let thenRun):
                FlowTrustSheet(plan: plan, actionTitle: thenRun ? String(localized: "Trust and run") : String(localized: "Trust")) {
                    Task {
                        do {
                            try await flows.trust()
                            if thenRun { await prepare(flow) }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            case .setup: FlowSetupSheet(flows: flows)
            case .edit(let flow, let node): FlowEditorSheet(flows: flows, initialFlow: flow, initialNode: node)
            case .create: FlowCreateSheet(flows: flows) { name in requestedFlow = name }
            }
        }
        .confirmationDialog(
            "Run this flow?",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            presenting: confirm
        ) { c in
            Button("Run") { Task { await launch(c.flow, yes: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(confirmText(c.plan))
        }
        .alert("Couldn't run the flow", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    /// Reads once, then again every 3 seconds while a run is going and every 30 seconds otherwise (so runs started elsewhere and file changes show up)
    private func poll() async {
        await flows.refresh()
        while !Task.isCancelled {
            let active = flows.runs.contains { $0.running == true }
            try? await Task.sleep(for: .seconds(active ? 3 : 30))
            if Task.isCancelled { break }
            await flows.refresh()
        }
    }

    /// Why there is no flow to show, each in a shared form, or else the workspace
    @ViewBuilder
    private var content: some View {
        if !flows.engineAvailable {
            HostedListEmpty(symbol: "exclamationmark.triangle",
                            title: String(localized: "The flow engine (gitch-flow) isn't in this Gitrochi. Update Gitrochi to run flows."))
        } else if !flows.hasFlowFile {
            noFlows
        } else if let failure = flows.loadError {
            // the engine's code and what it says to do, when it gave either
            let advice = [failure.code, failure.action].compactMap { $0 }.joined(separator: " · ")
            NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: failure.message, caption: advice.isEmpty ? nil : advice,
                        actions: [NoticeAction(title: String(localized: "Edit flow file…")) { sheet = .edit(flow: nil, node: nil) },
                                  NoticeAction(title: String(localized: "Try again")) { Task { await flows.refresh() } }])
                .frame(maxWidth: 560).padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let list = flows.list {
            if list.flows.isEmpty { noFlows } else { workspace(list) }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noFlows: some View {
        FlowEmptyState(onSetUp: { sheet = .setup }, onCreate: { sheet = .create })
    }

    private func workspace(_ list: FlowList) -> some View {
        FlowWorkspaceView(flows: flows, list: list, affected: affectedOnly, starting: starting, requestedFlow: requestedFlow,
                          onCreate: { sheet = .create },
                          onRun: { name in Task { await prepare(name) } },
                          onStop: { id in Task { do { try await flows.cancel(id) } catch { self.error = error.localizedDescription } } },
                          onOpenRun: { sheet = .run($0) },
                          onEdit: { flow, node in sheet = .edit(flow: flow, node: node) },
                          onReview: { name in Task { await review(name) } },
                          moreActions: { flow in
                              FlowMoreActionsMenu(flows: flows, list: list, flow: flow,
                                                  onReview: { Task { await review(flow.name) } },
                                                  onSetUp: { sheet = .setup },
                                                  onError: { error = $0 })
                          })
    }

    /// Shows the commands a flow would run, to read and approve without running anything
    private func review(_ flow: String) async {
        do {
            let plan = try await FlowEngine.plan(flow, in: flows.repo, affected: affectedOnly)
            sheet = .trust(flow: flow, plan: plan, thenRun: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Before a run: read the plan to see whether trust or confirmation is needed.
    private func prepare(_ flow: String) async {
        starting = flow
        defer { starting = nil }
        do {
            let plan = try await FlowEngine.plan(flow, in: flows.repo, affected: affectedOnly)
            if !plan.trust.trusted {
                sheet = .trust(flow: flow, plan: plan, thenRun: true)
            } else if plan.needsConfirmation || !plan.gates.isEmpty {
                confirm = (flow, plan)
            } else {
                await launch(flow, yes: false)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func launch(_ flow: String, yes: Bool) async {
        starting = flow
        defer { starting = nil }
        do {
            let id = try await flows.start(flow, affected: affectedOnly, yes: yes)
            sheet = .run(id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func confirmText(_ p: FlowPlan) -> String {
        var parts: [String] = []
        if !p.outward.isEmpty { parts.append(String(localized: "It acts outside this computer: \(p.outward.joined(separator: ", ")).")) }
        let destructive = p.nodes.filter { $0.destructive == true && $0.decision == "run" }.map(\.id)
        if !destructive.isEmpty { parts.append(String(localized: "Hard to undo: \(destructive.joined(separator: ", ")).")) }
        if !p.gates.isEmpty { parts.append(String(localized: "Running it approves its manual steps: \(p.gates.joined(separator: ", ")).")) }
        parts.append(String(localized: "Environment: \(p.env)"))
        return parts.joined(separator: "\n")
    }
}

/// No flow to show: the shared empty form (a 24 pt grey icon, one line, one caption) and the two ways to start. Set up
/// is filled because the page is blocked until there is a flow file.
private struct FlowEmptyState: View {
    let onSetUp: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            DesignIconImage(icon: .flows, size: 24).foregroundStyle(HostedList.caption)
            Text("No flows in this repository").font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text("Describe your build and test steps once in .gitch/flow.yml, then run them here and in CI.")
                .font(.system(size: 12)).foregroundStyle(HostedList.caption).multilineTextAlignment(.center)
                .frame(maxWidth: 400).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Set up flows…", action: onSetUp).hostedListFilledButton()
                Button("New flow…", action: onCreate).buttonStyle(HostedListButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Everything about a flow that is not Edit or Run, each with its name: what used to be a row of unlabeled icon
/// buttons above the page. (Windows: moreActions in FlowPanel.tsx)
struct FlowMoreActionsMenu: View {
    let flows: FlowStore
    let list: FlowList
    let flow: FlowList.Flow
    let onReview: () -> Void
    let onSetUp: () -> Void
    let onError: (String) -> Void
    @AppStorage("flowAffectedOnly") private var affectedOnly = false

    private var gateOn: Bool { flows.gate.map { $0.gate != "OFF" } ?? false }
    /// The flow a newly switched-on check runs: the one already set, else pre-push, else this flow
    private var gateFlow: String {
        flows.gate?.flow ?? (list.flows.contains { $0.name == "pre-push" } ? "pre-push" : flow.name)
    }

    var body: some View {
        Menu {
            Button("Review commands…", action: onReview)
            Divider()
            Toggle("Check a flow before every push", isOn: Binding(get: { gateOn }, set: { setGate($0, flow: gateFlow) }))
                .help(gateOn ? "Pushes check a flow first" : "Pushes don't check a flow")
            if gateOn, let checked = flows.gate?.flow {
                Picker("Flow", selection: Binding(get: { checked }, set: { setGate(true, flow: $0) })) {
                    ForEach(list.flows) { Text($0.name).tag($0.name) }
                }
                Text(flows.gate?.gate == "OK" ? String(localized: "This commit has passed") : String(localized: "This commit hasn't passed yet"))
            }
            Toggle("Run only affected tests", isOn: $affectedOnly)
                .help("Run only tests affected by your changes")
            Divider()
            Button("Set up flows…", action: onSetUp)
                .help("Detect tests and propose a flow file")
            Button("Refresh") { Task { await flows.refresh() } }
        } label: {
            DesignIconImage(icon: .more, size: 14)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
        .help("More flow actions")
        .accessibilityLabel("More flow actions")
    }

    private func setGate(_ on: Bool, flow: String) {
        Task {
            do { try await flows.setGate(on, flow: flow) } catch { onError(error.localizedDescription) }
        }
    }
}
