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
                LedgerVerdictBadge(verdict: s.verdict)
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                        .help("Close").accessibilityLabel("Close")
                }
            }
            Text(s.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text([s.kind, s.role.title, s.status.title].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if let base = s.baseVersion {
                let current = s.baseCurrent ?? base
                let behind = LedgerProjects.behind(s, baselines: ledger.state?.baselines ?? [])
                HStack(spacing: 4) {
                    Image(systemName: "tag").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(current == base ? base : base + " → " + current).font(.caption.monospaced())
                    if behind > 0 {
                        Text("\(behind) behind").font(.caption2.weight(.semibold)).foregroundStyle(Color(nsColor: .systemOrange))
                    }
                    if let into = s.mergedInto { Text("merged into \(into)").font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
            Text(s.verdict.advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        LedgerAnswerField(placeholder: String(localized: "Answer…"),
                                          text: Binding(get: { ledger.drafts[q.id] ?? "" }, set: { ledger.drafts[q.id] = $0 }),
                                          busy: ledger.working.contains("q\(q.id)"),
                                          save: { Task { await ledger.answer(q) } },
                                          dismiss: { Task { await ledger.dismiss(q) } })
                    }
                }
                ForEach(closed) { q in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(q.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if q.state == .answered {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: q.answeredBy == .auto ? "timer" : "person.fill").font(.caption2).foregroundStyle(.secondary)
                                    .help(q.answeredBy == .auto ? String(localized: "Answered by auto-continue") : String(localized: "Answered by a person"))
                                Text(q.answer ?? "").font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            Text(q.deliveredAt == nil ? String(localized: "Waiting for the session's next report")
                                                      : String(localized: "Delivered \(LedgerTime.short(q.deliveredAt ?? 0))"))
                                .font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text("Dismissed").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
                }
            }
        }
    }

    // MARK: - Timeline

    private func timeline(_ detail: LedgerSessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LedgerSectionHeader(title: String(localized: "Timeline"), count: detail.events.count)
            let events = detail.events.sorted { $0.ts != $1.ts ? $0.ts > $1.ts : $0.id > $1.id }
            // the newest report body stays open; older long ones are folded
            let newestBody = events.first { !($0.body ?? "").isEmpty }?.id
            ForEach(events) { e in
                LedgerTimelineRow(event: e, highlighted: ledger.highlightedEvent == e.id, startsOpen: e.id == newestBody)
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
                        Image(systemName: "doc").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        ForEach(detail.overlaps.filter { $0.kind == .same && $0.paths.contains(path) }, id: \.self) { o in
                            let other = o.a == s.id ? o.b : o.a
                            Button { open(other) } label: {
                                Label(other, systemImage: "exclamationmark.triangle.fill").font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(nsColor: .systemOrange))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "\(other) touches this too — open it"))
                        }
                    }
                }
                ForEach(detail.overlaps.filter { $0.kind == .coupled }, id: \.self) { o in
                    let other = o.a == s.id ? o.b : o.a
                    Button { open(other) } label: {
                        Label("Likely overlap with \(other): \(o.paths.joined(separator: ", "))", systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                        .font(.caption.weight(LedgerEventText.isMilestone(event.type) ? .semibold : .medium))
                        .foregroundStyle(person ? Color.secondary : Color.primary)
                    if let version = event.version { Text(version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Text(LedgerTime.short(event.ts)).font(.caption2).foregroundStyle(.tertiary).help(LedgerTime.long(event.ts))
                }
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(person ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
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
                            Button(expanded ? String(localized: "Show less") : String(localized: "Show all")) { toggled = !expanded }.buttonStyle(.link).font(.caption)
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
    }

    private var tint: Color { LedgerEventText.isMilestone(event.type) ? .accentColor : .secondary }

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
