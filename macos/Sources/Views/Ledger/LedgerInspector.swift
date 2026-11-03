import SwiftUI

/// One session's whole record: header and links, the actions its verdict allows, questions with answer fields,
/// the timeline (bodies through MarkdownView, long ones folded), touches and overlaps.
/// (Windows: widgets/ledger-workspace/ui/LedgerInspector.tsx)
struct LedgerInspector: View {
    let ledger: LedgerStore
    let open: (String) -> Void
    /// Set when the inspector is a sheet
    var close: (() -> Void)?
    @ViewState private var confirmDrop = false
    @ViewState private var showActivity = false

    var body: some View {
        Group {
            if let id = ledger.selection, let session = ledger.detail?.session.id == id ? ledger.detail?.session : ledger.session(id) {
                content(session, detail: ledger.detail?.session.id == id ? ledger.detail : nil)
            } else if ledger.selection != nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkspaceEmptyState(title: "Select a session", systemImage: "sidebar.right",
                                    description: "Its questions, reports, links and what to do with it show here.")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func content(_ s: LedgerSession, detail: LedgerSessionDetail?) -> some View {
        ScrollViewReader { proxy in
            InspectorScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(s)
                    actions(s)
                    if let detail {
                        questions(detail)
                        autoContinue(s)
                        timeline(detail)
                        touches(s, detail: detail)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            .onChange(of: ledger.highlightedEvent, initial: true) { _, event in
                if let event { DispatchQueue.main.async { withAnimation { proxy.scrollTo("event-\(event)", anchor: .center) } } }
            }
            .onChange(of: detail?.events.contains { $0.id == ledger.highlightedEvent } ?? false) { _, found in
                if found, let event = ledger.highlightedEvent {
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo("event-\(event)", anchor: .center) } }
                }
            }
        }
        .confirmationDialog("Drop \(s.id)?", isPresented: $confirmDrop) {
            Button("Drop", role: .destructive) {
                Task { await ledger.perform(.setStatus(.dropped, version: nil), on: [s.id], message: String(localized: "Dropped \(s.id)")) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session's result is discarded. It stays in the ledger as dropped, and Undo brings it back.")
        }
    }

    // MARK: - Header

    private func header(_ s: LedgerSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LedgerSessionLabel(id: s.id, color: s.color)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if LedgerWake.waits(s, now: LedgerStore.localNow() + ledger.clockSkew) { LedgerWakePill() }
                LedgerVerdictBadge(verdict: s.verdict)
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                        .help("Close").accessibilityLabel("Close")
                }
            }
            Text(s.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text([s.kind, s.role.title, s.status.title].joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Last report").foregroundStyle(.secondary)
                    if let report = s.lastAgentAt {
                        Text(LedgerTime.short(report)).help(LedgerTime.long(report))
                    } else {
                        Text("No reports yet.").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text("Last activity").foregroundStyle(.secondary)
                    Text(LedgerTime.short(s.lastAt)).help(LedgerTime.long(s.lastAt))
                }
            }
            .font(.system(size: 11))
            if let base = s.baseVersion {
                let current = s.baseCurrent ?? base
                let behind = LedgerProjects.behind(s, baselines: ledger.state?.baselines ?? [])
                HStack(spacing: 4) {
                    Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(current == base ? base : base + " → " + current).font(.system(size: 11))
                    if behind > 0 {
                        Text("\(behind) behind").font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.Tone.waiting.text)
                    }
                    if let into = s.mergedInto { Text("merged into \(into)").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
            Text(s.verdict.advice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            links(s)
        }
    }

    private func links(_ s: LedgerSession) -> some View {
        WorkbenchFlow(spacing: 6) {
            if let branch = s.links.branch { LedgerLinkChip(symbol: "arrow.triangle.branch", text: branch) }
            if let worktree = s.links.worktree { LedgerLinkChip(symbol: "folder", text: (worktree as NSString).lastPathComponent) }
            if let pr = s.links.pr { LedgerLinkChip(symbol: "arrow.triangle.pull", text: "#\(pr.number)", url: URL(string: pr.url)) }
            if let agent = s.links.agentId { LedgerLinkChip(symbol: "cpu", text: agent) }
            if let chat = s.chatUrl, let url = URL(string: chat) { LedgerLinkChip(symbol: "bubble.left.and.bubble.right", text: String(localized: "Open chat"), url: url) }
            if let auto = s.autoContinue, auto.enabled {
                LedgerLinkChip(symbol: "timer", text: String(localized: "Auto-continue after \(auto.delaySec) s"))
            }
        }
    }

    // MARK: - Actions

    private func actions(_ s: LedgerSession) -> some View {
        let busy = ledger.working.contains(s.id)
        let finished = s.status.isFinished
        return WorkbenchFlow(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            if finished && s.ackAt == nil {
                Button("Confirm") { run(.ack, s, String(localized: "Confirmed \(s.id)")) }.buttonStyle(.borderedProminent)
                    .help("Confirm the outcome")
            }
            if s.ackAt != nil {
                Button("Unconfirm") { run(.unack, s, String(localized: "Unconfirmed \(s.id)")) }.help("Go back to To confirm")
            }
            if s.archivedAt == nil, finished || s.status == .shelved {
                Button("Archive") { run(.archive, s, String(localized: "Archived \(s.id)")) }
                    .help("The conversation is cleaned up; a new report brings the session back")
            } else if s.archivedAt != nil {
                Button("Unarchive") { run(.unarchive, s, String(localized: "Unarchived \(s.id)")) }
            }
            if !finished {
                LedgerMergeMenu(session: s, ledger: ledger)
                Button("Close") { run(.setStatus(.closed, version: nil), s, String(localized: "Closed \(s.id)")) }
                    .help("Finished without a merge")
                Button("Drop…") { confirmDrop = true }.help("The result is discarded")
            }
            // shelving is for research and documents, which may pause without a merge
            if s.status == .active || s.status == .done, s.role == .research || s.role == .document {
                Button("Shelve") { run(.shelve, s, String(localized: "Shelved \(s.id)")) }
                    .help("Pause it on purpose; it never turns stale")
            }
            if s.verdict == .stale {
                Button("Still active") { run(.stillActive, s, String(localized: "Marked \(s.id) still active")) }
                    .help("It is still going: it does not count as stale for a while")
            }
            if s.status != .active {
                Button("Reopen") { run(.setStatus(.active, version: nil), s, String(localized: "Reopened \(s.id)")) }
                    .help("Back to active: clears the confirmation and the archive")
            }
        }
        .controlSize(.small)
        .disabled(busy)
    }

    private func run(_ action: LedgerHumanAction, _ s: LedgerSession, _ message: String) {
        Task { await ledger.perform(action, on: [s.id], message: message) }
    }

    // MARK: - Questions

    @ViewBuilder private func questions(_ detail: LedgerSessionDetail) -> some View {
        let open = detail.questions.filter { $0.state == .open }
        let closed = detail.questions.filter { $0.state != .open }.sorted { ($0.answeredAt ?? 0) > ($1.answeredAt ?? 0) }
        if !detail.questions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                LedgerSectionHeader(title: String(localized: "Questions"), count: open.count)
                ForEach(open) { q in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q.text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        LedgerReportedAnswerField(question: q,
                                          text: Binding(get: { ledger.drafts[q.id] ?? "" }, set: { ledger.drafts[q.id] = $0 }),
                                          busy: ledger.working.contains("q\(q.id)"),
                                          save: { Task { await ledger.answer(q) } },
                                          dismiss: { Task { await ledger.dismiss(q) } })
                    }
                }
                ForEach(closed) { q in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(q.text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let source = LedgerBrowserSetup.sourceURL(q.browserSourceUrl) {
                            Link("Source conversation", destination: source).font(.system(size: 11))
                        }
                        if q.state == .answered {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: q.answeredBy == .auto ? "timer" : "person.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .help(q.answeredBy == .auto ? String(localized: "Answered by auto-continue") : String(localized: "Answered by a person"))
                                Text(q.answer ?? "").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            Text(LedgerBrowserSetup.sourceURL(q.browserSourceUrl) != nil
                                 ? String(localized: "Answers are saved in Ledger. They are not sent back to ChatGPT.")
                                 : q.deliveredAt == nil ? String(localized: "Waiting for the session's next report")
                                                      : String(localized: "Delivered \(LedgerTime.short(q.deliveredAt ?? 0))"))
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                            Button("Copy answer") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(q.answer ?? "", forType: .string)
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                        } else {
                            Text("Dismissed").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        if let draft = ledger.drafts[q.id], !draft.isEmpty {
                            Text("Your draft was not sent.").font(.system(size: 11)).foregroundStyle(.secondary)
                            LedgerQuestionAnswerEditor(question: LedgerPromptAnswers.question(q),
                                                       text: .constant(draft), busy: true, showsQuestion: false)
                            Button("Close") { ledger.drafts[q.id] = nil }.buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
                }
            }
        }
    }

    // MARK: - Auto-continue

    /// The session's own switch and wait (DESIGN.md §9.3); without its own it shows the default it follows
    @ViewBuilder private func autoContinue(_ s: LedgerSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LedgerSectionHeader(title: String(localized: "Auto-continue"))
            if s.role == .decision {
                Text("Decision sessions never continue automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let policy = s.autoContinue ?? ledger.autoContinueDefault ?? .init(enabled: false, delaySec: 30)
                let busy = ledger.working.contains(s.id)
                Toggle("Continue automatically when nobody answers", isOn: Binding(get: { policy.enabled }, set: { on in
                    Task { await ledger.setAutoContinue(s, .init(enabled: on, delaySec: policy.delaySec)) }
                }))
                .toggleStyle(.checkbox).disabled(busy)
                HStack(spacing: 8) {
                    LedgerWaitPicker(seconds: policy.delaySec) { seconds in
                        Task { await ledger.setAutoContinue(s, .init(enabled: policy.enabled, delaySec: seconds)) }
                    }
                    .disabled(busy)
                    if s.autoContinue != nil {
                        Button("Use the default") { Task { await ledger.setAutoContinue(s, nil) } }
                            .controlSize(.small).disabled(busy)
                            .help("Follow the repository's or the default auto-continue setting again")
                    }
                }
                Text("Works for Claude Code agents Gitrochi starts while Track agents I start is on.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await ledger.loadAutoContinueDefault() }
    }

    // MARK: - Timeline

    private func timeline(_ detail: LedgerSessionDetail) -> some View {
        let events = LedgerTimelineFilter.events(detail.events, showActivity: showActivity, focus: ledger.highlightedEvent)
        let hidden = detail.events.count - events.count
        let hasActivity = detail.events.contains(where: LedgerTimelineFilter.isActivity)
        // The newest report body stays open; a search target opens as well.
        let newestBody = events.first { !($0.body ?? "").isEmpty }?.id
        return VStack(alignment: .leading, spacing: 8) {
            LedgerSectionHeader(title: String(localized: "Timeline"))
            if hasActivity {
                Toggle("Show activity", isOn: $showActivity)
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
            if hidden > 0 {
                Text("\(hidden) activity events hidden").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if events.isEmpty {
                Text("No reports yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(events) { e in
                LedgerTimelineRow(event: e, highlighted: ledger.highlightedEvent == e.id, startsOpen: e.id == newestBody || e.id == ledger.highlightedEvent)
                    .id("event-\(e.id)")
            }
        }
    }

    // MARK: - Touches

    @ViewBuilder private func touches(_ s: LedgerSession, detail: LedgerSessionDetail) -> some View {
        if !s.touches.isEmpty || !detail.overlaps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                LedgerSectionHeader(title: String(localized: "Touches"), count: s.touches.count)
                ForEach(s.touches, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                        // the file name whole, then its folder shortened from the start (docs/design.md, Text)
                        Text((path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1).fixedSize()
                            .textSelection(.enabled)
                        let folder = (path as NSString).deletingLastPathComponent
                        if !folder.isEmpty {
                            Text(folder).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 4)
                        ForEach(detail.overlaps.filter { $0.kind == .same && $0.paths.contains(path) }, id: \.self) { o in
                            let other = o.a == s.id ? o.b : o.a
                            Button { open(other) } label: {
                                Label(other, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StudioStyle.Tone.waiting.text)
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "\(other) touches this too — open it"))
                        }
                    }
                    .help(path)
                }
                ForEach(detail.overlaps.filter { $0.kind == .coupled }, id: \.self) { o in
                    let other = o.a == s.id ? o.b : o.a
                    Button { open(other) } label: {
                        Label("Likely overlap with \(other): \(o.paths.joined(separator: ", "))", systemImage: "link")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .help("Files that usually change together")
                }
            }
        }
    }
}

/// One event: what happened, by whom, the version and artifacts, and the body folded when it is long
private struct LedgerTimelineRow: View {
    let event: LedgerEvent
    let highlighted: Bool
    let startsOpen: Bool
    @ViewState private var toggled: Bool?

    private var expanded: Bool { toggled ?? startsOpen }

    private var long: Bool { (event.body?.count ?? 0) > 600 || (event.body?.split(separator: "\n").count ?? 0) > 10 }
    private var person: Bool { event.actor == .human }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(person ? Color.secondary : tint)
                .frame(width: 16).padding(.top, 2)
                .help(actor)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(LedgerEventText.title(event.type))
                        .font(.system(size: 11, weight: LedgerEventText.isMilestone(event.type) ? .semibold : .medium))
                        .foregroundStyle(person ? Color.secondary : Color.primary)
                    if let version = event.version { Text(version).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Text(LedgerTime.short(event.ts)).font(.system(size: 11)).foregroundStyle(.tertiary).help(LedgerTime.long(event.ts))
                }
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 11)).foregroundStyle(person ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let artifacts = event.artifacts, !artifacts.isEmpty {
                    WorkbenchFlow(spacing: 4) {
                        ForEach(artifacts, id: \.self) { a in
                            LedgerLinkChip(symbol: "doc.text", text: a.name + (a.ssot.map { " · " + $0 } ?? ""))
                        }
                    }
                }
                if let body = event.body, !body.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MarkdownView(body)
                            .frame(maxHeight: long && !expanded ? 150 : nil, alignment: .top)
                            .clipped()
                        if long {
                            Button(expanded ? String(localized: "Show less") : String(localized: "Show all")) { toggled = !expanded }.buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? StudioStyle.selection : Color.clear))
        .accessibilityElement(children: .combine)
        .onChange(of: highlighted) { _, focused in
            if focused { toggled = true }
        }
    }

    /// Milestones stand out in the text colour; the accent is not for status (docs/design.md, Accent)
    private var tint: Color { LedgerEventText.isMilestone(event.type) ? .primary : .secondary }

    private var icon: String {
        switch event.actor {
        case .human: return "person.fill"
        case .auto: return "timer"
        case .hook: return "bolt.horizontal"
        case .agent: return LedgerEventText.isMilestone(event.type) ? "smallcircle.filled.circle" : "circle.fill"
        }
    }

    private var actor: String {
        switch event.actor {
        case .human: return String(localized: "A person")
        case .auto: return String(localized: "Auto-continue")
        case .hook: return String(localized: "Agent activity")
        case .agent: return String(localized: "The agent")
        }
    }
}
