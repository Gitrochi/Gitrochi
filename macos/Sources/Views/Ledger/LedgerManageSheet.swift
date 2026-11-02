import SwiftUI

/// Person-only session details and baseline notes. (Windows: LedgerManage.tsx)
struct LedgerManageSheet: View {
    let ledger: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var project = ""
    @ViewState private var snapshot: LedgerState?
    @ViewState private var sessionID = ""
    @ViewState private var version = ""
    @ViewState private var mode = Mode.session
    @ViewState private var title = ""
    @ViewState private var kind = ""
    @ViewState private var touches = ""
    @ViewState private var related = ""
    @ViewState private var chatURL = ""
    @ViewState private var note = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var pending: Pending?

    private enum Mode { case session, baseline }
    private enum Pending {
        case session(String), version(String), project(String), mode(Mode), delete, close
        var deleting: Bool { if case .delete = self { return true }; return false }
    }
    private var session: LedgerSession? { snapshot?.sessions.first { $0.id == sessionID } }
    private var baselines: [LedgerBaseline] { snapshot?.baselines.filter { $0.project == project } ?? [] }
    private var baseline: LedgerBaseline? { baselines.first { $0.version == version } }
    private var dirty: Bool {
        if mode == .baseline { return note != (baseline?.note ?? "") }
        return title != (session?.title ?? "") || kind != (session?.kind ?? "")
            || touches != (session?.touches.joined(separator: "\n") ?? "")
            || related != (session?.related.joined(separator: "\n") ?? "") || chatURL != (session?.chatUrl ?? "")
    }
    private var canSave: Bool {
        !busy && dirty && (mode == .baseline ? baseline != nil
            : session != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty && !kind.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage records").font(.title3.weight(.semibold))
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            HStack(spacing: 16) {
                tab("Session details", mode: .session)
                tab("Baseline notes", mode: .baseline)
                Spacer()
            }
            Picker("Project", selection: Binding(get: { project }, set: { request(.project($0)) })) {
                ForEach(snapshot?.projects ?? ledger.state?.projects ?? [], id: \.key) { item in Text(item.name).tag(item.key) }
            }.disabled(busy)
            if mode == .session { sessionEditor } else { baselineEditor }
            if let error { Text(error).font(.caption).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                if mode == .session && session != nil {
                    Button("Delete session…", role: .destructive) { request(.delete) }.disabled(busy)
                }
                Spacer()
                Button("Close") { request(.close) }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(mode == .session ? String(localized: "Save session details") : String(localized: "Save baseline note")) {
                    Task { await save() }
                }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command).disabled(!canSave)
            }
        }
        .padding(20).frame(width: 760, height: 680)
        .interactiveDismissDisabled(dirty || busy)
        .task {
            project = ledger.project ?? ledger.graphProject ?? ""
            sessionID = ledger.selection ?? ""
            await load()
        }
        .alert(pending?.deleting == true ? String(localized: "Delete this session?") : String(localized: "Discard unsaved changes?"),
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            if let action = pending {
                Button(action.deleting ? String(localized: "Delete") : String(localized: "Discard changes"), role: .destructive) { Task { await run(action) } }
            }
        } message: {
            Text(pending?.deleting == true
                 ? String(localized: "This removes its reports, questions and waiting prompts. Baselines and work records remain. A running agent can report again.")
                 : String(localized: "Your draft will be replaced. Save it first to keep your changes."))
        }
    }

    private func tab(_ label: LocalizedStringKey, mode: Mode) -> some View {
        Button { request(.mode(mode)) } label: {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { if self.mode == mode { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        }.buttonStyle(.plain).disabled(busy)
    }

    private var sessionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Session", selection: Binding(get: { sessionID }, set: { request(.session($0)) })) {
                ForEach(snapshot?.sessions ?? [], id: \.id) { item in Text(item.title + " · " + item.id).tag(item.id) }
            }.disabled(busy)
            if session != nil {
                LabeledContent("Title") { TextField("Title", text: $title).textFieldStyle(.roundedBorder) }
                LabeledContent("Session kind") { TextField("Session kind", text: $kind).textFieldStyle(.roundedBorder) }
                Text("Touched IDs and paths, one per line").font(.callout)
                TextEditor(text: $touches).font(.system(size: 12, design: .monospaced))
                    .frame(height: 100).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    .accessibilityLabel("Touched IDs and paths, one per line")
                Text("Related session IDs").font(.callout)
                TextEditor(text: $related).font(.system(size: 12)).frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary)).accessibilityLabel("Related session IDs")
                LabeledContent("Chat URL") { TextField("Chat URL", text: $chatURL).textFieldStyle(.roundedBorder) }
            } else if !busy {
                Text("No sessions in this project").font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            }
        }.disabled(busy)
    }

    private var baselineEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Baseline", selection: Binding(get: { version }, set: { request(.version($0)) })) {
                ForEach(baselines, id: \.version) { item in Text(item.version).tag(item.version) }
            }.disabled(busy)
            if baseline != nil {
                Text("Baseline note").font(.callout)
                TextEditor(text: $note).font(.system(size: 13)).frame(minHeight: 180, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    .accessibilityLabel("Baseline note").disabled(busy)
            } else if !busy {
                Text("No baselines in this project").font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            }
        }
    }

    private func selectSession(_ id: String) {
        sessionID = id
        title = session?.title ?? ""
        kind = session?.kind ?? ""
        touches = session?.touches.joined(separator: "\n") ?? ""
        related = session?.related.joined(separator: "\n") ?? ""
        chatURL = session?.chatUrl ?? ""
        error = nil
    }

    private func selectVersion(_ value: String) { version = value; note = baseline?.note ?? ""; error = nil }

    private func load() async {
        let wasBusy = busy
        busy = true
        defer { busy = wasBusy }
        do {
            let data = try await ledger.client.state(project: project.isEmpty ? nil : project, range: .all)
            snapshot = data
            selectSession(data.sessions.contains { $0.id == sessionID } ? sessionID : data.sessions.first?.id ?? "")
            selectVersion(baselines.contains { $0.version == version } ? version : baselines.first?.version ?? "")
        } catch { self.error = error.localizedDescription }
    }

    private func request(_ action: Pending) {
        guard !busy else { return }
        if case .mode(let mode) = action, mode == self.mode { return }
        if action.deleting || dirty { pending = action } else { Task { await run(action) } }
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        let args: [String: LedgerJSON]
        if mode == .baseline {
            args = ["action": "version_note", "project": .string(project), "version": .string(version), "note": .string(note)]
        } else {
            let lines = { (text: String) in text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { LedgerJSON.string(String($0).trimmingCharacters(in: .whitespaces)) } }
            args = ["action": "update", "sessionId": .string(sessionID), "title": .string(title), "kind": .string(kind),
                    "touches": .array(touches.split(separator: "\n").map { .string(String($0).trimmingCharacters(in: .whitespaces)) }),
                    "related": .array(lines(related)), "chatUrl": chatURL.isEmpty ? .null : .string(chatURL)]
        }
        do {
            _ = try await ledger.client.records(args)
            await load()
            await ledger.reload()
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ action: Pending) async {
        pending = nil
        switch action {
        case .close: dismiss()
        case .session(let id): selectSession(id)
        case .version(let value): selectVersion(value)
        case .project(let value): project = value; await load()
        case .mode(let value): selectSession(sessionID); selectVersion(version); mode = value
        case .delete:
            busy = true
            error = nil
            defer { busy = false }
            do {
                _ = try await ledger.client.records(["action": "delete", "sessionId": .string(sessionID), "confirmed": true])
                if ledger.selection == sessionID { ledger.selection = nil }
                await load()
                await ledger.reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}
