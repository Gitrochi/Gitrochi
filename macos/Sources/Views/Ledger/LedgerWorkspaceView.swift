import SwiftUI

/// The Ledger page: top view tabs and compact filters above the view, with an inspector from 1,080 pt.
/// It opens without a repository and shows the open repository's project.
/// (Windows: widgets/ledger-workspace/ui/LedgerWorkspace.tsx)
struct LedgerWorkspaceView: View {
    enum Sheet: String, Identifiable {
        case connect, importReports, importLegacy, learning, chatGPTDraft, workLog, documents, notebook, records
        var id: String { rawValue }
    }

    /// The open repository, whose project the page shows; nil without one
    let repositoryPath: String?
    var ledger: LedgerStore = .shared
    /// The window's repository, whose terminal panel the quick launches open tabs in; nil in previews and tests
    @Environment(RepoStore.self) private var store: RepoStore?
    @Environment(\.controlActiveState) private var activeState
    @ViewState private var width: CGFloat = 1200
    @ViewState private var compactInspector = false
    @ViewState private var sheet: Sheet?
    @ViewState private var sessionAfterSheet: String?
    /// The claude-ledger database chosen for Import from claude-ledger…
    @ViewState private var legacyPath: String?
    @AppStorage("ledgerInspectorWidth") private var inspectorWidth = 360.0

    /// The inspector stays a column from this width; below it, it is a sheet
    static let inspectorColumnWidth: CGFloat = 1_080

    private var compact: Bool { width < Self.inspectorColumnWidth }

