import SwiftUI

/// New issue or edit of an existing one (number set). (Windows: features/issue-editor)
struct IssueEditorSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let number: Int?
    @ViewState private var title: String
    @ViewState private var description: String
    @ViewState private var saving = false
    @ViewState private var error: String?

    init(number: Int?, title: String, body: String) {
        self.number = number
        _title = ViewState(initialValue: title)
        _description = ViewState(initialValue: body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(number.map { "Edit issue #\($0)" } ?? "New issue").font(.title3.weight(.semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Text("Description (Markdown)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $description)
                .font(.callout)
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .accessibilityLabel("Description")
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmed.isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await store.saveIssue(title: title, body: description, number: number)
            dismiss()
        } catch {
            self.error = store.describe(error)
        }
    }
}
