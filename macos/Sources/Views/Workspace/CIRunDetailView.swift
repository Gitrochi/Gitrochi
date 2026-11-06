import SwiftUI
import AppKit

/// The run picked on the Actions page, as the Actions board draws it: which run and its state, the title with its
/// actions, the branch, commit and how long it took; then the jobs by result on the left and the picked job's log on
/// the right. (Windows: features/ci-panel/ui/CIRunDetail.tsx)
struct CIRunDetailView: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.locale) private var locale
    let pipeline: CIPipeline
    @ViewState private var job: Int?
    /// The run whose failed job was already opened once; closing that log keeps it closed
    @ViewState private var autoOpened: Int?
    @ViewState private var width: CGFloat = 900

    private var provider: Provider { store.target?.provider ?? .gitlab }
    private var jobs: [CIJob]? { store.ciJobs[pipeline.id] }
    /// Too narrow for the jobs beside the log: the jobs go above it
    private var stacked: Bool { width < 620 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let deployments = store.ciDeployments[pipeline.id], !deployments.isEmpty {
                DeploymentApproval(pipeline: pipeline, deployments: deployments)
                Divider()
            }
            // only the arrangement changes, so the open log keeps its place when the window is resized
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                ScrollView { jobList.padding(12) }
                    .frame(width: stacked ? nil : 220, height: stacked ? 180 : nil)
                    .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: stacked ? nil : 1, height: stacked ? 1 : nil)
                Group {
                    if let selected = jobs?.first(where: { $0.id == job }) {
                        CIJobLogView(job: selected, pipeline: pipeline) { job = nil }
                    } else {
                        Group {
                            if jobs?.isEmpty == false { Text("Choose a job to read its log here.") }
                        }
                        .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: pipeline.id) { _, _ in job = nil; openFailedJob() }
        .onChange(of: jobs, initial: true) { _, _ in openFailedJob() }
    }

    /// A failed run opens on its first failed job, where the reason usually is
    private func openFailedJob() {
        guard autoOpened != pipeline.id, let jobs else { return }
        autoOpened = pipeline.id
        if job == nil, let failed = jobs.first(where: { $0.status == .failed && !$0.allowFailure }) { job = failed.id }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                (Text(verbatim: pipeline.name.isEmpty ? "" : pipeline.name + " · ") + Text(verbatim: ciRunName(pipeline, provider)).font(.system(size: 13, design: .monospaced)))
                    .font(.system(size: 13)).foregroundStyle(HostedList.caption).lineLimit(1)
                StatusPill(title: pipeline.status.title, symbol: pipeline.status == .running ? "arrow.triangle.2.circlepath" : pipeline.status.symbol, tone: pipeline.status.tone)
                if store.ciBusy.contains("pipeline:\(pipeline.id)") { ProgressView().controlSize(.small) }
            }
            if stacked {
                title
                actions
            } else {
                HStack(alignment: .top, spacing: 12) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize()
                }
            }
            WorkbenchFlow(spacing: 16) {
                // a branch name is set in the UI font, a commit in the monospaced one
                HostedListChip(title: pipeline.ref, square: true)
                Button { store.reveal(pipeline.sha) } label: {
                    Text(verbatim: String(pipeline.sha.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.link)
                }
                .buttonStyle(.plain).help("View commit")
                if let request = pipeline.request {
                    Button {
                        store.navigate(.pullRequests, prepare: false)
                        store.select(.pullRequest(request))
                    } label: { Text("Pull request #\(String(request))").foregroundStyle(StudioStyle.link) }
                    .buttonStyle(.plain)
                }
                // the list row owns the date; the detail says how long the run took
                if let took = ActionsPage.took(pipeline) {
                    Text("Took \(ciDuration(took))")
                } else if pipeline.status.isActive, let start = pipeline.started ?? pipeline.created {
                    Text("Started \(ListDate.when(start, locale: locale))")
                }
            }
            .font(.system(size: 12)).foregroundStyle(HostedList.caption)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text(verbatim: store.ciTitle(pipeline)).font(.system(size: 22, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    /// Open in browser stays in sight; rerunning, cancelling and the rest are in the More menu
    private var actions: some View {
        let p = pipeline
        let failed = p.status == .failed || p.status == .canceled
        let busy = store.ciBusy.contains("pipeline:\(p.id)")
        return HStack(spacing: 6) {
            Button { open(p.url) } label: { Label("Open in browser", symbol: "arrow.up.right.square") }
                .buttonStyle(HostedListButtonStyle())
            Menu {
                if p.status.isActive {
                    Button("Cancel run") { store.cancelPipeline(p) }.disabled(busy)
                } else if provider == .github {
                    Button("Rerun failed jobs only") { Task { await store.retryPipeline(p, failedOnly: true) } }.disabled(busy || !failed)
                    Button("Rerun all jobs") { Task { await store.retryPipeline(p, failedOnly: false) } }.disabled(busy)
                } else {
                    Button("Rerun failed and canceled jobs") { Task { await store.retryPipeline(p, failedOnly: true) } }.disabled(busy || !failed)
                }
                Divider()
                Button("View commit") { store.reveal(p.sha) }
                Button("Copy link") { store.copy(p.url) }
                Button("Refresh") { Task { await store.loadJobs(p) } }
            } label: { DesignIconImage(icon: .more, size: 12) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                .help("More run actions").accessibilityLabel("More run actions")
        }
    }

    // MARK: Jobs

    /// The jobs by result, what failed first; each group says how many it holds
    private var jobList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let jobs {
                if jobs.isEmpty { Text("No jobs").font(.system(size: 12)).foregroundStyle(HostedList.caption).padding(.horizontal, 8) }
                ForEach(ActionsPage.groups(jobs), id: \.group) { group, list in
                    Text(verbatim: "\(Self.title(group)) \(list.count)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption)
                        .padding(.horizontal, 8).padding(.top, group == ActionsPage.groups(jobs).first?.group ? 4 : 10).padding(.bottom, 4)
                    ForEach(list) { j in
                        CIJobRow(job: j, pipeline: pipeline, selected: job == j.id) { job = j.id }
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jobs")
    }

    private static func title(_ group: ActionsPage.JobGroup) -> String {
        switch group {
        case .failed: return String(localized: "Failed")
        case .running: return String(localized: "Running")
        case .waiting: return String(localized: "Waiting")
        case .passed: return String(localized: "Passed")
        case .other: return String(localized: "Other")
        }
    }
}

/// The picked job's log, read with the account and masked for secrets; it stays on this Mac.
/// A running job's log is read again every ten seconds.
private struct CIJobLogView: View {
    @Environment(RepoStore.self) private var store
    let job: CIJob
    let pipeline: CIPipeline
    let close: () -> Void
    @AppStorage("ciLogWrap") private var wrap = false
    @ViewState private var text = ""
    @ViewState private var loadedJob: Int?
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var truncated = false
    @ViewState private var generation = UUID()
    /// The lines before the part the log opens on are shown on request
    @ViewState private var showAll = false
    /// Counts presses of "Jump to first error"
    @ViewState private var jump = 0

    private var provider: Provider { store.target?.provider ?? .gitlab }

    private var key: String {
        "\(job.id)|\(job.status.rawValue)|\(store.url?.path ?? "")|\(store.collaboration.contextID)|\(AccountStore.shared.revision)|\(store.hostingAccount?.id ?? "")"
    }

    private var canRetry: Bool {
        switch provider {
        case .gitlab: return [.failed, .canceled, .success].contains(job.status)
        case .github: return job.status.isFinished && !pipeline.status.isActive
        }
    }

    /// "Failed after 3m 12s" for a failed job, how long any other finished one took, else its state
    private var outcome: String {
        guard let duration = job.duration, duration > 0 else { return job.status.title }
        return job.status == .failed ? String(localized: "Failed after \(ciDuration(duration))") : String(localized: "Took \(ciDuration(duration))")
    }

    var body: some View {
        let lines = ActionsPage.lines(text)
        let hasError = lines.contains(where: ActionsPage.isError)
        let first = showAll ? 0 : ActionsPage.firstShown(lines)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { name; Spacer(minLength: 8); buttons(hasError: hasError) }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) { name }
                        buttons(hasError: hasError)
                    }
                }
                if truncated {
                    Text("Log preview is limited to 2 MB. Open the browser for the complete log.")
                        .font(.system(size: 12)).foregroundStyle(HostedList.caption).padding(.leading, 22)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text).textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if text.isEmpty {
                Group {
                    if busy { ProgressView().controlSize(.small) }
                    else { Text("No log output yet.").font(.system(size: 12)).foregroundStyle(HostedList.caption) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if first > 0 {
                        Button("Show \(first) earlier lines") { showAll = true }
                            .buttonStyle(HostedListTextButtonStyle())
                            .padding(.leading, 12).padding(.top, 2)
                    }
                    LogTextView(lines: Array(lines[first...]), first: first, wrap: wrap, jump: jump, follow: !hasError)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.canvas))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
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
        .onChange(of: job.id) { _, _ in showAll = false }
        .onDisappear { generation = UUID() }
    }

    @ViewBuilder private var name: some View {
        CIStatusIcon(status: job.status, size: 13)
        Text(verbatim: job.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
        // the failed tone on words that say it failed; the icon says it too
        Text(verbatim: outcome).font(.system(size: 12)).foregroundStyle(job.status == .failed ? StudioStyle.Tone.failed.text : HostedList.caption)
            .lineLimit(1).fixedSize()
        if busy { ProgressView().controlSize(.mini) }
    }

    private func buttons(hasError: Bool) -> some View {
        HStack(spacing: 6) {
            if hasError {
                Button("Jump to first error") { showAll = false; jump += 1 }.buttonStyle(HostedListButtonStyle())
            }
            if canRetry {
                Button { Task { await store.retryJob(job, in: pipeline) } } label: { Label("Re-run job", symbol: "arrow.clockwise") }
                    .buttonStyle(HostedListButtonStyle())
                    .disabled(store.ciBusy.contains("job:\(job.id)"))
            }
            Button { open(job.url) } label: { Label("Open in browser", symbol: "arrow.up.right.square") }
                .buttonStyle(HostedListButtonStyle(iconOnly: true))
                .help("Open in browser")
            Menu {
                Toggle("Wrap long lines", isOn: $wrap)
                Button("Copy redacted log") { store.copy(text) }.disabled(text.isEmpty)
                Button("Reload log") { Task { await load() } }.disabled(busy)
                Divider()
                Button("Close log", action: close)
            } label: { DesignIconImage(icon: .more, size: 12) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                .help("More job actions").accessibilityLabel("More job actions")
        }
        .fixedSize()
    }

    private func load() async {
        let id = UUID(), expected = key
        generation = id
        if loadedJob != job.id {
            text = ""
            truncated = false
            loadedJob = job.id
        }
        busy = true
        error = nil
        defer { if generation == id { busy = false } }
        _ = await store.resolveCollaborationAccess()
        guard generation == id, key == expected, !Task.isCancelled else { return }
        guard let c = workspaceAccess(store) else {
            error = store.hostingAccount.map { AccountStore.shared.savedAccessMessage(for: $0) }
                ?? String(localized: "Connect an account to load this workspace.")
            return
        }
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

/// Read-only monospaced text with line numbers; a SwiftUI Text is slow with a log of thousands of lines.
/// Lines that name an error are marked in the failed tone. A log without one opens at its end and keeps following
/// the end while it is there; one with an error opens on it.
private struct LogTextView: NSViewRepresentable {
    let lines: [String]
    /// How many lines of the log come before the first one shown
    let first: Int
    let wrap: Bool
    let jump: Int
    let follow: Bool

    final class Coordinator {
        var signature = ""
        var jump = 0
        var wrap: Bool?
        var error: NSRange?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.textContainer?.replaceLayoutManager(LogLayoutManager())
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 8, height: 6)
        }
        context.coordinator.jump = jump
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let state = context.coordinator
        if state.wrap != wrap {
            // a new text view wraps already; only a change, or no wrapping, needs setting up
            let changed = state.wrap != nil
            state.wrap = wrap
            if !wrap {
                // unwrapped lines scroll sideways
                scroll.hasHorizontalScroller = true
                view.isHorizontallyResizable = true
                view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                view.textContainer?.widthTracksTextView = false
                view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            } else if changed {
                scroll.hasHorizontalScroller = false
                view.isHorizontallyResizable = false
                view.frame.size.width = scroll.contentSize.width
                view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                view.textContainer?.widthTracksTextView = true
            }
        }
        let signature = "\(first)|\(lines.count)|\(lines.last?.hashValue ?? 0)|\(lines.first?.hashValue ?? 0)"
        if state.signature != signature {
            let following = follow && (view.string.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.height - 8)
            let (text, error) = Self.attributed(lines, first: first)
            state.signature = signature
            state.error = error
            view.textStorage?.setAttributedString(text)
            if following { view.scrollToEndOfDocument(nil) }
        }
        if state.jump != jump {
            state.jump = jump
            if let error = state.error { view.scrollRangeToVisible(error) }
        }
    }

    /// The numbered lines, with the range of the first one that names an error
    private static func attributed(_ lines: [String], first: Int) -> (NSAttributedString, NSRange?) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        let digits = String(first + lines.count).count
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        var marked = plain
        marked[.foregroundColor] = NSColor(StudioStyle.Tone.failed.text)
        marked[.logErrorLine] = true
        let out = NSMutableAttributedString()
        var error: NSRange?
        for (index, line) in lines.enumerated() {
            let label = String(first + index + 1)
            let isError = ActionsPage.isError(line)
            let start = out.length
            out.append(NSAttributedString(string: String(repeating: " ", count: max(0, digits - label.count)) + label + "  ", attributes: isError ? marked.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 } : number))
            out.append(NSAttributedString(string: line + (index == lines.count - 1 ? "" : "\n"), attributes: isError ? marked : plain))
            if isError, error == nil { error = NSRange(location: start, length: out.length - start) }
        }
        return (out, error)
    }
}

private extension NSAttributedString.Key {
    static let logErrorLine = NSAttributedString.Key("logErrorLine")
}

/// Draws the failed tone across a whole line, not only behind its text
private final class LogLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange range: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: range, at: origin)
        guard let storage = textStorage else { return }
        NSColor(StudioStyle.Tone.failed.fill).setFill()
        enumerateLineFragments(forGlyphRange: range) { rect, _, _, glyphs, _ in
            let location = self.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
            guard location < storage.length, storage.attribute(.logErrorLine, at: location, effectiveRange: nil) != nil else { return }
            NSRect(x: 0, y: rect.minY + origin.y, width: 100_000, height: rect.height).fill()
        }
    }
}

/// One job: status, name and duration; a click shows its log. A job that waits to be run, or one that can be stopped,
/// carries that one button.
private struct CIJobRow: View {
    @Environment(RepoStore.self) private var store
    let job: CIJob
    let pipeline: CIPipeline
    let selected: Bool
    let select: () -> Void
    @ViewState private var hovered = false

    private var provider: Provider { store.target?.provider ?? .gitlab }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    CIStatusIcon(status: job.status, size: 13)
                    Text(verbatim: job.name).font(.system(size: 13, weight: selected ? .semibold : .regular, design: .monospaced)).lineLimit(1)
                    if job.allowFailure, job.status == .failed {
                        SymbolIcon("exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.waiting.text).help("Allowed to fail")
                    }
                    Spacer(minLength: 0)
                    if let d = job.duration, d > 0 {
                        Text(ciDuration(d)).font(.system(size: 11, design: .monospaced)).foregroundStyle(HostedList.secondary(selected: selected)).fixedSize()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            actions
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hovered ? StudioStyle.hover : Color.clear))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("View log (browser)") { open(job.url) }
            if job.canPlay, provider == .gitlab { Button("Run") { store.playJob(job, in: pipeline) } }
            if canRetry { Button("Run again") { Task { await store.retryJob(job, in: pipeline) } } }
            if job.status.isActive, provider == .gitlab { Button("Cancel") { Task { await store.cancelJob(job, in: pipeline) } } }
            Divider()
            Button("Copy link") { store.copy(job.url) }
        }
        .help(job.stage.isEmpty ? job.status.title : "\(job.stage) · \(job.status.title)")
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
            Button { store.playJob(job, in: pipeline) } label: { SymbolIcon("play.circle").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .help(job.status == .scheduled ? "Run now (don't wait for the schedule)" : "Run manual job")
        } else if job.status.isActive, provider == .gitlab {
            Button { Task { await store.cancelJob(job, in: pipeline) } } label: { SymbolIcon("stop.circle").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .help("Cancel job")
        }
    }
}

/// A deployment that waits for approval (GitHub environment protection rules): white with a hairline, the waiting
/// icon and words in its tone, and the two answers
private struct DeploymentApproval: View {
    @Environment(RepoStore.self) private var store
    let pipeline: CIPipeline
    let deployments: [CIDeployment]

    var body: some View {
        let mine = deployments.filter(\.canApprove)
        HStack(spacing: 10) {
            SymbolIcon("hand.raised.fill").font(.system(size: 14)).foregroundStyle(StudioStyle.Tone.waiting.text).accessibilityHidden(true)
            Text("Waiting for deployment approval: \(deployments.map(\.environment).joined(separator: ", "))")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.Tone.waiting.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if mine.isEmpty {
                Text("This account can't approve.").font(.system(size: 12)).foregroundStyle(HostedList.caption)
            } else {
                Button("Approve") { store.reviewDeployment(pipeline, mine, approve: true) }.hostedListFilledButton()
                Button("Reject") { store.reviewDeployment(pipeline, mine, approve: false) }.buttonStyle(HostedListButtonStyle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}


func ciDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 60 ? String(localized: "\(t / 60)m \(t % 60)s") : String(localized: "\(t)s")
}

private func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}
