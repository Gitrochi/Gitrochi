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
    case edit

    var id: String {
        switch self {
        case .run(let id): return "run:" + id
        case .trust(let f, _, _): return "trust:" + f
        case .setup: return "setup"
        case .edit: return "edit"
        }
    }
}

private struct FlowPanelBody: View {
    let flows: FlowStore
    @ViewState private var sheet: FlowSheet?
    @ViewState private var confirm: (flow: String, plan: FlowPlan)?
    @ViewState private var error: String?
    @ViewState private var starting: String?
    @ViewState private var editorFlow: String?
    @ViewState private var editorNode: String?
    @AppStorage("flowAffectedOnly") private var affectedOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
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
            case .edit: FlowEditorSheet(flows: flows, initialFlow: editorFlow, initialNode: editorNode)
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

    private var header: some View {
        HStack(spacing: 8) {
            Text("Flows").font(.subheadline.weight(.semibold))
            if flows.loading { ProgressView().controlSize(.mini) }
            Spacer()
            if let list = flows.list, !list.flows.isEmpty { gateMenu(list) }
            Toggle(isOn: $affectedOnly) { Image(systemName: "scope") }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(affectedOnly ? "Running only tests affected by your changes" : "Run only tests affected by your changes")
                .accessibilityLabel("Run only affected tests")
            Button { Task { await flows.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
            Button { sheet = .edit } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("Edit flow file…")
                .disabled(!flows.engineAvailable)
            Button { sheet = .setup } label: { Image(systemName: "wand.and.stars") }
                .buttonStyle(.borderless)
                .help("Detect tests and propose a flow file")
                .disabled(!flows.engineAvailable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func gateMenu(_ list: FlowList) -> some View {
        let on = flows.gate.map { $0.gate != "OFF" } ?? false
        return Menu {
            Toggle("Check a flow before every push", isOn: Binding(get: { on }, set: { v in
                let flow = flows.gate?.flow ?? (list.flows.first { $0.name == "pre-push" } ?? list.flows[0]).name
                Task {
                    do { try await flows.setGate(v, flow: flow) } catch { self.error = error.localizedDescription }
                }
            }))
            if on, let f = flows.gate?.flow {
                Picker("Flow", selection: Binding(get: { f }, set: { nf in Task { try? await flows.setGate(true, flow: nf) } })) {
                    ForEach(list.flows) { Text($0.name).tag($0.name) }
                }
                Text(flows.gate?.gate == "OK" ? String(localized: "This commit has passed") : String(localized: "This commit hasn't passed yet"))
            }
        } label: {
            Image(systemName: on ? "checkmark.shield.fill" : "shield")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(on ? "Pushes check a flow first" : "Pushes don't check a flow")
        .accessibilityLabel("Pre-push check")
    }

    @ViewBuilder
    private var content: some View {
        if !flows.engineAvailable {
            emptyState(icon: "exclamationmark.triangle", text: String(localized: "The flow engine (gitch-flow) isn't in this Gitrochi. Update Gitrochi to run flows."))
        } else if !flows.hasFlowFile {
            workspace(FlowList(project: nil, trusted: false, flows: [], suites: []))
        } else if let e = flows.loadError {
            VStack(alignment: .leading, spacing: 8) {
                if let c = e.code { Text(c).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Text(e.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if let a = e.action { Text(a).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Edit flow file…") { sheet = .edit }
                    Button("Try again") { Task { await flows.refresh() } }
                }
                .buttonStyle(.link)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let list = flows.list {
            workspace(list)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workspace(_ list: FlowList) -> some View {
        FlowWorkspaceView(flows: flows, list: list, affected: affectedOnly, starting: starting,
                          onRun: { name in Task { await prepare(name) } },
                          onReview: { plan in sheet = .trust(flow: plan.flow, plan: plan, thenRun: false) },
                          onEdit: { sheet = .edit }, onOpenRun: { sheet = .run($0) },
                          onSelection: { flow, node in editorFlow = flow; editorNode = node })
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
