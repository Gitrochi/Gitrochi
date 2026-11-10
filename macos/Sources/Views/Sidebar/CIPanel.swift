import SwiftUI
import AppKit

/// The Actions page's list column, as the Actions board draws it: search with the sort and filter menu (order, all
/// branches or this one, grouping), the segments that count what failed, runs or waits, and two-line rows.
/// A row shows the run on the right (CIRunDetailView). (Windows: features/ci-panel/ui/CIPanel.tsx)
struct CIPanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.locale) private var locale
    /// Rows in one list, or under their branches (the folded branches are remembered for this window only)
    @AppStorage("ciGroupByBranch") private var byBranch = false
    @AppStorage("ciOldestFirst") private var oldestFirst = false
    @ViewState private var collapsedRefs: Set<String> = []
    @ViewState private var scrollTarget: Int?
    @ViewState private var search = ""
    @ViewState private var segment = ActionsPage.Segment.all

    private var host: String { store.target?.host ?? "" }

    var body: some View {
        @Bindable var store = store
        let target = store.target
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let message) = store.ciState, !store.ciPipelines.isEmpty {
                FailureBlock(title: String(localized: "Couldn't reach \(host)"), caption: hostedListAge(store.ciLoadedAt, locale: locale), detail: message) {
                    Task { await store.loadCI() }
                }
            }
            HostedListSearch(prompt: String(localized: "Search runs"), text: $search, menuTitle: menuTitle) {
                Picker("Sort", selection: $oldestFirst) {
                    Text("Newest first").tag(false)
                    Text("Oldest first").tag(true)
                }
                .pickerStyle(.inline)
                // the branch filter lives here, not in a control of its own
                Picker("Branch", selection: $store.ciCurrentBranchOnly) {
                    Text("All branches").tag(false)
                    Text(verbatim: store.ciCurrentRef ?? String(localized: "Current branch")).tag(true)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Group by branch", isOn: $byBranch)
            }
            HostedListSegments(options: ActionsPage.Segment.allCases.map { segment in
                (value: segment, title: Self.title(segment), count: count(segment))
            }, selection: segment) { segment = $0 }
            if let target { list(target) }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run list")
        .onChange(of: store.ciSelected, initial: true) { _, id in show(id) }
    }

    private var menuTitle: String {
        let order = oldestFirst ? String(localized: "Oldest first") : String(localized: "Newest first")
        let branch = store.ciCurrentBranchOnly ? store.ciCurrentRef ?? String(localized: "Current branch") : String(localized: "All branches")
        return String(localized: "Sort and filter") + ": " + order + ", " + branch
    }

    private static func title(_ segment: ActionsPage.Segment) -> String {
        switch segment {
        case .all: return String(localized: "All")
        case .failed: return String(localized: "Failed")
        case .running: return String(localized: "Running")
        case .waiting: return String(localized: "Waiting")
        }
    }

    /// Failed, Running and Waiting count what they hold; All never does, and nothing counts zero
    private func count(_ segment: ActionsPage.Segment) -> String? {
        guard segment != .all else { return nil }
        let count = ActionsPage.count(store.ciPipelines, segment)
        return count > 0 ? String(count) : nil
    }

    @ViewBuilder
    private func list(_ target: RepoTarget) -> some View {
        let runs = ActionsPage.visible(store.ciPipelines, segment: segment, search: search, oldestFirst: oldestFirst, title: store.ciTitle)
        if store.ciPipelines.isEmpty {
            switch store.ciState {
            case .failed(let message):
                HostedListEmpty(symbol: "xmark.circle.fill", title: String(localized: "Couldn't reach \(host)"), caption: message,
                                actionTitle: String(localized: "Retry"), failed: true) { Task { await store.loadCI() } }
            case .loaded:
                HostedListEmpty(symbol: "play.circle",
                                title: store.ciCurrentBranchOnly ? String(localized: "No runs for this branch.") : String(localized: "No runs yet."),
                                actionTitle: store.ciCurrentBranchOnly ? String(localized: "Show all branches") : nil) { store.ciCurrentBranchOnly = false }
            default:
                HostedListLoading(caption: String(localized: "Loading runs…"))
                Spacer(minLength: 0)
            }
        } else if runs.isEmpty {
            HostedListEmpty(symbol: "magnifyingglass", title: String(localized: "No runs match this filter."),
                            actionTitle: search.isEmpty ? String(localized: "Show all runs") : String(localized: "Clear search")) {
                search = ""
                segment = .all
            }
        } else {
            let common = ActionsPage.commonWorkflow(store.ciPipelines)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if byBranch {
                            ForEach(CIBranchGroup.group(runs)) { g in
                                branchHeader(g)
                                if !collapsedRefs.contains(g.ref) {
                                    ForEach(g.pipelines) { p in row(p, target: target, showRef: false, common: common).padding(.leading, 14) }
                                }
                            }
                        } else {
                            ForEach(runs) { p in row(p, target: target, showRef: true, common: common) }
                        }
                    }
                }
                .onChange(of: scrollTarget, initial: true) { _, id in
                    guard let id else { return }
                    // no anchor: a row already in view stays where it is
                    withAnimation { proxy.scrollTo(id) }
                    scrollTarget = nil
                }
            }
        }
    }

    private func row(_ p: CIPipeline, target: RepoTarget, showRef: Bool, common: String?) -> some View {
        let selected = store.ciSelected == p.id
        let secondary = HostedList.secondary(selected: selected)
        let manual = (store.ciJobs[p.id] ?? []).filter(\.canPlay).count
        // a waiting run says so in words, so it carries no separate status icon
        let waiting = ActionsPage.segment(p.status) == .waiting || manual > 0
        return HostedListRow(selected: selected) { store.selectRun(p) } content: {
            HostedListRowTitle(title: store.ciTitle(p), when: p.created.map { ListDate.when($0, locale: locale) }, selected: selected)
            HStack(spacing: 6) {
                // the usual workflow goes without saying; any other one is named before the run
                (Text(verbatim: p.name.isEmpty || p.name == common ? "" : p.name + " · ") + Text(verbatim: ciRunName(p, target.provider)).font(.system(size: 11, design: .monospaced)))
                    .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1).fixedSize()
                if waiting {
                    HostedListChip(title: String(localized: "Waiting"), symbol: "clock", selected: selected, tone: .waiting)
                        .help(manual > 0 ? String(localized: "\(manual) jobs waiting to be run manually") : p.status.title)
                } else {
                    CIStatusIcon(status: p.status, size: 11)
                }
                if store.ciBusy.contains("pipeline:\(p.id)") { ProgressView().controlSize(.mini) }
                Spacer(minLength: 6)
                // the run is never cut; the branch gives way, from the front
                if showRef { Text(verbatim: p.ref).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1).truncationMode(.head) }
            }
        }
        .contextMenu { CIRunMenu(pipeline: p, provider: target.provider) }
        .accessibilityAction { store.selectRun(p) }
        .id(p.id)
    }

    private func branchHeader(_ g: CIBranchGroup) -> some View {
        let open = !collapsedRefs.contains(g.ref)
        return Button { if open { collapsedRefs.insert(g.ref) } else { collapsedRefs.remove(g.ref) } } label: {
            HStack(spacing: 6) {
                DesignIconImage(icon: .chevronDown)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(HostedList.caption)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .frame(width: 10)
                CIStatusIcon(status: g.pipelines[0].status, size: 11)
                Text(verbatim: g.ref).font(.system(size: 13)).lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(g.ref) · \(g.pipelines[0].status.title)")
    }

    /// The run the page selected (a row, or a commit's CI icon): open its branch group, drop a filter that hides it and
    /// bring it into view
    private func show(_ id: Int?) {
        guard let id, let p = store.ciPipelines.first(where: { $0.id == id }) else { return }
        collapsedRefs.remove(p.ref)
        if !ActionsPage.visible(store.ciPipelines, segment: segment, search: search, oldestFirst: oldestFirst, title: store.ciTitle).contains(where: { $0.id == id }) {
            search = ""
            segment = .all
        }
        scrollTarget = id
    }
}

/// Runs are written "run #318", never a bare number (docs/design.md, Text); GitLab calls them pipelines
func ciRunName(_ p: CIPipeline, _ provider: Provider) -> String {
    provider == .gitlab ? String(localized: "pipeline #\(String(p.number))") : String(localized: "run #\(String(p.number))")
}

extension CIStatus {
    /// The tone a status badge takes; a status never uses the accent
    var tone: StudioStyle.Tone {
        switch self {
        case .success: return .passed
        case .failed: return .failed
        case .created, .waiting, .pending, .running, .manual, .scheduled: return .waiting
        case .canceled, .skipped, .neutral, .unknown: return .neutral
        }
    }
}

/// The run's commands, for the list's context menu and the detail's More menu
struct CIRunMenu: View {
    @Environment(RepoStore.self) private var store
    let pipeline: CIPipeline
    let provider: Provider

    var body: some View {
        let p = pipeline
        Button("Open in browser") { open(p.url) }
        Button("View commit") { store.reveal(p.sha) }
        Divider()
        if p.status.isActive {
            Button("Cancel run") { store.cancelPipeline(p) }
        } else if provider == .github {
            Button("Rerun all jobs") { Task { await store.retryPipeline(p, failedOnly: false) } }
            Button("Rerun failed jobs only") { Task { await store.retryPipeline(p, failedOnly: true) } }
                .disabled(p.status != .failed && p.status != .canceled)
        } else {
            Button("Rerun failed and canceled jobs") { Task { await store.retryPipeline(p, failedOnly: true) } }
                .disabled(p.status != .failed && p.status != .canceled)
        }
        Divider()
        Button("Copy link") { store.copy(p.url) }
    }
}

/// 파이프라인·작업 상태 아이콘(실행 중이면 도는 표시) — 그래프·PR 목록에서도 쓴다
struct CIStatusIcon: View {
    let status: CIStatus
    var size: CGFloat = 13

    var body: some View {
        Group {
            if status == .running {
                ProgressView().controlSize(.mini).frame(width: size + 2, height: size + 2)
            } else {
                SymbolIcon(status.symbol)
                    .font(.system(size: size))
                    .foregroundStyle(status.color)
                    .frame(width: size + 2, height: size + 2)
            }
        }
        .help(status.title)
    }
}

private func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}
