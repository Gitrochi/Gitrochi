import SwiftUI
import AppKit

/// The sidebar's Agents tab: what waits for the user first, then each worktree with the sessions in it, then agents
/// running elsewhere. Every session is drawn by one row, with the terminal tab's marks and words.
/// (Windows: widgets/sidebar/ui/AgentsPanel.tsx)
struct AgentsPanel: View {
    @Environment(RepoStore.self) private var store
    private let agents = AgentCenter.shared
    /// Ended sessions start folded away
    @AppStorage("agentsEndedOpen") private var endedOpen = false

    var body: some View {
        let known = Set(store.worktrees.map { AgentCenter.normalize($0.path) })
        let inWorktree = { (s: AgentSession) in known.contains(AgentCenter.normalize(s.path)) }
        let needs = agents.sessions.filter { $0.status.needsUser }.sorted { $0.updated < $1.updated }
        let ended = agents.sessions.filter { $0.status == .ended && inWorktree($0) }
        let others = agents.sessions.filter { !inWorktree($0) && $0.status != .ended }
        let typed = agents.terminalAgents(in: store.worktrees.map(\.path))
        let elsewhere = agents.external(in: store.worktrees.map(\.path) + [store.url?.path].compactMap { $0 })
        let mainPath = store.worktrees.first(where: \.isMain)?.path
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                startRow

                if !needs.isEmpty {
                    SidebarSection("agent-needs") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(needs) { s in NeedCard(session: s) }
                        }
                    } header: {
                        Text("Needs you")
                        StatusPill(title: "\(needs.count)", tone: .neutral)
                    }
                }

                SidebarSection("agent-worktrees") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.worktrees) { w in
                            WorktreeGroup(worktree: w,
                                          stats: store.worktreeStats[w.path],
                                          sessions: agents.sessions(in: w.path).filter { $0.status != .ended },
                                          typed: typed.filter { root(for: $0)?.path == w.path },
                                          isCurrent: AgentCenter.normalize(w.path) == AgentCenter.normalize(store.url?.path ?? ""),
                                          isMain: w.path == mainPath)
                        }
                    }
                    if !ended.isEmpty {
                        SidebarSection("agent-ended", open: $endedOpen) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(ended) { s in
                                    SessionRow(session: s, place: store.worktrees.first { AgentCenter.normalize($0.path) == AgentCenter.normalize(s.path) }?.branch
                                               ?? (s.path as NSString).lastPathComponent)
                                }
                            }
                        } header: {
                            Text("Ended")
                            StatusPill(title: "\(ended.count)", tone: .neutral)
                        }
                        // a section inside a section: its head lines up with the others
                        .padding(.horizontal, -6)
                    }
                } header: {
                    Text("Worktrees")
                    StatusPill(title: "\(store.worktrees.count)", tone: .neutral)
                    Spacer(minLength: 4)
                    Button { store.sheet = .addWorktree(branch: nil, start: nil) } label: { DesignIconImage(icon: .plus, size: 13) }
                        .buttonStyle(PullRequestIconButtonStyle())
                        .help("New worktree…").accessibilityLabel("New worktree…")
                    if agents.sessions.contains(where: { $0.status == .ended }) {
                        Menu {
                            Button("Clear ended sessions") { agents.clearEnded() }
                        } label: {
                            DesignIconImage(icon: .more, size: 14).foregroundStyle(StudioStyle.Tone.neutral.text)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("More agent actions").accessibilityLabel("More agent actions")
                    }
                }

                if !elsewhere.isEmpty || !others.isEmpty {
                    SidebarSection("agent-elsewhere") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(elsewhere) { a in ExternalAgentRow(agent: a, root: root(for: a)) }
                            ForEach(others) { s in
                                SessionRow(session: s, place: (s.path as NSString).abbreviatingWithTildeInPath, flat: true)
                            }
                        }
                    } header: {
                        Text("Elsewhere")
                    }
                }

                Text(AgentCenter.Place.current == .app
                     ? "Sessions started here run in the terminal tabs below; click one to go to its terminal."
                     : "Only sessions started here show their status. Click a session to go to its Terminal window.")
                    .font(.system(size: 12))
                    .foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .task(id: store.worktrees.map(\.path)) {
            // the store polls other worktrees while this tab is in front; count once right away
            await store.refreshWorktreeStats()
        }
        .task {
            // agents in other apps are looked up only while this tab is open
            while !Task.isCancelled {
                await agents.refreshExternal()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// "Start agent session…" and, beside it, a session of the last agent in this worktree right away
    private var startRow: some View {
        HStack(spacing: 6) {
            Button { store.sheet = .startAgent(path: nil) } label: {
                Label("Start agent session…", symbol: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(HostedListButtonStyle())
            Button { if let u = store.url { store.startAgent(in: u.path) } } label: {
                Label("Start \(agents.defaultKind.title) in this worktree now", symbol: "bolt.fill")
            }
            .buttonStyle(HostedListButtonStyle(iconOnly: true))
            .help("Start \(agents.defaultKind.title) in this worktree now")
        }
        .padding(.horizontal, 6)
    }

    /// The worktree an agent works in, so the row can name it instead of the full path
    private func root(for agent: ExternalAgent) -> Worktree? {
        store.worktrees
            .filter { ExternalAgents.isInside(agent.cwd, roots: [$0.path]) }
            .max { $0.path.count < $1.path.count }
    }
}

/// A session that waits for the user: what it waits for, which session, and the way to its terminal
private struct NeedCard: View {
    let session: AgentSession

    var body: some View {
        let agents = AgentCenter.shared
        NoticeBlock(symbol: session.status == .permission ? "exclamationmark.circle.fill" : "pause.circle.fill",
                    tone: .waiting,
                    title: session.status.title,
                    caption: AgentSessionState.needCaption(task: session.task, folder: (session.path as NSString).lastPathComponent,
                                                           kind: session.kind.title,
                                                           detail: session.status == .permission ? session.detail : nil,
                                                           ago: Fmt.short(session.updated)),
                    actions: [NoticeAction(title: String(localized: "Respond")) { agents.focus(session) }])
    }
}

/// A worktree and, indented under it, the sessions working in it
private struct WorktreeGroup: View {
    @Environment(RepoStore.self) private var store
    let worktree: Worktree
    let stats: WorktreeStats?
    let sessions: [AgentSession]
    /// Agents typed into the terminal below that work here
    let typed: [ExternalAgent]
    let isCurrent: Bool
    let isMain: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isCurrent {
                    CurrentMarker()
                } else {
                    DesignIconImage(icon: .branch, size: 13).foregroundStyle(HostedList.caption)
                }
                Text(worktree.branch ?? String(localized: "Detached HEAD"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                stateIcon
            }
            .frame(minHeight: 18)
            HStack(spacing: 4) {
                Text(verbatim: AgentSessionState.worktreePlace((worktree.path as NSString).abbreviatingWithTildeInPath, isMain: isMain))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HostedList.caption)
                    .lineLimit(1).truncationMode(.tail)
                    .help(worktree.path)
                Spacer(minLength: 0)
                if let stats, stats.ahead > 0 { AheadBehindPill(text: "↑\(stats.ahead)").help("Commits not pushed to the remote") }
                if let stats, stats.behind > 0 { AheadBehindPill(text: "↓\(stats.behind)").help("Commits not pulled from the remote") }
            }
            .frame(minHeight: 18)
            .padding(.leading, 19)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !isCurrent else { return }
            Task { await store.switchWorktree(to: worktree.path) }
        }
        .contextMenu {
            Button("Start agent session…") { store.sheet = .startAgent(path: worktree.path) }
            Button("Open worktree") { Task { await store.switchWorktree(to: worktree.path) } }
                .disabled(isCurrent)
            Button("Open in new tab") {
                Task { await store.openOrReport(URL(fileURLWithPath: worktree.path, isDirectory: true)) }
            }
            .disabled(isCurrent)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)]) }
            Button("Open in the terminal below") { store.newTerminal(in: worktree.path) }
            Button("Open in Terminal") { Launcher.openTerminal(at: worktree.path) }
            Divider()
            Button("Remove worktree…", role: .destructive) { store.confirmRemove(worktree) }
                .disabled(worktree.isMain || isCurrent)
        }
        ForEach(sessions) { s in SessionRow(session: s) }
        ForEach(typed) { a in TerminalAgentRow(agent: a, root: worktree.path) }
    }

    /// One state icon: a conflict outranks plain uncommitted files
    @ViewBuilder private var stateIcon: some View {
        if let stats, stats.conflicted > 0 {
            SymbolIcon("xmark.circle.fill").font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.failed.text)
                .help(String(localized: "Conflict") + " \(stats.conflicted)")
                .accessibilityLabel(String(localized: "Conflict") + " \(stats.conflicted)")
        } else if let stats, stats.added + stats.modified + stats.deleted > 0 {
            DesignIconImage(icon: .pencil, size: 12).foregroundStyle(HostedList.caption)
                .help(String(localized: "Uncommitted changes") + " \(stats.added + stats.modified + stats.deleted)")
                .accessibilityLabel(String(localized: "Uncommitted changes") + " \(stats.added + stats.modified + stats.deleted)")
        }
    }
}

