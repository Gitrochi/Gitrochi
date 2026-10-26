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

    var id: String {
        switch self {
        case .run(let id): return "run:" + id
        case .trust(let f, _, _): return "trust:" + f
        case .setup: return "setup"
        }
    }
}

private struct FlowPanelBody: View {
    let flows: FlowStore
    @ViewState private var sheet: FlowSheet?
    @ViewState private var confirm: (flow: String, plan: FlowPlan)?
    @ViewState private var error: String?
    @ViewState private var starting: String?
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
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Connect this repository's tests, checks and CI into flows you can run here, from gitch, before a push or in CI.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Set up flows…") { sheet = .setup }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = flows.loadError {
            VStack(alignment: .leading, spacing: 8) {
                if let c = e.code { Text(c).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Text(e.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if let a = e.action { Text(a).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Open flow file") { NSWorkspace.shared.open(flows.repo.appendingPathComponent(".gitch/flow.yml")) }
                    Button("Try again") { Task { await flows.refresh() } }
                }
                .buttonStyle(.link)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let list = flows.list {
            List {
                if !list.trusted {
                    Section {
                        Label("This flow file is new or changed. Review the commands before running it.", systemImage: "hand.raised")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Flows") {
                    ForEach(list.flows) { f in flowRow(f) }
                }
                if !flows.runs.isEmpty {
                    Section("Recent runs") {
                        ForEach(flows.runs.prefix(30)) { r in runRow(r) }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func flowRow(_ f: FlowList.Flow) -> some View {
        HStack(spacing: 6) {
            FlowStateIcon(state: f.last?.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.name).lineLimit(1)
                HStack(spacing: 4) {
                    if let d = f.description, !d.isEmpty { Text(d).lineLimit(1) }
                    Text("\(f.nodes) steps")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if starting == f.name {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await prepare(f.name) } } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Run \(f.name)")
                    .accessibilityLabel("Run \(f.name)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await prepare(f.name) } }
        .contextMenu {
            Button("Run") { Task { await prepare(f.name) } }
            if let last = f.last { Button("Show last run") { sheet = .run(last.runId) } }
            Button("Review commands…") {
                Task {
                    do { sheet = .trust(flow: f.name, plan: try await FlowEngine.plan(f.name, in: flows.repo), thenRun: false) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func runRow(_ r: FlowRunRow) -> some View {
        HStack(spacing: 6) {
            FlowStateIcon(state: r.running == true ? "RUNNING" : r.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.flow).lineLimit(1)
                HStack(spacing: 4) {
                    if let s = r.startedAt, let d = ISO8601DateFormatter.flow.date(from: s) { Text(Fmt.short(d)) }
                    if let ms = r.durationMs, r.running != true { Text(FlowFormat.duration(ms)) }
                    if let c = r.code, r.running != true { Text(c).font(.caption.monospaced()) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if r.signed == false, r.running != true {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                    .help("This record isn't signed by the engine, so gates don't trust it")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { sheet = .run(r.runId) }
        .accessibilityAction { sheet = .run(r.runId) }
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

/// Run and node state icons
struct FlowStateIcon: View {
    let state: String?
    var size: CGFloat = 12

    var body: some View {
        let (name, color) = FlowStateIcon.look(state)
        Image(systemName: name)
            .font(.system(size: size))
            .foregroundStyle(color)
            .help(FlowFormat.stateTitle(state))
            .accessibilityLabel(FlowFormat.stateTitle(state))
    }

    static func look(_ s: String?) -> (String, Color) {
        switch s {
        case "SUCCEEDED", "PASSED": return ("checkmark.circle.fill", .green)
        case "CACHED": return ("checkmark.circle", .green)
        case "FAILED", "ROLLBACK_FAILED": return ("xmark.circle.fill", .red)
        case "INDETERMINATE": return ("questionmark.circle.fill", .red)
        case "REJECTED": return ("nosign", .orange)
        case "ROLLED_BACK", "ROLLING_BACK": return ("arrow.uturn.backward.circle.fill", .orange)
        case "CANCELLED": return ("stop.circle.fill", .secondary)
        case "RUNNING", "PREFLIGHT": return ("circle.dotted", .blue)
        case "SKIPPED": return ("minus.circle", .secondary)
        case nil: return ("circle", .secondary)
        default: return ("circle", .secondary)
        }
    }
}

enum FlowFormat {
    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1fs", s) }
        return "\(Int(s) / 60)m \(Int(s) % 60)s"
    }

    static func stateTitle(_ s: String?) -> String {
        switch s {
        case "SUCCEEDED": return String(localized: "Succeeded")
        case "PASSED": return String(localized: "Passed")
        case "CACHED": return String(localized: "Passed before with the same inputs")
        case "FAILED": return String(localized: "Failed")
        case "INDETERMINATE": return String(localized: "Couldn't judge (counts as a failure)")
        case "REJECTED": return String(localized: "Rejected before running")
        case "ROLLING_BACK": return String(localized: "Rolling back")
        case "ROLLED_BACK": return String(localized: "Failed and rolled back")
        case "ROLLBACK_FAILED": return String(localized: "Rollback failed — environment on hold")
        case "CANCELLED": return String(localized: "Canceled")
        case "RUNNING", "PREFLIGHT": return String(localized: "Running")
        case "SKIPPED": return String(localized: "Skipped")
        case "PENDING": return String(localized: "Waiting")
        default: return String(localized: "Not run yet")
        }
    }
}

extension ISO8601DateFormatter {
    /// The engine's timestamps (2026-10-26T05:23:20.616Z)
    static let flow: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
