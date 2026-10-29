import SwiftUI
import AppKit

/// The Actions page's run list: GitLab pipelines or GitHub Actions runs, newest first or grouped by branch.
/// A row shows the run on the right (CIRunDetailView). (Windows: features/ci-panel/ui/CIPanel.tsx)
struct CIPanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    /// 보기: 시간순 목록 / 브랜치별(접은 브랜치는 이 창에서만 기억)
    @AppStorage("ciGroupByBranch") private var byBranch = false
    @ViewState private var collapsedRefs: Set<String> = []
    @ViewState private var scrollTarget: Int?

    var body: some View {
        if let target = store.target {
            VStack(spacing: 0) {
                header(target)
                list(target)
            }
            .task(id: "\(target.host)/\(target.path)/\(store.ciCurrentBranchOnly)") { await poll() }
            .onChange(of: AccountStore.shared.revision) { _, _ in Task { await store.loadCI() } }
            .onChange(of: store.ciFocus, initial: true) { _, _ in reveal() }
            .onChange(of: store.ciPipelines) { _, _ in reveal() }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle").font(.largeTitle).foregroundStyle(.tertiary)
                Text("You can view and run pipelines in repositories with a GitHub or GitLab remote.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 처음 읽고, 실행 중인 게 있으면 8초·없으면 45초마다 새로 고친다(고른 실행의 작업도)
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

    /// Styled like the Pull requests and Issues lists' section header
    private func header(_ target: RepoTarget) -> some View {
        HStack(spacing: 8) {
            Text(target.provider == .gitlab ? "Pipelines" : "Runs")
            if !store.ciPipelines.isEmpty { Text(verbatim: "\(store.ciPipelines.count)") }
            if store.ciState == .loading { ProgressView().controlSize(.mini) }
            Spacer()
            Menu {
                Picker("", selection: $byBranch) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("By branch", systemImage: "arrow.triangle.branch").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: byBranch ? "arrow.triangle.branch" : "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show runs as a list or grouped by branch")
            .accessibilityLabel("Show runs as a list or grouped by branch")
            Button { store.ciCurrentBranchOnly.toggle() } label: {
                Image(systemName: store.ciCurrentBranchOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .help(store.ciCurrentBranchOnly ? "Show all branches" : "Show only the current branch (\(store.ciCurrentRef ?? "-"))")
            Button { Task { await store.loadCI() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
            Button { store.sheet = .runPipeline } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .disabled(store.ciAccess == nil || store.ciBusy.contains("run"))
                .help(target.provider == .gitlab ? "Run new pipeline (branch, variables)" : "Run workflow")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func list(_ target: RepoTarget) -> some View {
        switch store.ciState {
        case .authorizationRequired:
            if let account = store.pendingCredentialAccount {
                CredentialAccessNotice(account: account)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .needsAccount:
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect a \(target.provider == .gitlab ? String(localized: "Self-hosted GitLab (\(target.host))") : "GitHub") account to see pipelines.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Connect account…") { openSettings() }.buttonStyle(.link)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed(let m):
            VStack(alignment: .leading, spacing: 8) {
                Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { Task { await store.loadCI() } }.buttonStyle(.link)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .loaded where store.ciPipelines.isEmpty:
            Text(store.ciCurrentBranchOnly ? "No runs for this branch." : "No runs yet.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if byBranch {
                            ForEach(CIBranchGroup.group(store.ciPipelines)) { g in
                                branchHeader(g)
                                if !collapsedRefs.contains(g.ref) {
                                    ForEach(g.pipelines) { p in row(p, target: target, showRef: false).padding(.leading, 14) }
                                }
                            }
                        } else {
                            ForEach(store.ciPipelines) { p in row(p, target: target, showRef: true) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .onChange(of: scrollTarget, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    scrollTarget = nil
                }
            }
        }
    }

    private func row(_ p: CIPipeline, target: RepoTarget, showRef: Bool) -> some View {
        PipelineRow(pipeline: p, provider: target.provider, showRef: showRef)
            .sidebarRow()
            .background(store.ciSelected == p.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { store.selectRun(p) }
            .focusable()
            .onKeyPress(.return) { store.selectRun(p); return .handled }
            .onKeyPress(.space) { store.selectRun(p); return .handled }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(store.ciSelected == p.id ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { store.selectRun(p) }
            .id(p.id)
    }

    private func branchHeader(_ g: CIBranchGroup) -> some View {
        let open = !collapsedRefs.contains(g.ref)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 0 : -90))
                .frame(width: 10)
            CIStatusIcon(status: g.pipelines[0].status, size: 11)
            Text(g.ref).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(verbatim: "\(g.pipelines.count)").font(.caption).foregroundStyle(.secondary)
        }
        .sidebarRow()
        .contentShape(Rectangle())
        .onTapGesture { if open { collapsedRefs.insert(g.ref) } else { collapsedRefs.remove(g.ref) } }
        .help("\(g.ref) · \(g.pipelines[0].status.title)")
    }

    /// A commit's CI icon asked for this pipeline: open its branch group, select the run and bring it into view
    private func reveal() {
        guard let id = store.ciFocus, let p = store.ciPipelines.first(where: { $0.id == id }) else { return }
        collapsedRefs.remove(p.ref)
        store.selectRun(p)
        scrollTarget = id
        store.ciFocus = nil
    }
}

/// 파이프라인 한 줄: 상태 · 제목 · 브랜치 · 시간. 버튼은 오른쪽 상세와 우클릭 메뉴에 있다.
private struct PipelineRow: View {
    @Environment(RepoStore.self) private var store
    let pipeline: CIPipeline
    let provider: Provider
    /// 브랜치별 보기에서는 묶음 머리에 브랜치가 있으니 줄마다 다시 적지 않는다
    var showRef = true

    var body: some View {
        let p = pipeline
        let manual = (store.ciJobs[p.id] ?? []).filter(\.canPlay).count
        HStack(alignment: .center, spacing: 6) {
            CIStatusIcon(status: p.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.ciTitle(p)).fontWeight(.medium).lineLimit(2)
                Text(p.status.title).font(.caption2).foregroundStyle(p.status.color)
                HStack(spacing: 4) {
                    if provider == .github, !p.name.isEmpty { Text(p.name).lineLimit(1) }
                    Text("#\(p.number)").monospacedDigit()
                    if showRef { Text(p.ref).font(.caption.monospaced()).lineLimit(1) }
                    if let d = p.created { Text(Fmt.short(d)).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if manual > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "play.fill")
                    Text(verbatim: "\(manual)")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .help("\(manual) jobs waiting to be run manually")
            }
            if store.ciBusy.contains("pipeline:\(p.id)") { ProgressView().controlSize(.mini) }
        }
        .contextMenu { CIRunMenu(pipeline: p, provider: provider) }
    }
}

/// The run's commands, for the list's context menu
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
                Image(systemName: status.symbol)
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
