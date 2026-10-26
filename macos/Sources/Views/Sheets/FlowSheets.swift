import SwiftUI
import AppKit

/// One run: live node states, the end of the chosen node's log, failure locations and rollback. Verdicts are shown exactly as the engine made them.
struct FlowRunSheet: View {
    let flows: FlowStore
    let runId: String
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected: String?
    @ViewState private var copied = false
    @ViewState private var cancelling = false
    @ViewState private var error: String?

    private var view: FlowRunView? { flows.view(runId) }
    private var record: FlowJSON? { flows.record(runId) }
    private var running: Bool { view.map { !$0.done } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                nodeList.frame(minWidth: 230, idealWidth: 270)
                detail.frame(minWidth: 400)
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 920, minHeight: 540, idealHeight: 640)
        .task { await flows.open(runId) }
    }

    private var header: some View {
        let state = view?.state ?? record?["state"].string
        return HStack(spacing: 10) {
            FlowStateIcon(state: state, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(view?.flow.isEmpty == false ? view!.flow : (record?["flow"].string ?? "")).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text(FlowFormat.stateTitle(state))
                    if let c = view?.code ?? record?["code"].string { Text(c).font(.caption.monospaced()) }
                    Text(runId).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let v = view {
                let c = v.counts
                Text("\(c.passed) passed · \(c.failed) failed · \(c.total) steps")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if running { ProgressView().controlSize(.small) }
        }
        .padding(14)
    }

    private var nodes: [FlowRunView.Node] { view?.nodes ?? [] }

    private var nodeList: some View {
        List(selection: $selected) {
            Section("Steps") {
                ForEach(nodes) { n in
                    HStack(spacing: 6) {
                        FlowStateIcon(state: n.state.rawValue)
                        Text(n.branchOf == nil ? n.id : "↳ " + n.id).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let t = n.testsExecuted { Text("\(n.testsPassed ?? 0)/\(t)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        if let d = n.durationMs { Text(FlowFormat.duration(d)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .tag(n.id)
                }
            }
            if let steps = view?.steps, !steps.isEmpty {
                Section("Services and rollback") {
                    ForEach(steps) { s in
                        HStack(spacing: 6) {
                            Image(systemName: stepIcon(s.state)).foregroundStyle(.secondary)
                            Text(s.node.map { "\($0): \(s.text)" } ?? s.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(s.state).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: nodes.map(\.state)) { _, _ in
            // Without a choice, show the node that is running (or else the first that failed).
            if selected == nil || nodes.first(where: { $0.id == selected })?.state == .passed {
                selected = nodes.first { $0.state == .running }?.id ?? nodes.first { $0.state.isBad }?.id ?? selected
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

    /// That node in the record (run.json)
    private func recordNode(_ id: String) -> FlowJSON? {
        record?["nodes"].array.first { $0["id"].string == id }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selected, let n = nodes.first(where: { $0.id == id }) {
            let rec = recordNode(id)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    FlowStateIcon(state: n.state.rawValue, size: 14)
                    Text(n.id).font(.headline).textSelection(.enabled)
                    Text(n.block).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if let log = n.log, let dir = record?["runDir"].string {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: dir).appendingPathComponent(log)) } label: { Image(systemName: "doc.text.magnifyingglass") }
                            .buttonStyle(.borderless)
                            .help("Open the full log")
                    }
                }
                if let f = rec?["failure"], f != .null {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f["description"].string ?? "").font(.callout.weight(.medium))
                        if let a = f["action"].string { Text(a).font(.caption).foregroundStyle(.secondary) }
                        if let d = f["detail"].string, !d.isEmpty { Text(d).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                } else if let r = n.reason {
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
                let failures = rec?["failures"].array ?? []
                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Failed tests").font(.subheadline.weight(.semibold))
                        ForEach(Array(failures.enumerated()), id: \.offset) { _, f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f["name"].string ?? "").font(.callout).lineLimit(2)
                                if let file = f["file"].string {
                                    let line = f["line"].int.map { ":\($0)" } ?? ""
                                    Button(file + line) { openFile(file, line: f["line"].int) }
                                        .buttonStyle(.link)
                                        .font(.caption.monospaced())
                                }
                                if let m = f["message"].string { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        }
                    }
                }
                let verdicts = rec?["verdicts"].array ?? []
                if !verdicts.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verdicts").font(.subheadline.weight(.semibold))
                        ForEach(Array(verdicts.enumerated()), id: \.offset) { _, v in
                            HStack(spacing: 6) {
                                FlowStateIcon(state: v["result"].string == "PASS" ? "PASSED" : "FAILED", size: 10)
                                Text(v["rule"].string ?? "").font(.caption.monospaced())
                                Text(v["title"].string ?? "").font(.caption).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(v["observed"].string ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Text("Output").font(.subheadline.weight(.semibold))
                logView(n.tail)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                rollbackNote
                Text(nodes.isEmpty ? String(localized: "Waiting for the engine…") : String(localized: "Choose a step to see its output."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var rollbackNote: some View {
        if let rb = record?["rollback"], rb != .null {
            VStack(alignment: .leading, spacing: 4) {
                if rb["state"].string == "ROLLBACK_FAILED" {
                    Label("Rollback failed. The environment is on hold until a person checks it and releases it (gitch flow hold release).", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                } else if rb["state"].string == "ROLLED_BACK" {
                    Label("The changes were undone in reverse order.", systemImage: "arrow.uturn.backward.circle")
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

    private func logView(_ lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if running {
                Button(role: .destructive) {
                    cancelling = true
                    Task {
                        do { try await flows.cancel(runId) } catch { self.error = error.localizedDescription }
                    }
                } label: { Label("Cancel run", systemImage: "stop.fill") }
                .disabled(cancelling)
                .help("Stops every step and its child processes, then undoes what was changed")
            }
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
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    /// Opens a failure location: the file in the repository, in the default editor (the file only, since editors take line numbers differently)
    private func openFile(_ rel: String, line: Int?) {
        let url = flows.repo.appendingPathComponent(rel)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Review this flow").font(.title3.weight(.semibold))
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
                Label("Acts outside this computer: \(plan.outward.joined(separator: ", "))", systemImage: "arrow.up.forward.app")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !plan.services.isEmpty {
                Label("Starts services: \(plan.services.joined(separator: ", "))", systemImage: "shippingbox")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(plan.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { dismiss(); onApprove() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
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
                                Image(systemName: "checkmark.circle").foregroundStyle(.green)
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
                    Label("A flow file already exists, so nothing will be written. Merge the proposal by hand.", systemImage: "exclamationmark.triangle")
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