    var body: some View {
        Group {
            if ledger.state == nil {
                if let error = ledger.loadError {
                    WorkspaceEmptyState(title: "The ledger cannot be read", systemImage: "exclamationmark.triangle", description: error,
                                        actionTitle: "Try again", action: { Task { await ledger.reload() } })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if ledger.isEmpty && ledger.project == nil {
                onboarding
            } else {
                workspace
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
            width = value
            if value >= Self.inspectorColumnWidth { compactInspector = false }
        }
        .task {
            ledger.activate()
            await ledger.follow(repository: repositoryPath)
        }
        .onChange(of: repositoryPath) { _, path in Task { await ledger.follow(repository: path) } }
        .onChange(of: activeState) { _, state in if state == .key { Task { await ledger.follow(repository: repositoryPath) } } }
        .sheet(isPresented: $compactInspector) {
            LedgerInspector(ledger: ledger, open: open, close: { compactInspector = false })
                .frame(width: 480, height: 640)
        }
        .sheet(item: $sheet, onDismiss: {
            if let id = sessionAfterSheet {
                sessionAfterSheet = nil
                open(id)
            }
        }) { sheet in
            switch sheet {
            case .connect: LedgerConnectSheet(ledger: ledger)
            case .importReports: LedgerImportSheet(ledger: ledger)
            case .importLegacy: if let legacyPath { LedgerLegacyImportSheet(ledger: ledger, path: legacyPath) }
            case .learning:
                LedgerLearningSheet(openConnect: { switchSheet(to: .connect) },
                                    bringChatGPTDraft: { switchSheet(to: .chatGPTDraft) })
            case .chatGPTDraft:
                LedgerChatGPTDraftSheet(ledger: ledger, onOpenQuestion: { id in
                    sessionAfterSheet = id
                    self.sheet = nil
                })
            case .workLog: LedgerWorkLogSheet(ledger: ledger)
            case .documents: LedgerDocumentsSheet(ledger: ledger)
            case .notebook: LedgerNotebookSheet(ledger: ledger)
            case .records: LedgerManageSheet(ledger: ledger)
            }
        }
        .alert("The ledger did not take the change", isPresented: Binding(get: { ledger.actionError != nil }, set: { if !$0 { ledger.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ledger.actionError ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = ledger.toast {
                LedgerToastView(toast: toast, undo: { Task { await ledger.undo() } }, close: { ledger.dismissToast(toast.id) })
                    .padding(.bottom, 18).padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.canUndo ? 8 : 4))
                        ledger.dismissToast(toast.id)
                    }
            }
        }
        .animation(.easeOut(duration: 0.18), value: ledger.toast)
    }

    private func open(_ id: String) {
        ledger.selection = id
        if compact { compactInspector = true }
    }

    private var workspace: some View {
        WorkspaceColumns(width: $inspectorWidth, fixedTrailing: true, minimumFlexible: 640, trailingCollapsed: compact) {
            VStack(spacing: 0) {
                centerHeader
                Divider()
                LedgerWorkspaceFilters(ledger: ledger, compact: width < 640)
                Divider()
                // agents waiting on a person show above every view; the Inbox shows them in full
                if ledger.page != .inbox, !ledger.inbox.prompts.isEmpty {
                    LedgerPromptStrip(prompts: ledger.inbox.prompts, ledger: ledger, compact: true, openInbox: { ledger.page = .inbox })
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider()
                }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        } trailing: {
            LedgerInspector(ledger: ledger, open: open)
        }
    }

    @ViewBuilder private var page: some View {
        switch ledger.page {
        case .inbox: LedgerInboxView(ledger: ledger, open: open)
        case .board: LedgerBoardView(ledger: ledger, open: open, showStreams: { ledger.page = .streams })
        case .graph: LedgerGraphView(ledger: ledger, open: open)
        case .streams: LedgerStreamsView(ledger: ledger, open: open)
        }
    }

    private var centerHeader: some View {
        HStack(spacing: 8) {
            LedgerViewTabs(ledger: ledger)
            Spacer(minLength: 6)
            if let error = ledger.loadError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StudioStyle.Tone.failed.text)
                    .help(error).accessibilityLabel(error)
            }
            quickLaunches
            Button { sheet = .learning } label: { Label("Learn Ledger", systemImage: "book") }
                .buttonStyle(.borderless).font(.system(size: 12)).help("Learn Ledger")
            Button { sheet = .importReports } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.borderless)
                .help("Paste reports from a conversation")
                .accessibilityLabel("Paste reports")
            Menu {
                Button("Learn Ledger") { sheet = .learning }
                Button("Bring a ChatGPT draft…") { sheet = .chatGPTDraft }
                Divider()
                Button("Connect agents…") { sheet = .connect }
                Button("Paste reports…") { sheet = .importReports }
                Button("Import from claude-ledger…") { importLegacy() }
                Divider()
                Button("Work log…") { sheet = .workLog }
                Button("Document tracker…") { sheet = .documents }
                Button("Notebook…") { sheet = .notebook }
                Button("Manage records…") { sheet = .records }
                Divider()
                Button("Back up now") { backup() }
                Button("Refresh") { Task { await ledger.reload() } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("More ledger actions")
            .accessibilityLabel("More ledger actions")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// The quick launches (DESIGN.md §2, P4): a tab in the terminal panel below the page through the panel's own
    /// newTerminal, and Claude Code the way Gitrochi's Run agent buttons start it, so Track agents I start applies
    private var quickLaunches: some View {
        let folder = store?.url?.path
        return Menu {
            Button("Ledger overview") { openOverview() }
                .help("The overview agents read: HEAD, open sessions, streams and overlaps")
            Button {
                if let folder { store?.startAgent(in: folder, kind: .claude) }
            } label: {
                Text(verbatim: AgentKind.claude.title)
            }
            .help("Start Claude Code in this repository")
        } label: {
            Image(systemName: "apple.terminal")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(folder == nil)
        .help(folder == nil ? "Open a repository to use its terminal" : "Open in the terminal")
        .accessibilityLabel("Open in the terminal")
    }

    /// `gitrochi-ledger overview` for the project shown, in a new terminal tab that keeps its text
    private func openOverview() {
        guard let store, let folder = store.url?.path else { return }
        store.newTerminal(in: folder, command: .init(program: LedgerCommandLine.bundled.path,
                                                     args: LedgerCommandLine.overviewArguments(project: ledger.project),
                                                     title: String(localized: "Ledger overview")))
    }

    private func backup() {
        Task {
            do {
                let path = try await ledger.backup()
                ledger.actionError = nil
                ledger.showNotice(String(localized: "Backed up to \(path)"))
            } catch {
                ledger.actionError = error.localizedDescription
            }
        }
    }

    private func importLegacy() {
        guard let path = LedgerLegacyImportSheet.chooseDatabase() else { return }
        legacyPath = path
        sheet = .importLegacy
    }

    private func switchSheet(to destination: Sheet) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { sheet = destination }
    }

    /// No sessions yet: what the ledger is for, and the ways to fill it
    private var onboarding: some View {
        VStack(spacing: 14) {
            WorkspaceEmptyState(title: "No reports yet", systemImage: WorkspaceDestination.ledger.symbol,
                                description: "No reports have arrived yet. Register the tools, then ask your agent to send a start report.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Connect agents…") { sheet = .connect }.buttonStyle(.borderedProminent)
                Button("Paste reports…") { sheet = .importReports }
                Button("Import from claude-ledger…") { importLegacy() }
            }
            HStack(spacing: 10) {
                Button("Learn Ledger") { sheet = .learning }
                Button("Bring a ChatGPT draft…") { sheet = .chatGPTDraft }
            }
            Text("To track new Claude Code agents launched from Gitrochi automatically, turn on Settings > Ledger > Track agents I start. It is off by default.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
