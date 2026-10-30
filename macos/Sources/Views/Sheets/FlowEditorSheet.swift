import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Visual forms are the default; YAML remains available for advanced settings.
struct FlowEditorSheet: View {
    let flows: FlowStore
    var initialFlow: String? = nil
    var initialNode: String? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewState private var design: FlowAuthoringStore?
    @ViewState private var mode = 0
    @ViewState private var confirmClose = false
    @ViewState private var pendingFile: String?
    @ViewState private var pendingImport: FlowImportDraft?
    @ViewState private var replacement: FlowImportReplacement?
    @ViewState private var dropTarget = false
    @ViewState private var importGeneration = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let design {
                controls(design)
                if design.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if mode == 0, design.editable {
                    FlowVisualEditor(design: design)
                        .id(design.file)
                        .disabled(design.saving || design.loading)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                } else { sourceEditor(design) }
                diagnostics(design)
                footer(design)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .padding(18).frame(minWidth: 980, idealWidth: 1180, minHeight: 700, idealHeight: 820)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropTarget ? Color.accentColor : .clear, lineWidth: 3))
        .interactiveDismissDisabled(design?.dirty == true || design?.saving == true)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget, perform: receiveDrop)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmClose) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } }), presenting: pendingFile) { file in
            Button("Discard changes", role: .destructive) { pendingFile = nil; Task { await design?.load(file) } }
            Button("Keep editing", role: .cancel) { pendingFile = nil }
        }
        .sheet(item: $pendingImport) { draft in
            FlowImportPreview(draft: draft) { choice in
                Task { await useImport(draft, choice: choice) }
            }
        }
        .confirmationDialog("Replace the current unsaved draft?", isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } }), presenting: replacement) { request in
            Button("Replace draft", role: .destructive) { Task { await applyImport(request.draft, choice: request.choice) } }
            Button("Keep editing", role: .cancel) { replacement = nil }
        }
        .task {
            let model = FlowAuthoringStore(flows: flows, initialFlow: initialFlow, initialNode: initialNode)
            design = model
            await model.initialize()
            if !model.editable { mode = 1 }
        }
        .task(id: design?.revision) { await design?.updatePreview() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 21)).foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("Design flows").font(.title3.weight(.semibold))
                Text("Add modules, configure inputs and connect dependencies. Scripts run only when you start a flow.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if design?.dirty == true { Label("Unsaved changes", systemImage: "circle.fill").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func controls(_ model: FlowAuthoringStore) -> some View {
        HStack(spacing: 12) {
            Picker("Flow file", selection: Binding(get: { model.file }, set: { file in
                if model.dirty { pendingFile = file } else { Task { await model.load(file) } }
            })) { ForEach(model.files, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 400)
            Spacer()
            Picker("Editor", selection: Binding(get: { mode }, set: { selected in
                if selected == 0, mode == 1 {
                    Task {
                        model.loading = true
                        defer { model.loading = false }
                        do { try await model.inspect(); model.fieldErrors = [:]; if model.editable { mode = 0 } }
                        catch { model.error = error.localizedDescription }
                    }
                } else if selected == 1, mode == 0, model.editable {
                    Task {
                        model.loading = true
                        defer { model.loading = false }
                        do { try await model.prepareSource(); mode = 1 }
                        catch { model.error = error.localizedDescription }
                    }
                } else { mode = selected }
            })) {
                Text("Visual").tag(0)
                Text("YAML").tag(1)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
            Button { chooseImport() } label: { Label("Import file…", systemImage: "square.and.arrow.down") }
        }.controlSize(.small).disabled(model.loading || model.saving)
    }

    private func sourceEditor(_ model: FlowAuthoringStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.editable {
                Label("This source needs YAML editing. Diagnostics explain why visual editing is unavailable.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
            TextEditor(text: Binding(get: { model.yaml }, set: { model.yaml = $0 }))
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(10)
                .disabled(model.saving).accessibilityIdentifier("flow-script-editor")
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    @ViewBuilder private func diagnostics(_ model: FlowAuthoringStore) -> some View {
        if model.error != nil || !model.diagnostics.isEmpty || !model.fieldErrors.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    FlowDesignDiagnosticsView(diagnostics: model.diagnostics)
                    ForEach(model.fieldErrors.keys.sorted(), id: \.self) { key in Text(key + ": " + (model.fieldErrors[key] ?? "")).foregroundStyle(.red) }
                }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 78)
        }
    }

    private func footer(_ model: FlowAuthoringStore) -> some View {
        HStack(spacing: 12) {
            if model.saving { ProgressView().controlSize(.small) }
            Label("Changed commands require review before the next run.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { if model.dirty { confirmClose = true } else { dismiss() } }
                .keyboardShortcut(.cancelAction).disabled(model.saving)
            Button("Validate and save") {
                Task {
                    do { try await model.save(visual: mode == 0 && model.editable); dismiss() }
                    catch { model.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.loading || model.saving || !model.dirty || !model.fieldErrors.isEmpty)
        }
    }

    private func chooseImport() {
        guard design?.saving == false, design?.loading == false else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a flow, GitHub Actions, GitLab CI, Jenkins or Compose source to preview.")
        panel.begin { response in if response == .OK, let url = panel.url { Task { await inspectImport(url) } } }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.count == 1, let provider = providers.first, design?.saving == false, design?.loading == false else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let value = item as? URL { url = value }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = nil }
            if let url { Task { @MainActor in await inspectImport(url) } }
        }
        return true
    }

    private func inspectImport(_ url: URL) async {
        guard let design, !design.saving, !design.loading else { return }
        let generation = UUID()
        importGeneration = generation
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard resource.isRegularFile == true, let size = resource.fileSize, size <= 2 * 1024 * 1024 else {
                throw FlowEngine.Failure(message: String(localized: "Choose a text source no larger than 2 MB."))
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let inspection = try await FlowEngine.inspectDesign(source, file: url.lastPathComponent, in: flows.repo)
            guard generation == importGeneration, !design.saving, !design.loading else { return }
            pendingImport = FlowImportDraft(name: url.lastPathComponent, inspection: inspection)
        } catch { if generation == importGeneration, !design.saving { design.error = error.localizedDescription } }
    }

    private func useImport(_ draft: FlowImportDraft, choice: FlowImportChoice) async {
        guard let design, !design.saving, !design.loading else { return }
        if design.document != design.baseline || design.yaml != design.source {
            replacement = FlowImportReplacement(draft: draft, choice: choice)
            return
        }
        await applyImport(draft, choice: choice)
    }

    private func applyImport(_ draft: FlowImportDraft, choice: FlowImportChoice) async {
        guard let design, !design.saving, !design.loading else { return }
        replacement = nil
        do {
            switch choice {
            case .flow: try await design.importDraft(yaml: draft.inspection.yaml, name: (draft.name as NSString).deletingPathExtension)
            case .proposal:
                if let proposal = draft.inspection.proposal { try await design.importDraft(yaml: proposal.yaml, name: (draft.name as NSString).deletingPathExtension) }
            case .compose: try await design.importCompose(draft.inspection, name: (draft.name as NSString).deletingPathExtension)
            }
            mode = 0
        } catch { design.error = error.localizedDescription }
    }
}
