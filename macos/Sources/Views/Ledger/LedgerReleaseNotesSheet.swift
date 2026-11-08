import SwiftUI
import AppKit

/// Release notes…: a Markdown draft for one baseline from the sessions merged into it or absorbed by its release,
/// written by the core from what their agents reported (never answers, messages or notebook notes). Pick the project
/// and baseline, read it, copy it. (Windows: widgets/ledger-workspace/ui/LedgerReleaseNotes.tsx)
struct LedgerReleaseNotesSheet: View {
    let ledger: LedgerStore
    /// The project and baseline to start with; nil picks the page's project and its HEAD
    var project: String?
    var version: String?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var chosenProject = ""
    @ViewState private var chosenVersion: String?
    @ViewState private var notes: LedgerReleaseNotes?
    @ViewState private var error: String?
    @ViewState private var loading = false
    @ViewState private var showSource = false
    @ViewState private var copied = false

    private var projects: [LedgerProject] { ledger.state?.projects ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Release notes").font(.title3.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            controls
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .task {
            chosenProject = project ?? ledger.project ?? ledger.graphProject ?? projects.first?.key ?? ""
            chosenVersion = version
            await load()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Project", selection: Binding(get: { chosenProject }, set: { key in
                chosenProject = key
                chosenVersion = nil
                Task { await load() }
            })) {
                ForEach(projects) { Text(verbatim: $0.name).tag($0.key) }
            }
            .fixedSize()
            Picker("Baseline", selection: Binding(get: { notes?.version ?? chosenVersion ?? "" }, set: { value in
                chosenVersion = value
                Task { await load() }
            })) {
                ForEach(notes?.versions ?? [], id: \.self) { value in
                    if value == notes?.versions.first {
                        Text("\(value) (HEAD)").tag(value)
                    } else {
                        Text(verbatim: value).tag(value)
                    }
                }
            }
            .fixedSize()
            .disabled(notes == nil)
            Spacer(minLength: 8)
            Picker("Show", selection: $showSource) {
                Text("Preview").tag(false)
                Text("Markdown").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button {
                guard let markdown = notes?.markdown else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy Markdown", symbol: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(notes == nil)
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var content: some View {
        if let error {
            WorkspaceEmptyState(title: "No release notes for this baseline", systemImage: "doc.text.magnifyingglass",
                                description: error, actionTitle: "Try again", action: { Task { await load() } })
        } else if let notes {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary(notes)).font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    Group {
                        if showSource {
                            Text(verbatim: notes.markdown)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            MarkdownView(notes.markdown)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .background(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).strokeBorder(StudioStyle.border))
                Text("A draft from what agents reported. Answers, messages and notebook notes are never included.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if !loading, projects.isEmpty {
            WorkspaceEmptyState(title: "No projects yet", systemImage: "doc.text",
                                description: "Release notes are drafted from sessions merged into a baseline.")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ notes: LedgerReleaseNotes) -> String {
        if notes.sessionCount == 0 { return String(localized: "No sessions were merged into \(notes.version).") }
        return String(localized: "Sessions merged into \(notes.version): \(notes.sessionCount)")
    }

    private func load() async {
        guard !chosenProject.isEmpty else { return }
        loading = true
        copied = false
        defer { loading = false }
        do {
            notes = try await ledger.client.releaseNotes(project: chosenProject, version: chosenVersion)
            error = nil
        } catch {
            notes = nil
            self.error = error.localizedDescription
        }
    }
}
