import SwiftUI

/// The Ledger page: what each agent session was for, where it stands and what a person still has to do. Filters | the
/// view | the inspector, like the repository screen; below 1,080 pt the inspector becomes a sheet and below 640 pt the
/// filter column goes above the view. It opens without a repository and shows the open repository's project.
/// (Windows: widgets/ledger-workspace/ui/LedgerWorkspace.tsx)
struct LedgerWorkspaceView: View {
    enum Sheet: String, Identifiable {
        case connect, importReports
        var id: String { rawValue }
    }

    /// The open repository, whose project the page shows; nil without one
    let repositoryPath: String?
    var ledger: LedgerStore = .shared
    @Environment(\.controlActiveState) private var activeState
    @ViewState private var width: CGFloat = 1200
    @ViewState private var compactInspector = false
    @ViewState private var sheet: Sheet?
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
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .connect: LedgerConnectSheet(ledger: ledger)
            case .importReports: LedgerImportSheet(ledger: ledger)
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
            AdaptiveWorkbenchSplit(listWidth: 230) {
                LedgerFilterColumn(ledger: ledger)
            } detail: {
                VStack(spacing: 0) {
                    centerHeader
                    Divider()
                    // agents waiting on a person show above every view; the Inbox shows them in full
                    if ledger.page != .inbox, !ledger.inbox.prompts.isEmpty {
                        LedgerPromptStrip(prompts: ledger.inbox.prompts, ledger: ledger, compact: true) { ledger.page = .inbox }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        Divider()
                    }
                    page.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            }
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
            Image(systemName: ledger.page.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(ledger.page.title).font(.headline)
            if ledger.page == .inbox, ledger.attentionTotal > 0 {
                Text("\(ledger.attentionTotal)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let name = projectName { Text("· " + name).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 6)
            if let error = ledger.loadError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
                    .help(error).accessibilityLabel(error)
            }
            Button { sheet = .importReports } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.borderless)
                .help("Paste reports from a conversation")
                .accessibilityLabel("Paste reports")
            Menu {
                Button("Connect Claude Code…") { sheet = .connect }
                Button("Paste reports…") { sheet = .importReports }
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

    private var projectName: String? {
        guard let key = ledger.project else { return nil }
        return ledger.state?.projects.first { $0.key == key }?.name ?? key
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

    /// No sessions yet: what the ledger is for, and the two ways to fill it
    private var onboarding: some View {
        VStack(spacing: 14) {
            WorkspaceEmptyState(title: "Keep track of your agent sessions", systemImage: WorkspaceDestination.ledger.symbol,
                                description: "Agents report what they started from, what they made and what they need from you. You answer, confirm and clean up here.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Connect Claude Code…") { sheet = .connect }.buttonStyle(.borderedProminent)
                Button("Paste reports…") { sheet = .importReports }
            }
            Text("Sessions you start from Gitrochi appear here by themselves.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The left column: the views, the project and the verdicts, with a filter field whose menu picks the period
private struct LedgerFilterColumn: View {
    let ledger: LedgerStore

    var body: some View {
        VStack(spacing: 0) {
            ListSearchRow(prompt: String(localized: "Filter sessions"), text: Binding(get: { ledger.filter.text }, set: { text in
                var filter = ledger.filter
                filter.text = text
                ledger.filter = filter
                // the Inbox is not filtered: typing shows the matching sessions on the Board
                if !text.isEmpty, ledger.page == .inbox { ledger.page = .board }
            }), filters: LedgerRange.allCases.map { ($0, $0.title) }, selection: ledger.range, defaultFilter: .week,
                          onSearch: {}, onFilter: { range in Task { await ledger.setRange(range) } })
                .padding(.horizontal, 8).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    title(String(localized: "Views"))
                    ForEach(LedgerPage.allCases) { page in pageRow(page) }
                    title(String(localized: "Project"))
                    projectRows
                    if !ledger.verdictCounts.isEmpty {
                        title(String(localized: "Verdicts"))
                        ForEach(LedgerVerdict.displayOrder.filter { (ledger.verdictCounts[$0] ?? 0) > 0 }, id: \.self) { verdictRow($0) }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func title(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, symbol: String, tint: Color = .secondary, count: Int? = nil, active: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(active ? Color.accentColor : tint).frame(width: 18)
                Text(title).font(.system(size: 13, weight: active ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text(count > 999 ? "999+" : "\(count)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary.opacity(0.7), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .background(active ? StudioStyle.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (count.map { $0 > 0 ? ", \($0)" : "" } ?? ""))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func pageRow(_ page: LedgerPage) -> some View {
        let count: Int? = switch page {
        case .inbox: ledger.attentionTotal
        case .streams: ledger.streamCount
        case .board: ledger.boardRows.count
        case .graph: nil
        }
        return row(page.title, symbol: page.symbol, count: count, active: ledger.page == page) { ledger.page = page }
    }

    @ViewBuilder private var projectRows: some View {
        let projects = ledger.state?.projects ?? []
        if let mine = ledger.repositoryProject, let project = projects.first(where: { $0.key == mine }) {
            row(String(localized: "This repository (\(project.name))"), symbol: "folder", count: project.open,
                active: ledger.project == mine && !ledger.projectChosen) { Task { await ledger.resumeFollowing() } }
        }
        row(String(localized: "All projects"), symbol: "square.stack", active: ledger.project == nil) { Task { await ledger.choose(project: nil) } }
        ForEach(projects) { project in
            row(project.name, symbol: "shippingbox", count: project.open, active: ledger.project == project.key && (ledger.projectChosen || project.key != ledger.repositoryProject)) {
                Task { await ledger.choose(project: project.key) }
            }
        }
    }

    private func verdictRow(_ verdict: LedgerVerdict) -> some View {
        let on = ledger.page == .board && ledger.filter.verdicts == [verdict]
        return row(verdict.title, symbol: verdict.symbol, tint: verdict.color, count: ledger.verdictCounts[verdict], active: on) {
            var filter = ledger.filter
            filter.verdicts = on ? [] : [verdict]
            ledger.filter = filter
            ledger.page = .board
        }
    }
}
