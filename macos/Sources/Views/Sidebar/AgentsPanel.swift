import SwiftUI
import AppKit

/// 사이드바 '에이전트' 탭: 워크트리 카드 + 그 안에서 도는 에이전트(Claude Code·Codex·Gemini CLI) 세션
struct AgentsPanel: View {
    @Environment(RepoStore.self) private var store
    private let agents = AgentCenter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Worktrees").font(.headline)
                    Text("\(store.worktrees.count)").foregroundStyle(.secondary)
                    Spacer()
                    if agents.sessions.contains(where: { $0.status == .ended }) {
                        Button("Clear ended sessions") { agents.clearEnded() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    Button { store.sheet = .addWorktree(branch: nil, start: nil) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New worktree")
                }

                HStack(spacing: 6) {
                    Button { store.sheet = .startAgent(path: nil) } label: {
                        Label("Start session", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help("Start agent session — choose Claude Code, Codex or Gemini CLI, a worktree to work in, and a task")
                    Button { if let u = store.url { store.startAgent(in: u.path) } } label: {
                        Image(systemName: "bolt.fill")
                    }
                    .controlSize(.large)
                    .help("Start \(agents.defaultKind.title) in this worktree now")
                }

                ForEach(store.worktrees) { w in
                    WorktreeCard(worktree: w,
                                 stats: store.worktreeStats[w.path],
                                 sessions: agents.sessions(in: w.path),
                                 isCurrent: AgentCenter.normalize(w.path) == AgentCenter.normalize(store.url?.path ?? ""))
                }

                let known = Set(store.worktrees.map { AgentCenter.normalize($0.path) })
                let others = agents.sessions.filter { !known.contains(AgentCenter.normalize($0.path)) && $0.status != .ended }
                if !others.isEmpty {
                    Text("Sessions in other folders").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(others) { s in
                        SessionRow(session: s, showPath: true)
                    }
                }

                Text(AgentCenter.Place.current == .app
                     ? "Sessions started here run in tabs of the terminal below, and their status is shown here. Click a session to go to its terminal."
                     : "Only sessions started here show their status. Click a session to go to its Terminal window.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(10)
        }
        .task(id: store.worktrees.map(\.path)) {
            // 다른 워크트리는 파일 감시 대상이 아니라 몇 초마다 다시 센다
            while !Task.isCancelled {
                await store.refreshWorktreeStats()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct WorktreeCard: View {
    @Environment(RepoStore.self) private var store
    let worktree: Worktree
    let stats: WorktreeStats?
    let sessions: [AgentSession]
    let isCurrent: Bool

    @ViewState private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(worktree.branch ?? String(localized: "Detached HEAD"))
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(worktree.path)
                Spacer(minLength: 4)
                if hover {
                    Button { store.sheet = .startAgent(path: worktree.path) } label: { Image(systemName: "sparkles") }
                        .buttonStyle(.borderless)
                        .help("Start an agent session in this worktree")
                }
            }

            if let stats {
                HStack(spacing: 8) {
                    if stats.isClean && stats.ahead == 0 && stats.behind == 0 {
                        Text("No changes").foregroundStyle(.secondary)
                    }
                    if stats.added > 0 { Text("+\(stats.added)").foregroundStyle(.green).help("New file") }
                    if stats.modified > 0 {
                        Label("\(stats.modified)", systemImage: "pencil").labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange).help("Modified files")
                    }
                    if stats.deleted > 0 { Text("−\(stats.deleted)").foregroundStyle(.red).help("Deleted file") }
                    if stats.conflicted > 0 { Text("!\(stats.conflicted)").foregroundStyle(.red).help("Conflict") }
                    if !stats.isClean && (stats.ahead > 0 || stats.behind > 0) { Divider().frame(height: 10) }
                    if stats.ahead > 0 { Text("↑\(stats.ahead)").foregroundStyle(.blue).help("Commits not pushed to the remote") }
                    if stats.behind > 0 { Text("↓\(stats.behind)").foregroundStyle(.orange).help("Commits not pulled from the remote") }
                }
                .font(.callout.monospacedDigit().weight(.medium))
            }

            if !sessions.isEmpty {
                Divider()
                ForEach(sessions) { s in SessionRow(session: s, showPath: false) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isCurrent ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            guard !isCurrent else { return }
            Task { await store.openOrReport(URL(fileURLWithPath: worktree.path, isDirectory: true)) }
        }
        .contextMenu {
            Button("Start agent session…") { store.sheet = .startAgent(path: worktree.path) }
            Button("Open in Gitrochi") {
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
    }
}

private struct SessionRow: View {
    @Environment(RepoStore.self) private var store
    let session: AgentSession
    let showPath: Bool

    var body: some View {
        let agents = AgentCenter.shared
        let inApp = agents.runsInApp(session)
        HStack(alignment: .top, spacing: 6) {
            StatusDot(status: session.status)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.status.title).fontWeight(.medium)
                    Text(session.kind.title).font(.caption2).foregroundStyle(.tertiary)
                    if session.kind.skipsPermissions(session.mode) {
                        Label("Skips permissions", systemImage: "exclamationmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize()
                            .help("Started with all permission checks skipped")
                    }
                    if let d = session.detail, session.status != .ended {
                        Text("· \(d)").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !session.task.isEmpty {
                    Text(session.task).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text((showPath ? (session.path as NSString).abbreviatingWithTildeInPath + " · " : "") + Fmt.short(session.updated))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onTapGesture { agents.focus(session) }
        .help(session.status == .ended ? "Ended sessions" : inApp ? "Click to go to that terminal" : "Click to go to the Terminal window")
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

private struct StatusDot: View {
    let status: AgentStatus
    @ViewState private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity((status == .working || status == .running) && pulse ? 0.35 : 1)
            .animation(status == .working || status == .running ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }

    private var color: Color {
        switch status {
        case .working, .running: return .blue
        case .permission: return .red
        case .starting, .waiting: return .orange
        case .ended: return .gray
        }
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
        VStack(alignment: .leading, spacing: 0) {
            Text("Start agent session").font(.title3.weight(.semibold)).padding([.top, .horizontal], 20)
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
            }
            .formStyle(.grouped)
            HStack {
                Text(AgentCenter.Place.current == .app
                     ? "Runs in a new tab of the terminal below; its status is shown in the Agents tab."
                     : "Runs in a new Terminal window; its status is shown in the Agents tab.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tools.path(kind.tool) == nil || (target.isEmpty && !validBranch) || (kind.skipsPermissions(mode) && !riskAccepted))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 580)
        .onAppear {
            target = presetPath ?? store.url?.path ?? store.worktrees.first?.path ?? ""
        }
        .onChange(of: kind) { _, _ in mode = "" }
        .onChange(of: mode) { _, _ in riskAccepted = false }
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
