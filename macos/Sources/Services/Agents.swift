import Foundation
import AppKit
import Observation

/// 세션 상태: Claude Code 는 훅 이벤트로 자세히, 다른 에이전트는 실행 중/종료만
enum AgentStatus: String {
    case starting, working, permission, waiting, running, ended

    var title: String {
        switch self {
        case .starting: return String(localized: "Waiting for input")
        case .working: return String(localized: "Working")
        case .permission: return String(localized: "Needs permission")
        case .waiting: return String(localized: "Waiting for input")
        case .running: return String(localized: "Running")
        case .ended: return String(localized: "Ended")
        }
    }

    var isActive: Bool { self == .working || self == .permission || self == .running }
}

/// Terminal 에서 띄울 수 있는 코딩 에이전트
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, gemini
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        }
    }

    var tool: ToolID {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        }
    }

    /// 권한 모드: (값, 이름)
    var modes: [(String, String)] {
        let bypass = (bypassMode, String(localized: "Skip all permission checks"))
        switch self {
        case .claude: return [("", String(localized: "Default (ask every time)")), ("acceptEdits", String(localized: "Auto-approve file edits")), ("plan", String(localized: "Plan only")), ("auto", String(localized: "Auto")), bypass]
        case .codex: return [("", String(localized: "Default")), ("read-only", String(localized: "Read-only")), ("workspace-write", String(localized: "Allow writing to the working folder")), bypass]
        case .gemini: return [("", String(localized: "Default (ask every time)")), ("auto_edit", String(localized: "Auto-approve file edits")), ("plan", String(localized: "Plan only (read-only)")), bypass]
        }
    }

    /// The mode that skips every permission check. Never remembered; the start sheet asks for confirmation.
    var bypassMode: String {
        switch self {
        case .claude: return "bypassPermissions"
        case .codex: return "bypass"
        case .gemini: return "yolo"
        }
    }

    func skipsPermissions(_ mode: String?) -> Bool { mode == bypassMode }

    /// 실행 인자
    func arguments(hooks: String, task: String, mode: String?) -> [String] {
        let m = mode.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .claude:
            return ["--settings", hooks] + (m.map { ["--permission-mode", $0] } ?? []) + (task.isEmpty ? [] : [task])
        case .codex:
            // --sandbox danger-full-access keeps the approval prompts; this flag drops both
            if m == bypassMode { return ["--dangerously-bypass-approvals-and-sandbox"] + (task.isEmpty ? [] : [task]) }
            return (m.map { ["--sandbox", $0] } ?? []) + (task.isEmpty ? [] : [task])
        case .gemini:
            return (m.map { ["--approval-mode", $0] } ?? []) + (task.isEmpty ? [] : ["-i", task])
        }
    }
}

struct AgentSession: Identifiable, Hashable {
    let id: String
    var kind: AgentKind = .claude
    let path: String
    let task: String
    /// Permission mode it was started with ("" = default)
    var mode = ""
    let created: Date
    var pid: Int32?
    var status: AgentStatus
    var detail: String?
    var updated: Date
}

/// Gitrochi 가 띄운 에이전트(Claude Code·Codex·Gemini CLI) 세션 추적. 상태는 Claude Code 만 훅으로 자세히 본다.
///
/// 세션을 띄울 때 `--settings` 로 훅을 더해 두면(사용자 설정·훅은 그대로 유지) 각 이벤트마다
/// hook.sh 가 ~/Library/Application Support/Gitrochi/agents/<id>.state 에 마지막 상태를 쓴다.
/// 이 폴더를 지켜보다가 상태를 읽고, 프로세스가 사라졌으면 종료로 본다.
@MainActor @Observable
final class AgentCenter {
    static let shared = AgentCenter()

    private(set) var sessions: [AgentSession] = []
    let directory: URL
    private var watcher: FileWatcher?
    private var timer: Timer?

