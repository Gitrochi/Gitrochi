import SwiftUI

/// Content navigation stays above the Ledger, leaving the app's sidebar as its only vertical navigation.
/// (Windows: widgets/ledger-workspace/ui/LedgerWorkspace.tsx)
struct LedgerViewTabs: View {
    let ledger: LedgerStore

    var body: some View {
        HStack(spacing: 16) {
            ForEach(LedgerPage.allCases) { page in
                let selected = ledger.page == page
                Button { ledger.page = page } label: {
                    HStack(spacing: 5) {
                        Text(page.title)
                        if let count = count(page), count > 0 {
                            Text(count > 999 ? "999+" : "\(count)")
                                .font(.system(size: 11).monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary.opacity(0.7), in: Capsule())
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views")
    }

    private func count(_ page: LedgerPage) -> Int? {
        switch page {
        case .inbox: ledger.attentionTotal
        case .board: ledger.boardRows.count
        case .streams: ledger.streamCount
        case .graph: nil
        }
    }
}

/// The former filter column is one compact toolbar; narrow windows give the filter field its own line.
/// (Windows: widgets/ledger-workspace/ui/LedgerFilters.tsx)
struct LedgerWorkspaceFilters: View {
    let ledger: LedgerStore
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 4) {
                    HStack(spacing: 8) { projectMenu; Spacer(minLength: 4); verdictMenu }
                    search
                }
            } else {
                HStack(spacing: 8) { projectMenu; search; verdictMenu }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var search: some View {
        ListSearchRow(prompt: String(localized: "Filter sessions"), text: Binding(get: { ledger.filter.text }, set: { text in
            var filter = ledger.filter
            filter.text = text
            ledger.filter = filter
            // The Inbox is not filtered: typing shows the matching sessions on the Board.
            if !text.isEmpty, ledger.page == .inbox { ledger.page = .board }
        }), filters: LedgerRange.allCases.map { ($0, $0.title) }, selection: ledger.range, defaultFilter: .week,
                      onSearch: {}, onFilter: { range in Task { await ledger.setRange(range) } })
            .frame(minWidth: 160, maxWidth: .infinity)
    }

    private var projectMenu: some View {
        let projects = ledger.state?.projects ?? []
        return Menu {
            if let mine = ledger.repositoryProject, let project = projects.first(where: { $0.key == mine }) {
                Button { Task { await ledger.resumeFollowing() } } label: {
                    menuLabel(String(localized: "This repository (\(project.name))"),
                              selected: ledger.project == mine && !ledger.projectChosen)
                }
            }
            Button { Task { await ledger.choose(project: nil) } } label: {
                menuLabel(String(localized: "All projects"), selected: ledger.project == nil)
            }
            if !projects.isEmpty { Divider() }
            ForEach(projects) { project in
                Button { Task { await ledger.choose(project: project.key) } } label: {
                    menuLabel(project.name + (project.open > 0 ? " (\(project.open))" : ""),
                              selected: ledger.project == project.key && (ledger.projectChosen || project.key != ledger.repositoryProject))
                }
            }
        } label: {
            Label(projectName, symbol: "folder").lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: 200)
        .help("Project")
        .accessibilityLabel("Project")
        .accessibilityValue(projectName)
    }

    private var projectName: String {
        guard let key = ledger.project else { return String(localized: "All projects") }
        let name = ledger.state?.projects.first { $0.key == key }?.name ?? key
        if key == ledger.repositoryProject, !ledger.projectChosen { return String(localized: "This repository (\(name))") }
        return name
    }

    private var verdictMenu: some View {
        Menu {
            Button { setVerdict(nil) } label: {
                menuLabel(String(localized: "All verdicts"), selected: ledger.filter.verdicts.isEmpty)
            }
            Divider()
            ForEach(LedgerVerdict.displayOrder, id: \.self) { verdict in
                Button { setVerdict(verdict) } label: {
                    menuLabel(verdict.title + (ledger.verdictCounts[verdict].map { $0 > 0 ? " (\($0))" : "" } ?? ""),
                              selected: ledger.filter.verdicts == [verdict])
                }
            }
        } label: {
            Label(verdictName, symbol: "line.3.horizontal.decrease.circle").lineLimit(1)
        }
        .fixedSize()
        .help("Verdicts")
        .accessibilityLabel("Verdicts")
        .accessibilityValue(verdictName)
    }

    private var verdictName: String {
        if ledger.filter.verdicts.isEmpty { return String(localized: "All verdicts") }
        if ledger.filter.verdicts.count == 1, let verdict = ledger.filter.verdicts.first { return verdict.title }
        return String(localized: "Verdicts")
    }

    private func setVerdict(_ verdict: LedgerVerdict?) {
        var filter = ledger.filter
        filter.verdicts = verdict.map { [$0] } ?? []
        ledger.filter = filter
        ledger.page = .board
    }

    @ViewBuilder private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, symbol: "checkmark") } else { Text(title) }
    }
}
