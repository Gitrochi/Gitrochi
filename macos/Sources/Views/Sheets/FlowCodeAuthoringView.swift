import SwiftUI

/// Code defines execution order; the diagram is a read-only projection of the latest parsed source.
struct FlowCodeAuthoringView: View {
    @Bindable var design: FlowAuthoringStore
    @Bindable var related: FlowRelatedFileStore
    @ViewState private var pathInput = ""
    @ViewState private var requestedFile: FileTarget?
    @ViewState private var templates = false
    @ViewState private var fontSize: CGFloat = 12
    @ViewState private var wraps = false
    @ViewState private var findText = ""
    @ViewState private var matchIndex = 0

    private struct FileTarget: Identifiable {
        let path: String?
        var create = false
        var id: String { (path ?? "flow") + String(create) }
    }
    private var busy: Bool { design.saving || design.loading || design.formatting || related.saving || related.loading }
    private var currentPath: String { related.active ? related.path : design.file }
    private var currentText: String { related.active ? related.text : design.yaml }
    private var textBinding: Binding<String> {
        let editingRelated = related.active
        let path = currentPath
        return Binding(get: { editingRelated ? related.text : design.yaml }, set: {
            if editingRelated {
                guard related.active, related.path == path else { return }
                related.edit($0)
            } else {
                guard !related.active, design.file == path else { return }
                design.editCode($0)
            }
        })
    }
    private var references: [String] {
        FlowRelatedReferences.paths(node: design.selected, suite: design.suiteDefinition)
    }

    var body: some View {
        VStack(spacing: 0) {
            fileControls
            Divider()
            FlowSplitView(initialFraction: 0.57, minimumLeading: 400, minimumTrailing: 300) {
                VStack(spacing: 0) {
                    sourceHeader
                    Divider()
                    RepositoryCodeReader(text: currentText, path: currentPath, syntax: true, fontSize: $fontSize, wraps: $wraps,
                                         findText: $findText, matchIndex: $matchIndex, editableText: textBinding)
                        .id(currentPath).disabled(busy).accessibilityIdentifier("flow-code-editor")
                }
            } trailing: {
                preview
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $templates) { FlowModuleCatalog(design: design, onInsert: applyTemplate) }
        .confirmationDialog("Discard unsaved file changes?", isPresented: Binding(get: { requestedFile != nil }, set: { if !$0 { requestedFile = nil } }), presenting: requestedFile) { target in
            Button("Discard changes", role: .destructive) { requestedFile = nil; Task { await open(target) } }
            Button("Keep editing", role: .cancel) { requestedFile = nil }
        }
        .task(id: design.codeRevision) { await design.previewCode() }
    }

    private var fileControls: some View {
        HStack(spacing: 9) {
            Button { request(FileTarget(path: nil)) } label: { Label("Flow definition", systemImage: "point.3.connected.trianglepath.dotted") }
                .disabled(!related.active)
            Menu {
                if references.isEmpty { Text("No literal file references found") }
                ForEach(references, id: \.self) { path in Button(path) { request(FileTarget(path: path)) } }
            } label: { Label("Related files", systemImage: "doc.on.doc") }
            .menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 18)
            TextField("Repository-relative path", text: $pathInput).textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: .infinity)
                .onSubmit { request(FileTarget(path: pathInput)) }
            Button("Open") { request(FileTarget(path: pathInput)) }.disabled(pathInput.isEmpty)
            Button("New file") { request(FileTarget(path: pathInput, create: true)) }.disabled(pathInput.isEmpty)
        }
        .controlSize(.small).padding(.horizontal, 12).frame(height: 42).disabled(busy)
    }

    private var sourceHeader: some View {
        HStack(spacing: 9) {
            DesignIconImage(icon: .file).foregroundStyle(.secondary)
            Text(currentPath).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if related.active {
                if related.dirty { Text("Unsaved changes").font(.caption2).foregroundStyle(.secondary) }
                Button("Save file") {
                    Task {
                        if await related.save() { design.attachments.removeValue(forKey: related.path) }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command).disabled(!related.dirty || busy)
            } else {
                Menu {
                    Button("Module from catalogue…") { templates = true }
                    Button("Fork and join example") { design.addForkJoin(); applyTemplate() }
                } label: { Label("Insert template", systemImage: "plus.square") }
                .menuStyle(.borderlessButton).fixedSize().disabled(!design.sourcePreviewCurrent || busy || design.selectedFlow.isEmpty)
            }
        }.controlSize(.small).padding(.horizontal, 12).frame(height: 42)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Source preview", systemImage: "point.3.connected.trianglepath.dotted").font(.caption.weight(.medium))
                Spacer()
                Picker("Flow", selection: $design.selectedFlow) {
                    ForEach(design.flowNames, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 180)
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 42)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if design.sourcePreviewCurrent {
                FlowGraphView(nodes: design.graphNodes, selected: $design.selectedNode, initialFit: true).id(design.selectedFlow)
            } else {
                VStack(spacing: 10) {
                    if design.previewing { ProgressView().controlSize(.small); Text("Updating source preview…") }
                    else { Image(systemName: "exclamationmark.triangle").font(.title2); Text("Preview is out of date").font(.headline); Text("Fix the source errors to update the diagram.") }
                }.font(.callout).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("flow-preview-stale")
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("The diagram follows the flow definition. Edit needs in that file to change execution order; no wire drawing is needed.").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: "needs: [prepare]").font(.system(size: 11, design: .monospaced))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func request(_ target: FileTarget) {
        guard !busy else { return }
        if related.dirty { requestedFile = target } else { Task { await open(target) } }
    }
    private func open(_ target: FileTarget) async {
        guard let path = target.path, path != design.file else { related.close(); return }
        if design.attachments[path] != nil {
            related.error = String(localized: "Save the flow before opening this imported source file.")
            return
        }
        await related.open(path, create: target.create)
    }
    private func applyTemplate() {
        Task {
            do { try await design.prepareSource(); await design.previewCode() }
            catch { design.error = error.localizedDescription }
        }
    }
}