    private var hookScript: URL { directory.appendingPathComponent("hook.sh") }
    private var hooksFile: URL { directory.appendingPathComponent("hooks.json") }
    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gitrochi/agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        installHooks()
        load()
        watcher = FileWatcher(paths: [directory.path]) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
        // 터미널을 닫아 훅 없이 끝난 세션도 잡도록 주기적으로 프로세스 확인
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    func sessions(in path: String) -> [AgentSession] {
        let key = Self.normalize(path)
        return sessions.filter { Self.normalize($0.path) == key }
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: 훅 설치

    private func installHooks() {
        let script = """
        #!/bin/sh
        # Gitrochi: Claude Code 훅 이벤트를 세션 상태 파일로 남긴다(Gitrochi 가 띄운 세션만).
        [ -n "$GITROCHI_AGENT_ID" ] || exit 0
        dir="$HOME/Library/Application Support/Gitrochi/agents"
        payload=$(cat)
        [ -n "$payload" ] || payload=null
        tmp="$dir/$GITROCHI_AGENT_ID.state.tmp"
        printf '{"event":"%s","time":%s,"payload":%s}\\n' "$1" "$(date +%s)" "$payload" > "$tmp" && mv -f "$tmp" "$dir/$GITROCHI_AGENT_ID.state"
        exit 0

        """
        try? script.write(to: hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)

        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
        var hooks: [String: Any] = [:]
        for e in events {
            hooks[e] = [["matcher": "", "hooks": [["type": "command", "command": "\"\(hookScript.path)\" \(e)", "timeout": 5]]]]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: hooksFile)
        }
    }

    // MARK: 상태 읽기

