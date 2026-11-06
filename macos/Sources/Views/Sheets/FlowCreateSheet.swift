import SwiftUI
import AppKit

/// Creates a separate validated flow file while keeping existing flow sources intact.
struct FlowCreateSheet: View {
    let flows: FlowStore
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft = FlowCreationDraft()
    @ViewState private var saving = false
    @ViewState private var attempted = false
    @ViewState private var failure: FlowEngine.Failure?
    @ViewState private var confirmClose = false
    @FocusState private var nameFocused: Bool

    private var problem: FlowCreationDraft.Problem? {
        draft.problem(existingNames: flows.list?.flows.map(\.name) ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DesignIconImage(icon: .branch).font(.title2).foregroundStyle(.secondary)
                    .frame(width: 42, height: 42).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create flow").font(.title3.weight(.semibold))
                    Text("Build a flow from your commands.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: requestClose) { DesignIconImage(icon: .close) }
                    .buttonStyle(.borderless).help("Close").accessibilityLabel("Close").disabled(saving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identity
                    execution
                    steps
                }.padding(2)
            }
            .disabled(saving)
            if attempted, let problem { Text(problem.message).font(.caption).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            if let failure {
                VStack(alignment: .leading, spacing: 4) {
                    if let code = failure.code { Text(code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Text(failure.message).foregroundStyle(.red)
                    if let action = failure.action { Text(action).foregroundStyle(.secondary) }
                }
                .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                if saving { ProgressView().controlSize(.small) }
                Text("Creating a flow saves it without running commands.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: requestClose).keyboardShortcut(.cancelAction).disabled(saving)
                Button("Create flow") { Task { await create() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(20).frame(width: 620, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(saving || draft.hasChanges)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmClose) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .onAppear { nameFocused = true }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Flow name").font(.callout.weight(.medium))
                TextField("Flow name", text: $draft.name).textFieldStyle(.roundedBorder).focused($nameFocused)
                Text("Use 1–64 lowercase letters, numbers, hyphens or underscores, starting with a letter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.callout.weight(.medium))
                TextField("Optional", text: $draft.description).textFieldStyle(.roundedBorder).accessibilityLabel("Description")
            }
        }
    }

    private var execution: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Execution").font(.callout.weight(.medium))
                Spacer()
                Picker("Execution", selection: $draft.execution) {
                    Text("In order").tag(FlowCreationDraft.Execution.inOrder)
                    Text("In parallel").tag(FlowCreationDraft.Execution.inParallel)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
            }
            Text(draft.execution == .inOrder ? String(localized: "Each step starts after the previous step succeeds.") : String(localized: "Steps run independently at the same time."))
                .font(.caption).foregroundStyle(.secondary)
            Label("Commands run from the repository folder.", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($draft.steps) { step in stepCard(step) }
            Button { draft.steps.append(.init()) } label: { Label("Add step", systemImage: "plus") }
                .buttonStyle(.bordered)
        }
    }

    private func stepCard(_ step: Binding<FlowCreationDraft.Step>) -> some View {
        let index = draft.steps.firstIndex { $0.id == step.wrappedValue.id } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).background(Color.primary.opacity(0.05), in: Circle())
                TextField("Step title (optional)", text: step.title).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Step title (optional)")
                HStack(spacing: 5) {
                    Button { move(step.wrappedValue.id, by: -1) } label: { DesignIconImage(icon: .push) }
                        .disabled(index == 0).help("Move up").accessibilityLabel("Move up")
                    Button { move(step.wrappedValue.id, by: 1) } label: { DesignIconImage(icon: .pull) }
                        .disabled(index == draft.steps.count - 1).help("Move down").accessibilityLabel("Move down")
                    Button {
                        let id = step.wrappedValue.id
                        draft.steps.removeAll { $0.id == id }
                    } label: { DesignIconImage(icon: .trash) }
                        .disabled(draft.steps.count == 1).help("Remove step").accessibilityLabel("Remove step")
                }.buttonStyle(.borderless)
            }
            Text("Command").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            FlowCreationCommandEditor(text: step.command)
                .frame(height: 104).padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                .accessibilityLabel("Command")
        }
        .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(index + offset) else { return }
        draft.steps.swapAt(index, index + offset)
    }

    private func requestClose() {
        guard !saving else { return }
        if draft.hasChanges { confirmClose = true }
        else { dismiss() }
    }

    @MainActor private func create() async {
        guard !saving else { return }
        attempted = true
        failure = nil
        guard problem == nil else { return }
        saving = true
        defer { saving = false }
        let draft = draft
        do {
            let existing = FlowEngine.hasFlowFile(in: flows.repo) ? try await FlowEngine.list(in: flows.repo).flows.map(\.name) : []
            if let problem = draft.problem(existingNames: existing) { throw FlowEngine.Failure(message: problem.message) }
            let rendered = try await FlowEngine.renderDesign(draft.document(), original: nil, in: flows.repo)
            if let diagnostic = rendered.diagnostics.first(where: { $0.severity == "error" }) { throw FlowEngine.Failure(message: diagnostic.message, code: diagnostic.code) }
            guard !rendered.yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FlowEngine.Failure(message: String(localized: "The flow file cannot be empty."))
            }
            let target = flows.repo.appendingPathComponent(draft.file)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw FlowEngine.Failure(message: String(localized: "That flow file already exists. Choose a new file name."))
            }
            try await FlowEngine.saveConfiguration(rendered.yaml, original: nil, file: draft.file, in: flows.repo)
            await flows.refresh()
            onCreated(draft.trimmedName)
            dismiss()
        } catch let error as FlowEngine.Failure { failure = error }
        catch { failure = FlowEngine.Failure(message: error.localizedDescription) }
    }
}

/// Shell commands must not inherit smart quotes, dashes or spelling replacements.
private struct FlowCreationCommandEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isRichText = false
        view.isEditable = enabled
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.string = text
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.setAccessibilityLabel(String(localized: "Command"))
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = enabled
        if view.string != text {
            context.coordinator.updating = true
            view.string = text
            context.coordinator.updating = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: FlowCreationCommandEditor
        var updating = false
        init(_ parent: FlowCreationCommandEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            // AppKit undo can update storage without sending the text-view delegate notification.
            guard !updating, editedMask.contains(.editedCharacters) else { return }
            parent.text = textStorage.string
        }
    }
}
