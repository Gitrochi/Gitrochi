import SwiftUI

/// A person's Markdown notes, kept outside agent-facing records. (Windows: LedgerNotebook.tsx)
struct LedgerNotebookSheet: View {
    let ledger: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var notes: [Note] = []
    @ViewState private var selected: Note?
    @ViewState private var title = ""
    @ViewState private var text = ""
    @ViewState private var pinned = false
    @ViewState private var preview = false
    @ViewState private var query = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var pending: Pending?

    private struct Note: Codable, Identifiable, Equatable, Sendable {
        let id: Int
        let title: String
        let body: String
        let pinned: Bool
        let createdAt: Int
        let updatedAt: Int
    }
    private struct ListResult: Decodable, Sendable { let notes: [Note] }
    private struct NoteResult: Decodable, Sendable { let note: Note }
    private enum Pending {
        case select(Note), create, close, delete, reload
        var deleting: Bool { if case .delete = self { return true }; return false }
    }

    private var dirty: Bool {
        title != (selected?.title ?? "") || text != (selected?.body ?? "") || pinned != (selected?.pinned ?? false)
    }
    private var filtered: [Note] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter { needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle) || $0.body.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notebook").font(.title3.weight(.semibold))
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Personal notes stay in your notebook and are never sent to agents.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                noteList
                Divider()
                editor
            }
            HStack {
                if selected != nil {
                    Button("Delete note…", role: .destructive) { request(.delete) }.disabled(busy)
                }
                Spacer()
                Button("Close") { request(.close) }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(busy || !dirty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 940, height: 620)
        .interactiveDismissDisabled(dirty || busy)
        .task { await initialLoad() }
        .alert(pending?.deleting == true ? String(localized: "Delete this note?") : String(localized: "Discard unsaved changes?"),
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            if let action = pending {
                Button(action.deleting ? String(localized: "Delete") : String(localized: "Discard changes"), role: .destructive) {
                    Task { await run(action) }
                }
            }
        } message: {
            Text(pending?.deleting == true ? String(localized: "This removes the note permanently.")
                 : String(localized: "Your draft will be replaced. Save it first to keep your changes."))
        }
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search notes", text: $query).textFieldStyle(.roundedBorder)
            Button("New note") { request(.create) }.disabled(busy)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered) { note in
                        Button { request(.select(note)) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 4) {
                                    if note.pinned { SymbolIcon("pin.fill").accessibilityLabel("Pinned") }
                                    Text(note.title).fontWeight(selected?.id == note.id ? .semibold : .regular)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                Text(note.body.split(separator: "\n").first.map(String.init) ?? String(localized: "Empty note"))
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selected?.id == note.id ? Color.accentColor.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(busy)
                        .accessibilityElement(children: .combine)
                    }
                    if filtered.isEmpty {
                        Text(query.isEmpty ? String(localized: "No notes yet. Write your first note.") : String(localized: "No notes match your search."))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
        }
        .frame(width: 240)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Note title", text: $title).textFieldStyle(.roundedBorder).disabled(busy)
            HStack(spacing: 14) {
                Toggle("Pin note", isOn: $pinned).toggleStyle(.checkbox).disabled(busy)
                Toggle("Preview Markdown", isOn: $preview).toggleStyle(.checkbox)
                Spacer()
                if selected != nil { Button("Reload note") { request(.reload) }.disabled(busy) }
            }
            .font(.system(size: 12))
            if preview {
                ScrollView { MarkdownView(text.isEmpty ? String(localized: "Empty note") : text).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            } else {
                TextEditor(text: $text).font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(6).disabled(busy)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("Note text")
            }
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Give this note a title before saving.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled) }
        }
    }

    private func select(_ note: Note?) {
        selected = note
        title = note?.title ?? ""
        text = note?.body ?? ""
        pinned = note?.pinned ?? false
        error = nil
    }

    private func request(_ action: Pending) {
        guard !busy else { return }
        if case .select(let note) = action, note.id == selected?.id { return }
        if action.deleting || dirty { pending = action } else { Task { await run(action) } }
    }

    private func read<T: Decodable>(_ args: [String: LedgerJSON], as type: T.Type = T.self) async throws -> T {
        let value = try await ledger.client.notebook(args)
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func refresh() async throws -> [Note] {
        let result: ListResult = try await read(["action": "list"])
        notes = result.notes
        return result.notes
    }

    private func initialLoad() async {
        busy = true
        defer { busy = false }
        do { select(try await refresh().first) } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        var args: [String: LedgerJSON] = ["action": "save", "title": .string(title), "body": .string(text), "pinned": .bool(pinned)]
        if let selected {
            args["id"] = .number(Double(selected.id))
            args["expectedUpdatedAt"] = .number(Double(selected.updatedAt))
        }
        do {
            let result: NoteResult = try await read(args)
            select(result.note)
            _ = try await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ action: Pending) async {
        pending = nil
        switch action {
        case .close: dismiss()
        case .create: select(nil)
        case .select(let note): select(note)
        case .delete, .reload:
            guard let selected else { return }
            busy = true
            error = nil
            defer { busy = false }
            do {
                if action.deleting {
                    let _: LedgerJSON = try await read(["action": "delete", "id": .number(Double(selected.id)), "expectedUpdatedAt": .number(Double(selected.updatedAt))])
                    select(try await refresh().first)
                } else {
                    let result: NoteResult = try await read(["action": "get", "id": .number(Double(selected.id))])
                    select(result.note)
                    _ = try await refresh()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
