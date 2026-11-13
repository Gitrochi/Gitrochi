import SwiftUI

/// Actions, as the redesign's Actions board draws it: where the page is and its actions, how this branch's runs went,
/// then the run list and the selected run with its jobs and a job's log beside it. The page fills the window; only the
/// list column keeps its width. (Windows: widgets/workspace-panels/ui/WorkspacePanels.tsx › ActionsWorkspacePanel)
struct ActionsWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var width: CGFloat = 1000

    private var compact: Bool { width < HostedList.compact }
    private var run: CIPipeline? { store.ciPipelines.first { $0.id == store.ciSelected } }
    private var blocked: Bool { store.ciState == .needsAccount || store.ciState == .authorizationRequired }

    var body: some View {
        Group {
            if let target = store.target {
                VStack(spacing: 0) {
                    HostedListHeader(target: target) {
                        Button { Task { await store.loadCI() } } label: { Label("Refresh", symbol: "arrow.clockwise") }
                            .buttonStyle(HostedListButtonStyle(iconOnly: true))
                            .disabled(store.ciState == .loading)
                            .help("Refresh")
                        Button { store.sheet = .runPipeline } label: {
                            Label(target.provider == .gitlab ? String(localized: "Run pipeline…") : String(localized: "Run workflow…"), symbol: "play.fill")
                        }
                        .buttonStyle(HostedListButtonStyle())
                        .disabled(store.ciAccess == nil || store.ciBusy.contains("run"))
                        .help(target.provider == .gitlab ? "Run new pipeline (branch, variables)" : "Run workflow")
                    }
                    if blocked {
                        HostedAccountNeeded(target: target) { Task { await store.loadCI() } }
                    } else {
                        RunSummaryCard(compact: compact)
                        Divider()
                        columns(target)
                    }
                }
                .task(id: "\(target.host)/\(target.path)/\(store.ciCurrentBranchOnly)") { await poll() }
                .onChange(of: AccountStore.shared.revision) { _, _ in Task { await store.loadCI() } }
                .onChange(of: store.ciFocus, initial: true) { _, _ in focus() }
                .onChange(of: store.ciPipelines) { _, _ in focus() }
            } else {
                HostedListEmpty(symbol: "globe", title: String(localized: "No hosting remote"),
                                caption: String(localized: "Open a repository with a GitHub or GitLab remote to use this workspace."),
                                actionTitle: String(localized: "Open repository…"), filled: true) { store.presentOpenPanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // the page is the surface colour, as the board draws it; the list column is a shade off it
        .background(StudioStyle.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The list and the run side by side; in a narrow window choosing a row replaces the list with the run
    private func columns(_ target: RepoTarget) -> some View {
        HStack(spacing: 0) {
            if !(compact && run != nil) {
                CIPanel()
                    .frame(width: compact ? nil : HostedList.column)
                    .frame(maxWidth: compact ? .infinity : nil, maxHeight: .infinity, alignment: .top)
                    .background(StudioStyle.canvas)
                if !compact { Divider() }
            }
            if !compact || run != nil {
                Group {
                    if let run {
                        VStack(spacing: 0) {
                            if compact {
                                HStack {
                                    Button { store.ciSelected = nil } label: { Label("Back to runs", symbol: "chevron.left") }
                                        .buttonStyle(HostedListButtonStyle())
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                Divider()
                            }
                            CIRunDetailView(pipeline: run)
                        }
                    } else {
                        let latest = ActionsPage.history(store.ciPipelines, ref: store.ciCurrentRef).last
                        HostedListEmpty(symbol: "sidebar.right", title: String(localized: "Select a run"),
                                        caption: String(localized: "Choose a run to see its jobs and read their logs."),
                                        actionTitle: latest == nil ? nil : String(localized: "Show this branch's latest run"), filled: true) {
                            if let latest { store.selectRun(latest) }
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Reads the runs, then again every 8 seconds while one is active and every 45 otherwise (the selected run's jobs too)
    private func poll() async {
        await store.loadCI()
        while !Task.isCancelled {
            let active = store.ciPipelines.contains { $0.status.isActive }
            try? await Task.sleep(for: .seconds(active ? 8 : 45))
            if Task.isCancelled { break }
            await store.loadCI(silent: true)
            if let p = store.ciPipelines.first(where: { $0.id == store.ciSelected }), p.status.isActive || store.ciJobs[p.id] == nil {
                await store.loadJobs(p, silent: true)
            }
        }
    }

    /// A commit's CI icon asked for this run: select it once the list has it; the list column brings it into view
    private func focus() {
        guard let id = store.ciFocus, let p = store.ciPipelines.first(where: { $0.id == id }) else { return }
        store.selectRun(p)
        store.ciFocus = nil
    }
}

/// How this branch's latest runs went, oldest to newest, and what the newest one needs
private struct RunSummaryCard: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.locale) private var locale
    let compact: Bool

    private var provider: Provider { store.target?.provider ?? .github }

    var body: some View {
        let ref = store.ciCurrentRef
        let history = ActionsPage.history(store.ciPipelines, ref: ref)
        let streak = ActionsPage.streak(history)
        let name = ref ?? store.headBranch ?? String(localized: "Detached HEAD")
        let card = ActionsPage.summaryCard(history: history.count, runs: store.ciPipelines.count,
                                           loading: store.ciState == .loading || store.ciState == .idle, loaded: store.ciState == .loaded)
        HostedListSummary(compact: compact) {
            HostedListSummaryCaption(text: String(localized: "This branch"))
            // a branch name is cut from the front, where it says least
            Text(verbatim: name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.head)
            if card == .loading {
                HostedListSummaryLoadingLine(caption: String(localized: "Loading runs…"))
            } else if let base = baseRun(ref) {
                HStack(spacing: 6) {
                    CIStatusIcon(status: base.status, size: 11)
                    HostedListSummaryCaption(text: base.status == .success
                        ? String(localized: "\(base.ref) passes on \(ciRunName(base, provider))")
                        : String(localized: "\(base.ref) fails on \(ciRunName(base, provider))"))
                }
            }
        } middle: {
            switch card {
            case .loading: HostedListSummaryBars()
            case .empty: HostedListSummaryMessage(title: String(localized: "No runs on this branch yet"))
            case .unknown: Color.clear
            case .runs:
                VStack(spacing: 8) {
                    if let label = label(streak) {
                        Text(verbatim: label.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(label.1.text).lineLimit(1)
                    }
                    // as many of the latest runs as fit, the newest always among them
                    ViewThatFits(in: .horizontal) {
                        ForEach([3, 2, 1], id: \.self) { count in track(Array(history.suffix(count))) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(streak)?.0 ?? "")
            }
        } trail: {
            if card == .loading { HostedListSummaryBar() } else { trail(streak, history: history) }
        } strip: {
            if card == .loading { ProgressView().controlSize(.mini) } else if let latest = history.last { CIStatusIcon(status: latest.status, size: 13) }
            Text(verbatim: name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.head)
            if let label = label(streak) {
                Text(verbatim: label.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(label.1.text).lineLimit(1).layoutPriority(1)
            } else if card == .loading {
                HostedListSummaryCaption(text: String(localized: "Loading runs…"))
            } else if card == .empty {
                HostedListSummaryCaption(text: String(localized: "No runs on this branch yet"))
            }
            Spacer(minLength: 8)
            if case .failed(let run) = streak { showRun(run) }
            else if let latest = history.last { HostedListSummaryCaption(text: ciRunName(latest, provider)) }
        }
        .accessibilityLabel("This branch's runs")
        // the summary counts the latest run's jobs, which the list alone does not load
        .task(id: history.last?.id) {
            if let latest = history.last, store.ciJobs[latest.id] == nil { await store.loadJobs(latest) }
        }
    }

    /// The newest finished run of the branch runs are compared with, unless this is that branch
    private func baseRun(_ ref: String?) -> CIPipeline? {
        guard let base = ActionsPage.baseRef(store.localBranches.map(\.name) + store.remoteBranches.map(\.shortName)), base != ref else { return nil }
        return store.ciPipelines.first { $0.ref == base && ($0.status == .success || $0.status == .failed) }
    }

    /// What the newest run says, in its tone; the icon beside each run says it too
    private func label(_ streak: ActionsPage.Streak) -> (String, StudioStyle.Tone)? {
        switch streak {
        case .none: return nil
        case .passing(let count): return (count == 1 ? String(localized: "Passing for 1 run") : String(localized: "Passing for \(count) runs"), .passed)
        case .failed(let run):
            let job = store.ciJobs[run.id]?.first { $0.status == .failed && !$0.allowFailure }?.name
            return (String(localized: "Failed on \(ciRunName(run, provider))") + (job.map { " · " + $0 } ?? ""), .failed)
        case .running(let run):
            guard let jobs = store.ciJobs[run.id], !jobs.isEmpty else { return (String(localized: "Running"), .waiting) }
            return (String(localized: "Running · \(jobs.filter(\.status.isFinished).count) of \(jobs.count) jobs done"), .waiting)
        case .waiting: return (String(localized: "Waiting"), .waiting)
        }
    }

    @ViewBuilder private func trail(_ streak: ActionsPage.Streak, history: [CIPipeline]) -> some View {
        switch streak {
        case .failed(let run):
            showRun(run)
            if let took = ActionsPage.took(run) { HostedListSummaryCaption(text: String(localized: "Failed after \(ciDuration(took))")) }
        case .waiting(let run):
            showRun(run)
        case .running(let run):
            if let start = run.started ?? run.created {
                HostedListSummaryCaption(text: String(localized: "Started \(ListDate.when(start, locale: locale))"))
            }
        case .passing, .none:
            if let latest = history.last {
                HostedListSummaryCaption(text: latestFacts(latest).joined(separator: " · "))
            }
        }
    }

    /// "Latest run · 6 of 6 jobs · 6m 12s", with the jobs and the time only when they are known
    private func latestFacts(_ run: CIPipeline) -> [String] {
        var facts = [String(localized: "Latest run")]
        if let jobs = store.ciJobs[run.id], !jobs.isEmpty {
            let passed = jobs.filter { $0.status == .success }.count
            facts.append(String(localized: "\(passed) of \(jobs.count) jobs"))
        }
        if let took = ActionsPage.took(run) { facts.append(ciDuration(took)) }
        return facts
    }

    private func showRun(_ run: CIPipeline) -> some View {
        Button("Show run") { store.selectRun(run) }.buttonStyle(HostedListButtonStyle())
    }

    /// The runs as nodes on a line, each with its status icon and its number; the newest is the dark one
    private func track(_ runs: [CIPipeline]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                VStack(spacing: 4) {
                    CIStatusIcon(status: run.status, size: 13).frame(height: 16)
                    Text(verbatim: ciRunName(run, provider))
                        .font(.system(size: 11, weight: index == runs.count - 1 ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(index == runs.count - 1 ? Color.primary : HostedList.caption)
                        .lineLimit(1).fixedSize()
                }
                .frame(minWidth: 64, maxWidth: .infinity)
            }
        }
        // the line joins the icons' middles and stops short of each icon; the way to a run still going is dashed
        .background(alignment: .top) {
            GeometryReader { geometry in
                let step = geometry.size.width / CGFloat(max(1, runs.count))
                ForEach(Array(runs.enumerated()).dropFirst(), id: \.element.id) { index, run in
                    let active = run.status.isActive
                    Path { path in
                        path.move(to: CGPoint(x: step * (CGFloat(index) - 0.5) + 12, y: 8))
                        path.addLine(to: CGPoint(x: step * (CGFloat(index) + 0.5) - 12, y: 8))
                    }
                    .stroke(active ? StudioStyle.Tone.waiting.text : Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 2, dash: active ? [4, 3] : []))
                }
            }
        }
    }
}
