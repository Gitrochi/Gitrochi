import SwiftUI

/// Preserves arbitrary YAML while scripts, dependencies and block settings are edited.
struct FlowEditorSheet: View {
    let flows: FlowStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var files: [String] = []
    @ViewState private var selectedFile = ".gitch/flow.yml"
    @ViewState private var original: String?
    @ViewState private var content = ""
    @ViewState private var error: String?
    @ViewState private var loading = true
    @ViewState private var saving = false
    @ViewState private var pendingFile: String?
    @ViewState private var confirmClose = false

    private var dirty: Bool { content != (original ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Edit flow file", systemImage: "square.and.pencil").font(.title3.weight(.semibold))
                Spacer()
                if dirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Add scripts under run and connect steps with needs. Saving validates the file; commands run only when you start a flow.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Flow file", selection: Binding(get: { selectedFile }, set: { file in
                    if dirty { pendingFile = file } else { load(file) }
                })) {
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                .disabled(loading || saving)
                Spacer()
                if original == nil {
                    Button("Use script example") { content = FlowEngine.scriptExample }.disabled(loading || saving)
                }
            }
            TextEditor(text: $content)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .disabled(loading || saving)
                .accessibilityLabel("Flow YAML and scripts")
                .accessibilityIdentifier("flow-script-editor")
            if let error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
            }
            Text("Changed commands require review before the next run.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if loading || saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if dirty { confirmClose = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Validate and save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || !dirty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(minWidth: 660, idealWidth: 800, minHeight: 580, idealHeight: 680)
        .interactiveDismissDisabled(dirty || saving)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmClose) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } }), presenting: pendingFile) { file in
            Button("Discard changes", role: .destructive) {
                pendingFile = nil
                load(file)
            }
            Button("Keep editing", role: .cancel) { pendingFile = nil }
        }
        .task {
            files = FlowEngine.configurationFiles(in: flows.repo)
            if files.isEmpty { files = [".gitch/flow.yml"] }
            load(files[0])
            if original == nil {
                loading = true
                do { content = try await FlowEngine.proposeInit(in: flows.repo).yaml }
                catch { content = FlowEngine.scriptExample }
                loading = false
            }
        }
    }

    private func load(_ file: String) {
        selectedFile = file
        error = nil
        let url = flows.repo.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                original = try String(contentsOf: url, encoding: .utf8)
                content = original ?? ""
            } catch { self.error = error.localizedDescription; original = nil; content = "" }
        } else { original = nil; content = FlowEngine.scriptExample }
        loading = false
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await FlowEngine.saveConfiguration(content, original: original, file: selectedFile, in: flows.repo)
                await flows.refresh()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