/// Ahead or behind at a row's right edge: one neutral pill each, 18 pt tall, monospaced 11 pt semibold
private struct AheadBehindPill: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(StudioStyle.Tone.neutral.text)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Capsule().fill(StudioStyle.Tone.neutral.fill))
            .fixedSize()
    }
}

/// The one row every session is drawn by: the terminal tab's mark in its 12 pt slot, "Agent · what it does" on up to
/// two lines, then what only some rows have (the skipped permission checks, where it runs).
private struct AgentRow<Trailing: View>: View {
    let mark: TerminalTabMark
    /// The state in words, for the tooltip and VoiceOver (the mark alone shows it)
    let word: String
    let kind: String
    var text: String = ""
    /// Draws the text as a state word in the waiting tone (an agent in another app has no task to show)
    var toned = false
    var skips = false
    var place: String = ""
    /// Not indented under a worktree
    var flat = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @ViewState private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    TerminalTabMarkView(mark: mark).padding(.top, 2)
                    line.font(.system(size: 12)).lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if skips {
                    HStack(spacing: 4) {
                        SymbolIcon("exclamationmark.shield").font(.system(size: 12))
                        Text("Skips permissions").lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioStyle.Tone.waiting.text)
                    .padding(.leading, 18)
                    .help("Started with all permission checks skipped")
                }
                if !place.isEmpty {
                    Text(verbatim: place)
                        .font(.system(size: 11)).foregroundStyle(HostedList.caption)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered && action != nil ? StudioStyle.hover : Color.clear))
        .padding(.leading, flat ? 0 : 16)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { action?() }
        .help(word)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([kind, word, text].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var line: Text {
        let name = Text(verbatim: kind).fontWeight(.semibold)
        guard !text.isEmpty else { return name }
        let rest = toned ? Text(verbatim: text).fontWeight(.semibold).foregroundStyle(StudioStyle.Tone.waiting.text) : Text(verbatim: text)
        return name + Text(verbatim: " · ") + rest
    }
}

