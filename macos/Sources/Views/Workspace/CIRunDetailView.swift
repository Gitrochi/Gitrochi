import SwiftUI
import AppKit

/// The run picked on the Actions page: its summary and commands on top, the jobs by stage on the left and the picked
/// job's log on the right, as on GitHub's run page. (Windows: features/ci-panel/ui/CIRunDetail.tsx)
struct CIRunDetailView: View {
    @Environment(RepoStore.self) private var store
    let pipeline: CIPipeline
    @ViewState private var job: Int?
    /// The run whose failed job was already opened once; closing that log keeps it closed
    @ViewState private var autoOpened: Int?

    private var provider: Provider { store.target?.provider ?? .gitlab }
    private var jobs: [CIJob]? { store.ciJobs[pipeline.id] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            AdaptiveWorkbenchSplit(listWidth: 280) {
                ScrollView { jobList.padding(8) }
                    .background(Color(nsColor: .windowBackgroundColor))
            } detail: {
                if let selected = jobs?.first(where: { $0.id == job }) {
                    CIJobLogView(job: selected) { job = nil }
                } else {
                    Group {
                        if jobs?.isEmpty == false { Text("Choose a job to read its log here.") }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
        .onChange(of: pipeline.id) { _, _ in job = nil; openFailedJob() }
        .onChange(of: jobs, initial: true) { _, _ in openFailedJob() }
    }

    /// A failed run opens on its first failed job, where the reason usually is
    private func openFailedJob() {
        guard autoOpened != pipeline.id, let jobs else { return }
        autoOpened = pipeline.id
        if job == nil, let failed = jobs.first(where: { $0.status == .failed && !$0.allowFailure }) { job = failed.id }
    }

    private var header: some View {
        HStack(spacing: 6) {
            CIStatusIcon(status: pipeline.status)
            Text(provider == .gitlab ? "Pipeline #\(pipeline.number)" : "Run #\(pipeline.number)").font(.headline)
            Text(pipeline.status.title).foregroundStyle(.secondary)
            Spacer()
            if store.ciBusy.contains("pipeline:\(pipeline.id)") { ProgressView().controlSize(.small) }
            Button { Task { await store.loadJobs(pipeline) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.ciTitle(pipeline)).font(.title3.weight(.semibold)).textSelection(.enabled)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                if provider == .github, !pipeline.name.isEmpty {
                    GridRow { Text("Workflow").foregroundStyle(.secondary); Text(pipeline.name) }
                }
                GridRow { Text("Branch").foregroundStyle(.secondary); Text(pipeline.ref).monospaced().textSelection(.enabled) }
                GridRow {
                    Text("Commit").foregroundStyle(.secondary)
                    Button { store.reveal(pipeline.sha) } label: { Text(verbatim: String(pipeline.sha.prefix(8))).monospaced() }
                        .buttonStyle(.link)
                        .help("View commit")
                }
                GridRow { Text("Trigger").foregroundStyle(.secondary); Text(verbatim: trigger) }
                if let d = pipeline.created {
                    GridRow { Text("Created").foregroundStyle(.secondary); Text(Fmt.long(d)) }
                }
            }
            .font(.callout)
            commands
            if let deps = store.ciDeployments[pipeline.id], !deps.isEmpty {
                DeploymentApproval(pipeline: pipeline, deployments: deps)
            }
        }
    }

    private var trigger: String {
        ([pipeline.eventTitle] + [pipeline.actor.map { "@\($0)" }].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var commands: some View {
        let p = pipeline
        let failed = p.status == .failed || p.status == .canceled
        let busy = store.ciBusy.contains("pipeline:\(p.id)")
        return WorkbenchFlow {
            if p.status.isActive {
                Button { store.cancelPipeline(p) } label: { Label("Cancel run", systemImage: "stop.circle") }
                    .disabled(busy)
            } else if provider == .github {
                Button { Task { await store.retryPipeline(p, failedOnly: true) } } label: {
                    Label("Rerun failed jobs only", systemImage: "arrow.clockwise")
                }
                .disabled(busy || !failed)
                Button { Task { await store.retryPipeline(p, failedOnly: false) } } label: {
                    Label("Rerun all jobs", systemImage: "arrow.clockwise.circle")
                }
                .disabled(busy)
            } else {
                Button { Task { await store.retryPipeline(p, failedOnly: true) } } label: {
                    Label("Rerun failed and canceled jobs", systemImage: "arrow.clockwise")
                }
                .disabled(busy || !failed)
            }
            Button { open(p.url) } label: { Label("Browser", systemImage: "safari") }
            Button { store.copy(p.url) } label: { Label("Copy link", systemImage: "link") }
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Jobs").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let jobs, !jobs.isEmpty { Text(verbatim: "\(jobs.count)").foregroundStyle(.secondary) }
            }
            if let jobs {
                if jobs.isEmpty {
                    Text("No jobs").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(stages(jobs), id: \.0) { stage, list in
                        if !stage.isEmpty {
                            Text(stage).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                                .padding(.top, 6)
                        }
                        ForEach(list) { j in
                            CIJobRow(job: j, pipeline: pipeline)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(job == j.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { job = j.id }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// GitLab orders jobs by stage; GitHub jobs have none and stay in one group
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

/// The picked job's log, read with the account and masked for secrets; it stays on this Mac.
/// A running job's log is read again every ten seconds.
private struct CIJobLogView: View {
    @Environment(RepoStore.self) private var store
    let job: CIJob
    let close: () -> Void
    @ViewState private var text = ""
    @ViewState private var loadedJob: Int?
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var truncated = false
    @ViewState private var generation = UUID()

    private var key: String {
        "\(job.id)|\(job.status.rawValue)|\(store.url?.path ?? "")|\(store.collaboration.contextID)|\(AccountStore.shared.revision)|\(store.hostingAccount?.id ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CIStatusIcon(status: job.status, size: 11)
                Text(job.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let d = job.duration, d > 0 {
                    Text(ciDuration(d)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if busy { ProgressView().controlSize(.mini) }
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload log")
                    .disabled(busy)
                Button { store.copy(text) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy redacted log")
                    .disabled(text.isEmpty)
                Button { open(job.url) } label: { Image(systemName: "safari") }
                    .help("Open in browser")
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Close log")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if text.isEmpty {
                Group { if busy { ProgressView().controlSize(.small) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if truncated {
                    Text("Log preview is limited to 2 MB. Open the browser for the complete log.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LogTextView(text: text)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Job log")
        .task(id: key) {
            await load()
            while job.status.isActive, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await load()
            }
        }
        .onDisappear { generation = UUID() }
    }

    private func load() async {
        guard let c = workspaceAccess(store) else {
            error = String(localized: "Connect an account to load this workspace.")
            return
        }
        let id = UUID()
        generation = id
        if loadedJob != job.id {
            text = ""
            truncated = false
            loadedJob = job.id
        }
        busy = true
        error = nil
        defer { if generation == id { busy = false } }
        do {
            let result = try await WorkspaceCILog.load(c, job: job.id)
            guard generation == id, c.isCurrent?() != false else { return }
            text = result.body
            truncated = result.truncated
        } catch is CancellationError {
        } catch {
            if generation == id { self.error = error.localizedDescription }
        }
    }
}

/// Read-only monospaced text; a SwiftUI Text is slow with a log of thousands of lines.
/// It opens at the end, where a failure usually is, and keeps following the end while it is there.
private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textColor = .labelColor
            view.textContainerInset = NSSize(width: 8, height: 6)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let following = view.string.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.height - 8
        view.string = text
        if following { view.scrollToEndOfDocument(nil) }
    }
}

/// One job: status, name and duration, with its run, cancel or rerun button
private struct CIJobRow: View {
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
                Text(ciDuration(d)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            actions
        }
        .font(.callout)
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


func ciDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 60 ? String(localized: "\(t / 60)m \(t % 60)s") : String(localized: "\(t)s")
}

private func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}