    private func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func load() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var list: [AgentSession] = []
        for name in names where name.hasSuffix(".meta") {
            let id = String(name.dropLast(5))
            guard let meta = json(name) else { continue }
            let created = Date(timeIntervalSince1970: meta["created"] as? Double ?? 0)
            let pid = (try? String(contentsOf: file(id + ".pid"), encoding: .utf8)).flatMap { Int32($0.trimmed) }
            var status = AgentStatus.starting
            var detail: String?
            var updated = created

            let kind = AgentKind(rawValue: meta["kind"] as? String ?? "") ?? .claude
            // 훅이 없는 에이전트는 프로세스가 살아 있으면 실행 중
            if kind != .claude { status = .running }
            if let state = json(id + ".state") {
                updated = Date(timeIntervalSince1970: state["time"] as? Double ?? created.timeIntervalSince1970)
                let payload = state["payload"] as? [String: Any] ?? [:]
                switch state["event"] as? String {
                case "SessionStart":
                    status = .starting
                case "UserPromptSubmit":
                    status = .working
                case "PreToolUse":
                    status = .working
                    detail = payload["tool_name"] as? String
                case "PermissionRequest":
                    status = .permission
                    detail = payload["tool_name"] as? String
                case "Notification":
                    let message = payload["message"] as? String
                    status = (message?.lowercased().contains("permission") ?? false) ? .permission : .waiting
                    detail = message
                case "Stop":
                    status = .waiting
                case "SessionEnd":
                    status = .ended
                default:
                    break
                }
            }

            let alive: Bool
            if let pid {
                let r = kill(pid, 0)
                alive = r == 0 || errno == EPERM
            } else {
                alive = Date().timeIntervalSince(created) < 30   // 터미널이 뜨는 중
            }
            if !alive { status = .ended }
            if status == .ended, Date().timeIntervalSince(max(updated, created)) > 86_400 {
                remove(id: id)
                continue
            }
            list.append(AgentSession(id: id, kind: kind, path: meta["path"] as? String ?? "", task: meta["task"] as? String ?? "",
                                     mode: meta["mode"] as? String ?? "",
                                     created: created, pid: pid, status: status, detail: detail, updated: updated))
        }
        list.sort { $0.created > $1.created }
        if list != sessions { sessions = list }
    }

    // MARK: 세션 다루기

    /// 마지막으로 고른 에이전트(빠른 시작에 씀). 없으면 설치된 것 중 첫 번째.
    var defaultKind: AgentKind {
        let tools = ToolStore.shared
        if let saved = UserDefaults.standard.string(forKey: "agentKind").flatMap(AgentKind.init(rawValue:)),
           tools.path(saved.tool) != nil { return saved }
        return AgentKind.allCases.first { tools.path($0.tool) != nil } ?? .claude
    }

    /// Settings > Tools: where new sessions run
    enum Place: String, CaseIterable, Identifiable {
        case app, terminal
        var id: String { rawValue }
        static let key = "agentTerminal"
        static var current: Place { UserDefaults.standard.string(forKey: key).flatMap(Place.init(rawValue:)) ?? .app }
    }

    private final class TerminalLink {
        weak var session: TerminalSession?
        weak var store: RepoStore?
        init(_ session: TerminalSession, _ store: RepoStore) { self.session = session; self.store = store }
    }

    /// Sessions running in a tab of a Gitrochi terminal panel; the rest are in Terminal.app
    @ObservationIgnored private var inApp: [String: TerminalLink] = [:]

    func runsInApp(_ s: AgentSession) -> Bool { inApp[s.id]?.session != nil }

    /// 폴더에서 에이전트를 띄운다 — host 저장소 탭 아래 터미널의 새 탭(기본) 또는 새 Terminal 창. task 가 있으면 첫 요청으로 보낸다.
    func start(_ kind: AgentKind, in path: String, task: String, permissionMode: String? = nil, host: RepoStore? = nil) throws {
        guard let exe = ToolStore.shared.path(kind.tool) else {
            throw AIError.notConfigured(String(localized: "Couldn't find \(kind.title). Locate the executable in Settings > Tools or install it."))
        }
        UserDefaults.standard.set(kind.rawValue, forKey: "agentKind")
        let id = UUID().uuidString.lowercased()
        let meta: [String: Any] = ["id": id, "kind": kind.rawValue, "path": path, "task": task.trimmed, "mode": permissionMode ?? "",
                                   "created": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: meta).write(to: file(id + ".meta"))
        let args = kind.arguments(hooks: hooksFile.path, task: task.trimmed, mode: permissionMode)
        let env = ["GITROCHI_AGENT_ID": id], pidFile = file(id + ".pid").path
        if let host, Place.current == .app,
           let session = host.newTerminal(in: path, command: .init(program: exe, args: args, env: env, title: kind.title, pidFile: pidFile)) {
            inApp[id] = TerminalLink(session, host)
        } else {
            try Launcher.run(exe, args: args, in: path, env: env, pidFile: pidFile)
        }
        load()
    }

    /// 세션이 돌고 있는 터미널 탭을 앞으로 가져온다(Terminal.app 이면 처음 한 번 Terminal 제어 허용을 묻는다).
    func focus(_ s: AgentSession) {
        if let link = inApp[s.id], let session = link.session, let store = link.store {
            store.focusTerminal(session)
            return
        }
        guard let pid = s.pid, s.status != .ended else { return }
        Task {
            let r = try? await Shell.run("/bin/ps", ["-o", "tty=", "-p", String(pid)], cwd: directory)
            let tty = r?.output.trimmed ?? ""
            guard !tty.isEmpty, tty != "??" else { return }
            let source = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "/dev/\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error != nil, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
            }
        }
    }

    func stop(_ s: AgentSession) {
        if let pid = s.pid { kill(pid, SIGTERM) }
        load()
    }

    func remove(id: String) {
        for ext in [".meta", ".state", ".pid", ".state.tmp"] {
            try? FileManager.default.removeItem(at: file(id + ext))
        }
        inApp[id] = nil
        sessions.removeAll { $0.id == id }
    }

    func clearEnded() {
        for s in sessions where s.status == .ended { remove(id: s.id) }
    }
}