extension AgentRow where Trailing == EmptyView {
    init(mark: TerminalTabMark, word: String, kind: String, text: String = "", skips: Bool = false, place: String = "", flat: Bool = false, action: (() -> Void)? = nil) {
        self.init(mark: mark, word: word, kind: kind, text: text, skips: skips, place: place, flat: flat, action: action) { EmptyView() }
    }
}

private struct SessionRow: View {
    @Environment(RepoStore.self) private var store
    let session: AgentSession
    var place: String = ""
    var flat = false

    var body: some View {
        let agents = AgentCenter.shared
        let inApp = agents.runsInApp(session)
        AgentRow(mark: session.status.mark, word: session.status.title, kind: session.kind.title, text: session.task,
                 skips: session.kind.skipsPermissions(session.mode), place: place, flat: flat,
                 action: session.status == .ended ? nil : { agents.focus(session) })
        .contextMenu {
            Button(inApp ? "Go to terminal" : "Go to Terminal window") { agents.focus(session) }
                .disabled(session.status == .ended)
            Button("New session in the same place") { store.startAgent(in: session.path, kind: session.kind) }
            Divider()
            if session.status == .ended {
                Button("Remove from list") { agents.remove(id: session.id) }
            } else {
                Button("End session…", role: .destructive) {
                    store.confirm = ConfirmRequest(title: String(localized: "End the \(session.kind.title) session?"),
                                                   message: session.task.isEmpty ? session.path : session.task,
                                                   actionTitle: String(localized: "End")) { agents.stop(session) }
                }
            }
        }
    }
}

/// An agent typed into a tab of the terminal below (not started from here); clicking goes to that tab
private struct TerminalAgentRow: View {
    let agent: ExternalAgent
    let root: String

    var body: some View {
        AgentRow(mark: .ring, word: String(localized: "Running"), kind: agent.kind.title,
                 place: ExternalAgents.relativeFolder(agent.cwd, in: root), action: { ExternalAgents.bringForward(agent) })
        .contextMenu {
            Button("Go to terminal") { ExternalAgents.bringForward(agent) }
            Button("Copy folder path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(agent.cwd, forType: .string) }
        }
    }
}

/// An agent running in another app; the button brings that app (and in Terminal or iTerm its tab) to the front
private struct ExternalAgentRow: View {
    let agent: ExternalAgent
    let root: Worktree?

