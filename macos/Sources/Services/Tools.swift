import Foundation
import Observation

/// 외부 프로그램(git·AI CLI·gh·셸) 위치.
/// 사람마다 설치 위치가 달라 ① 설정에서 직접 고른 경로 → ② 흔한 설치 위치 → ③ 로그인 셸의 PATH 순서로 찾는다.
enum ToolID: String, CaseIterable, Identifiable {
    case git, claude, codex, gemini, gh, node, shell
    var id: String { rawValue }

    var title: String {
        switch self {
        case .git: return "Git"
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .gh: return "GitHub CLI (gh)"
        case .node: return "Node.js"
        case .shell: return String(localized: "Terminal shell")
        }
    }

    var detail: String {
        switch self {
        case .git: return String(localized: "Used for all repository operations.")
        case .claude: return String(localized: "Writing and agent sessions with your Claude login")
        case .codex: return String(localized: "Writing and agent sessions with your ChatGPT login")
        case .gemini: return String(localized: "Writing and agent sessions with your Google login")
        case .gh: return String(localized: "When importing the gh login as a GitHub account")
        case .node: return String(localized: "Read-only repository assistant and MCP connection (Node.js 22 or later)")
        case .shell: return String(localized: "Shell opened in the terminal panel below (zsh, bash, fish, etc.)")
        }
    }

    var install: String? {
        switch self {
        case .git: return "https://git-scm.com/download/mac"
        case .claude: return "https://claude.com/claude-code"
        case .codex: return "https://developers.openai.com/codex/cli"
        case .gemini: return "https://github.com/google-gemini/gemini-cli"
        case .gh: return "https://cli.github.com"
        case .node: return "https://nodejs.org/"
        case .shell: return nil
        }
    }

    var versionArgs: [String] { self == .shell ? [] : ["--version"] }

    /// 흔한 설치 위치
    var candidates: [String] {
        let home = NSHomeDirectory()
        let brew = ["/opt/homebrew/bin", "/usr/local/bin"]
        switch self {
        case .git: return brew.map { "\($0)/git" } + ["/usr/bin/git"]
        case .claude: return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude"] + brew.map { "\($0)/claude" }
        case .codex: return brew.map { "\($0)/codex" } + ["\(home)/.local/bin/codex"]
        case .gemini: return brew.map { "\($0)/gemini" } + ["\(home)/.local/bin/gemini"]
        case .gh: return brew.map { "\($0)/gh" } + ["/usr/bin/gh"]
        case .node: return brew.map { "\($0)/node" } + ["/usr/bin/node"]
        case .shell: return [TerminalSession.loginShell, "/bin/zsh", "/bin/bash"]
        }
    }
}

/// 백그라운드 작업(git 실행 등)에서도 읽을 수 있는 경로 표
final class ToolPaths: @unchecked Sendable {
    static let shared = ToolPaths()
    private let lock = NSLock()
    private var paths: [ToolID: String] = [:]

    func get(_ id: ToolID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return paths[id]
    }

    func set(_ id: ToolID, _ path: String?) {
        lock.lock(); defer { lock.unlock() }
        paths[id] = path
    }
}

@MainActor @Observable
final class ToolStore {
    static let shared = ToolStore()

    enum Source { case custom, auto, none }

    struct State {
        var path: String?
        var source: Source = .none
        var version: String?
    }

    private(set) var states: [ToolID: State] = [:]

    func path(_ id: ToolID) -> String? { states[id]?.path }
    func state(_ id: ToolID) -> State { states[id] ?? State() }

    private var custom: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "toolPaths") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "toolPaths") }
    }

    private init() {
        for id in ToolID.allCases { detect(id) }
        // 로그인 셸의 PATH 는 셸 설정에 따라 몇 초 걸릴 수 있어 화면 스레드 밖에서 읽고, 못 찾은 도구만 다시 찾는다
        Task.detached(priority: .utility) {
            let extra = Self.readLoginPATH()
            await MainActor.run {
                Self.loginPATH = extra
                for id in ToolID.allCases where self.states[id]?.path == nil { self.detect(id) }
            }
        }
    }

    func detect(_ id: ToolID) {
        let fm = FileManager.default
        var state = State()
        if let c = custom[id.rawValue], fm.isExecutableFile(atPath: c) {
            state.path = c
            state.source = .custom
        } else if let found = id.candidates.first(where: { fm.isExecutableFile(atPath: $0) })
                    ?? Self.pathCandidates(id).first(where: { fm.isExecutableFile(atPath: $0) }) {
            state.path = found
            state.source = .auto
        }
        states[id] = state
        ToolPaths.shared.set(id, state.path)
        if let p = state.path, !id.versionArgs.isEmpty { readVersion(id, p) }
    }

    /// 로그인 셸의 PATH(앱은 Finder 에서 켜면 PATH 가 짧다). 시작할 때 뒤에서 한 번 읽어 채운다.
    private static var loginPATH: [String] = []

    nonisolated private static func readLoginPATH() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TerminalSession.loginShell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return [] }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.split(separator: ":").map(String.init)
    }

    private static func pathCandidates(_ id: ToolID) -> [String] {
        guard id != .shell else { return [] }
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (loginPATH + env).map { "\($0)/\(id.rawValue)" }
    }

    private func readVersion(_ id: ToolID, _ path: String) {
        Task {
            guard let r = try? await Shell.run(path, id.versionArgs, cwd: FileManager.default.temporaryDirectory, timeout: 20) else { return }
            let line = (r.output.isEmpty ? r.stderr : r.output).trimmed.split(separator: "\n").first.map(String.init) ?? ""
            if states[id]?.path == path { states[id]?.version = r.status == 0 ? String(line.prefix(80)) : nil }
        }
    }

    /// 직접 고른 실행 파일로 바꾼다. 실행해 보고 안 되면 이유를 던진다.
    func setCustom(_ id: ToolID, path: String) async throws {
        let name = (path as NSString).lastPathComponent
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw GitError(command: id.rawValue, message: String(localized: "\(name) isn't an executable file."))
        }
        if !id.versionArgs.isEmpty {
            let r = try await Shell.run(path, id.versionArgs, cwd: FileManager.default.temporaryDirectory, timeout: 20)
            guard r.status == 0 else {
                throw GitError(command: id.rawValue, message: String(localized: "\(name) didn't respond correctly (exit code \(r.status)). Check that it's the \(id.title) executable."))
            }
        }
        var c = custom
        c[id.rawValue] = path
        custom = c
        detect(id)
    }

    func resetToAuto(_ id: ToolID) {
        var c = custom
        c[id.rawValue] = nil
        custom = c
        detect(id)
    }
}
