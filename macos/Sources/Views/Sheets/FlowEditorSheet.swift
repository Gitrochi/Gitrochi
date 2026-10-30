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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure scripts").font(.title3.weight(.semibold))
                    Text("Flow YAML and scripts").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if dirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            Text("Add scripts under run and connect steps with needs. Saving validates the file; commands run only when you start a flow.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Flow file", selection: Binding(get: { selectedFile }, set: { file in
                    if dirty { pendingFile = file } else { load(file) }
                })) {
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).controlSize(.small)
                .disabled(loading || saving)
                Spacer()
                if original == nil {
                    Button("Use script example") { content = FlowEngine.scriptExample }.disabled(loading || saving)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            editor
            if let error {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                    .frame(maxHeight: 90)
                    .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            Label("Changed commands require review before the next run.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if loading || saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if dirty { confirmClose = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Validate and save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || !dirty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(minWidth: 660, idealWidth: 820, minHeight: 620, idealHeight: 720)
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

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
                Text(selectedFile).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Flow YAML").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(Color.primary.opacity(0.035))
            Divider()
            TextEditor(text: $content)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(10)
                .disabled(loading || saving)
                .accessibilityLabel("Flow YAML and scripts")
                .accessibilityIdentifier("flow-script-editor")
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
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
