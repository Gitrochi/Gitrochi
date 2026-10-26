import SwiftUI
import AppKit

/// GitLab 파이프라인·GitHub Actions 실행 목록. 수동 작업 ▶ 실행, 다시 실행, 취소, 배포 승인.
struct CIPanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewState private var expanded: Set<Int> = []
    /// 보기: 시간순 목록 / 브랜치별(접은 브랜치는 이 창에서만 기억)
    @AppStorage("ciGroupByBranch") private var byBranch = false
    @ViewState private var collapsedRefs: Set<String> = []
    @ViewState private var scrollTarget: Int?

    var body: some View {
        if let target = store.target {
            VStack(spacing: 0) {
                header(target)
                Divider()
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

    /// 처음 읽고, 실행 중인 게 있으면 8초·없으면 45초마다 새로 고친다(펼친 파이프라인의 작업도)
    private func poll() async {
        await store.loadCI()
        while !Task.isCancelled {
            let active = store.ciPipelines.contains { $0.status.isActive }
            try? await Task.sleep(for: .seconds(active ? 8 : 45))
            if Task.isCancelled { break }
            await store.loadCI(silent: true)
            for p in store.ciPipelines where expanded.contains(p.id) && (p.status.isActive || store.ciJobs[p.id] == nil) {
                await store.loadJobs(p, silent: true)
            }
        }
    }

    private func header(_ target: RepoTarget) -> some View {
        HStack(spacing: 8) {
            Text(target.provider == .gitlab ? "Pipelines" : "Actions")
                .font(.subheadline.weight(.semibold))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            List {
                if byBranch {
                    ForEach(CIBranchGroup.group(store.ciPipelines)) { g in
                        Section(isExpanded: branchExpansion(g.ref)) {
                            ForEach(g.pipelines) { p in pipelineItem(p, target: target, showRef: false) }
                        } header: {
                            HStack(spacing: 6) {
                                CIStatusIcon(status: g.pipelines[0].status, size: 11)
                                Text(g.ref).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(g.pipelines.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            .help("\(g.ref) · \(g.pipelines[0].status.title)")
                        }
                    }
                } else {
                    ForEach(store.ciPipelines) { p in pipelineItem(p, target: target, showRef: true) }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: scrollTarget, initial: true) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                scrollTarget = nil
            }
            }
        }
    }

    /// A commit's CI icon asked for this pipeline: open its branch group and the run, then bring it into view
    private func reveal() {
        guard let id = store.ciFocus, let p = store.ciPipelines.first(where: { $0.id == id }) else { return }
        collapsedRefs.remove(p.ref)
        expanded.insert(id)
        Task { await store.loadJobs(p) }
        scrollTarget = id
        store.ciFocus = nil
    }

    private func pipelineItem(_ p: CIPipeline, target: RepoTarget, showRef: Bool) -> some View {
        DisclosureGroup(isExpanded: expansion(p)) {
            PipelineJobs(pipeline: p)
        } label: {
            PipelineRow(pipeline: p, provider: target.provider, showRef: showRef) { expanded.insert(p.id); Task { await store.loadJobs(p) } }
        }
        .id(p.id)
    }

    private func branchExpansion(_ ref: String) -> Binding<Bool> {
        Binding(get: { !collapsedRefs.contains(ref) }, set: { open in
            if open { collapsedRefs.remove(ref) } else { collapsedRefs.insert(ref) }
        })
    }

    private func expansion(_ p: CIPipeline) -> Binding<Bool> {
        Binding(get: { expanded.contains(p.id) }, set: { open in
            if open {
                expanded.insert(p.id)
                Task { await store.loadJobs(p) }
            } else {
                expanded.remove(p.id)
            }
        })
    }
}

/// 파이프라인 한 줄: 상태 · 제목 · 브랜치 · 시간, 오른쪽에 취소·다시 실행
private struct PipelineRow: View {
    @Environment(RepoStore.self) private var store
    let pipeline: CIPipeline
    let provider: Provider
    /// 브랜치별 보기에서는 묶음 머리에 브랜치가 있으니 줄마다 다시 적지 않는다
    var showRef = true
    let expand: () -> Void

    private var title: String {
        if !pipeline.title.isEmpty { return pipeline.title }
        if let i = store.commitIndex[pipeline.sha] { return store.entries[i].commit.subject }
        return pipeline.name.isEmpty ? String(pipeline.sha.prefix(8)) : pipeline.name
    }

    var body: some View {
        let p = pipeline
        let manual = (store.ciJobs[p.id] ?? []).filter(\.canPlay).count
        HStack(alignment: .center, spacing: 6) {
            CIStatusIcon(status: p.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
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
                Button(action: expand) {
                    HStack(spacing: 2) {
                        Image(systemName: "play.fill")
                        Text("\(manual)")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("\(manual) jobs waiting to be run manually — expand to run")
            }
            if store.ciBusy.contains("pipeline:\(p.id)") {
                ProgressView().controlSize(.mini)
            } else if p.status.isActive {
                Button { store.cancelPipeline(p) } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless)
                    .help("Cancel run")
            } else if p.status == .failed || p.status == .canceled {
                Button { Task { await store.retryPipeline(p, failedOnly: true) } } label: { Image(systemName: "arrow.clockwise.circle") }
                    .buttonStyle(.borderless)
                    .help(provider == .gitlab ? "Rerun failed and canceled jobs" : "Rerun failed jobs only")
            }
        }
        .contextMenu {
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
}

/// 펼친 파이프라인: 배포 승인 + 단계별 작업
private struct PipelineJobs: View {
    @Environment(RepoStore.self) private var store
    let pipeline: CIPipeline

    var body: some View {
        if let jobs = store.ciJobs[pipeline.id] {
            if let deps = store.ciDeployments[pipeline.id], !deps.isEmpty {
                DeploymentApproval(pipeline: pipeline, deployments: deps)
            }
            if jobs.isEmpty {
                Text("No jobs").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(stages(jobs), id: \.0) { stage, list in
                if !stage.isEmpty {
                    Text(stage).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        .padding(.top, 2)
                }
                ForEach(list) { j in JobRow(job: j, pipeline: pipeline) }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func stages(_ jobs: [CIJob]) -> [(String, [CIJob])] {
        var order: [String] = []
        var map: [String: [CIJob]] = [:]
        for j in jobs {
            if map[j.stage] == nil { order.append(j.stage) }
            map[j.stage, default: []].append(j)
        }
        return order.map { ($0, map[$0]!) }
    }
}

private struct JobRow: View {
    @Environment(RepoStore.self) private var store
    let job: CIJob
    let pipeline: CIPipeline

    private var provider: Provider { store.target?.provider ?? .gitlab }

    var body: some View {
        HStack(spacing: 6) {
            CIStatusIcon(status: job.status, size: 11)
            Text(job.name).lineLimit(1).truncationMode(.middle)
            if job.allowFailure, job.status == .failed {
                Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange).help("Allowed to fail")
            }
            Spacer(minLength: 0)
            if let d = job.duration, d > 0 {
                Text(duration(d)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            actions
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(job.url) }
        .contextMenu {
            Button("View log (browser)") { open(job.url) }
            if job.canPlay, provider == .gitlab { Button("Run") { store.playJob(job, in: pipeline) } }
            if canRetry { Button("Run again") { Task { await store.retryJob(job, in: pipeline) } } }
            if job.status.isActive, provider == .gitlab { Button("Cancel") { Task { await store.cancelJob(job, in: pipeline) } } }
            Divider()
            Button("Copy link") { store.copy(job.url) }
        }
        .help(job.status.title)
    }

    private var canRetry: Bool {
        switch provider {
        case .gitlab: return [.failed, .canceled, .success].contains(job.status)
        case .github: return job.status.isFinished && !pipeline.status.isActive
        }
    }

    @ViewBuilder private var actions: some View {
        if store.ciBusy.contains("job:\(job.id)") {
            ProgressView().controlSize(.mini)
        } else if job.canPlay, provider == .gitlab {
            Button { store.playJob(job, in: pipeline) } label: { Image(systemName: "play.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help(job.status == .scheduled ? "Run now (don't wait for the schedule)" : "Run manual job")
        } else if job.status.isActive, provider == .gitlab {
            Button { Task { await store.cancelJob(job, in: pipeline) } } label: { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless)
                .help("Cancel job")
        } else if canRetry, job.status != .success {
            Button { Task { await store.retryJob(job, in: pipeline) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Rerun job")
        }
    }

    private func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? String(localized: "\(t / 60)m \(t % 60)s") : String(localized: "\(t)s")
    }
}

/// GitHub 환경 보호 규칙: 배포 승인 대기
private struct DeploymentApproval: View {
    @Environment(RepoStore.self) private var store
    let pipeline: CIPipeline
    let deployments: [CIDeployment]

    var body: some View {
        let mine = deployments.filter(\.canApprove)
        VStack(alignment: .leading, spacing: 6) {
            Label("Waiting for deployment approval: \(deployments.map(\.environment).joined(separator: ", "))", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if mine.isEmpty {
                Text("This account can't approve.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Approve") { store.reviewDeployment(pipeline, mine, approve: true) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Reject") { store.reviewDeployment(pipeline, mine, approve: false) }
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
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