    var body: some View {
        AgentRow(mark: .ring, word: String(localized: "Running"), kind: agent.kind.title, text: String(localized: "Running"), toned: true,
                 place: place, flat: true, action: { ExternalAgents.bringForward(agent) }) {
            Button { ExternalAgents.bringForward(agent) } label: { DesignIconImage(icon: .external, size: 13) }
                .buttonStyle(PullRequestIconButtonStyle())
                .help("Bring \(agent.hostName) to the front")
                .accessibilityLabel("Bring \(agent.hostName) to the front")
        }
        .contextMenu {
            Button("Bring \(agent.hostName) to the front") { ExternalAgents.bringForward(agent) }
            Button("Copy folder path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(agent.cwd, forType: .string) }
        }
    }

    /// "branch · sub/folder"
    private var place: String {
        guard let root else { return (agent.cwd as NSString).abbreviatingWithTildeInPath }
        let rel = ExternalAgents.relativeFolder(agent.cwd, in: root.path)
        return [root.branch ?? (root.path as NSString).lastPathComponent, rel].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - 세션 시작

struct StartAgentSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let presetPath: String?
    private let tools = ToolStore.shared

    /// 빈 문자열 = 새 워크트리 만들기
    @ViewState private var target = ""
    @ViewState private var kind: AgentKind = AgentCenter.shared.defaultKind
    @ViewState private var newBranch = ""
    @ViewState private var task = ""
    @ViewState private var mode = ""
    @ViewState private var riskAccepted = false

    var body: some View {
        SharedSheet(title: String(localized: "Start agent session"), context: store.name, width: 580,
                    primary: SheetPrimary(title: String(localized: "Start"), disabledReason: blocked) { start() },
                    cancel: { dismiss() }) {
            Form {
                Picker("Agents", selection: $kind) {
                    ForEach(AgentKind.allCases) { k in
                        Text(tools.path(k.tool) == nil ? String(localized: "\(k.title) (none)") : k.title).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                if tools.path(kind.tool) == nil {
                    Text("Couldn't find the \(kind.title) executable. Locate it in Settings (⌘,) > Tools or install it.")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("Where to work", selection: $target) {
                    ForEach(store.worktrees) { w in
                        Text(label(w)).tag(w.path)
                    }
                    Divider()
                    Text("Create new worktree…").tag("")
                }
                if target.isEmpty {
                    TextField("New branch name", text: $newBranch, prompt: Text("feature/ai-work"))
                    LabeledContent("Location", value: newBranch.trimmed.isEmpty ? "-" : (store.defaultWorktreePath(for: newBranch.trimmed) as NSString).abbreviatingWithTildeInPath)
                }
                TextField("Task", text: $task, prompt: Text("e.g. add a lockout after failed logins, including tests"), axis: .vertical)
                    .lineLimit(3...6)
                Picker("Permission mode", selection: $mode) {
                    ForEach(kind.modes, id: \.0) { m in Text(m.1).tag(m.0) }
                }
                if kind.skipsPermissions(mode) {
                    Text("The agent runs commands and changes files without asking first. Use it only for tasks you trust, ideally in a separate worktree.")
                        .font(.caption).foregroundStyle(.red)
                    Toggle("I understand the risk", isOn: $riskAccepted)
                        .toggleStyle(.checkbox)
                }
                Text(AgentCenter.Place.current == .app
                     ? "Runs in a new tab of the terminal below; its status is shown in the Agents tab."
                     : "Runs in a new Terminal window; its status is shown in the Agents tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
        .onAppear {
            target = presetPath ?? store.url?.path ?? store.worktrees.first?.path ?? ""
        }
        .onChange(of: kind) { _, _ in mode = "" }
        .onChange(of: mode) { _, _ in riskAccepted = false }
    }

    /// The first thing that keeps Start from working, said beside it
    private var blocked: String? {
        if tools.path(kind.tool) == nil { return String(localized: "Agent executable not found") }
        if target.isEmpty && !validBranch { return String(localized: "Enter a new branch name") }
        if kind.skipsPermissions(mode) && !riskAccepted { return String(localized: "Confirm the risk first") }
        return nil
    }

    private var validBranch: Bool {
        let b = newBranch.trimmed
        return !b.isEmpty && !b.contains(" ") && !b.hasPrefix("-") && !FileManager.default.fileExists(atPath: store.defaultWorktreePath(for: b))
    }

    private func label(_ w: Worktree) -> String {
        let name = w.branch ?? String(localized: "Detached HEAD")
        return w.path == store.url?.path ? String(localized: "\(name)  (opened here)") : name
    }

    private func start() {
        let path = target, branch = newBranch.trimmed, t = task, m = mode.isEmpty ? nil : mode, k = kind
        dismiss()
        if path.isEmpty {
            let wtPath = store.defaultWorktreePath(for: branch)
            Task {
                await store.addWorktree(path: wtPath, branch: branch, createNew: true, start: nil, launchClaude: false, task: "")
                if FileManager.default.fileExists(atPath: wtPath) {
                    store.startAgent(in: wtPath, task: t, permissionMode: m, kind: k)
                }
            }
        } else {
            store.startAgent(in: path, task: t, permissionMode: m, kind: k)
        }
    }
}
