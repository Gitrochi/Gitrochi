import AppKit
import Darwin

/// An agent process Gitrochi did not start (Claude Code, Codex or Gemini CLI run in cmux, Terminal, iTerm, an editor…
/// or typed into Gitrochi's own terminal), found by its executable name and working directory. (Windows: entities/agent/lib/external-agents.ts, src-tauri/src/agents.rs)
struct ExternalAgent: Identifiable, Hashable {
    let pid: Int32
    let kind: AgentKind
    let cwd: String
    /// "ttys004" for a terminal tab, nil otherwise
    let tty: String?
    let started: Date?
    /// The app that runs it: the first ancestor process that is a regular app
    let hostPID: Int32?
    let hostName: String
    let hostBundleID: String?
    /// The shell of the Gitrochi terminal tab it was typed into; nil when another app runs it
    var terminalPID: Int32? = nil
    var id: Int32 { pid }
}

enum ExternalAgents {
    /// What a scan reads from a process; the host app is resolved afterwards on the main actor
    struct Raw: Sendable {
        let pid: Int32
        let kind: AgentKind
        let cwd: String
        let tty: String?
        let started: Date?
        /// Parent first, up to launchd
        let ancestors: [Int32]
    }

    static func kind(forExecutable name: String) -> AgentKind? {
        switch name {
        case "claude": return .claude
        case "codex": return .codex
        case "gemini": return .gemini
        default: return nil
        }
    }

    /// Whether a working directory lies in one of the folders (a worktree root or below it)
    static func isInside(_ cwd: String, roots: [String]) -> Bool {
        let path = AgentCenter.normalize(cwd)
        return roots.contains { root in
            let r = AgentCenter.normalize(root)
            return path == r || path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
    }

    /// The working directory below its root ("" for the root itself) (Windows: relativeFolder)
    static func relativeFolder(_ cwd: String, in root: String) -> String {
        String(AgentCenter.normalize(cwd).dropFirst(AgentCenter.normalize(root).count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Reads the process table (same-user processes only; others fail quietly). Runs off the main thread.
    static func scan() -> [Raw] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var found: [Raw] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let kind = kind(of: pid), let cwd = workingDirectory(of: pid) else { continue }
            let info = bsdInfo(pid)
            var tty: String?
            if let dev = info?.e_tdev, dev != UInt32.max, dev != 0, let n = devname(dev_t(bitPattern: dev), mode_t(S_IFCHR)) {
                tty = String(cString: n)
            }
            let started = info.map { Date(timeIntervalSince1970: TimeInterval($0.pbi_start_tvsec)) }
            found.append(Raw(pid: pid, kind: kind, cwd: cwd, tty: tty, started: started, ancestors: ancestors(of: pid)))
        }
        return found
    }

    /// The native Claude Code binary is named after its version (…/claude/versions/2.1.311);
    /// npm installs run under node with the package in the arguments
    static func kind(of pid: pid_t) -> AgentKind? {
        let name = name(of: pid)
        if let kind = kind(forExecutable: name) { return kind }
        if executablePath(of: pid).contains("/claude/versions/") { return .claude }
        guard name == "node" || name == "bun" else { return nil }
        return kind(forArguments: arguments(of: pid))
    }

    static func kind(forArguments args: [String]) -> AgentKind? {
        for arg in args.dropFirst() {
            if arg.contains("@anthropic-ai/claude-code") || arg.hasSuffix("/bin/claude") { return .claude }
            if arg.contains("@openai/codex") || arg.hasSuffix("/bin/codex") { return .codex }
            if arg.contains("@google/gemini-cli") || arg.hasSuffix("/bin/gemini") { return .gemini }
        }
        return nil
    }

    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// argv from KERN_PROCARGS2: argc, the executable path, padding, then the arguments
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var args: [String] = []
        while index < size, args.count < argc {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// The parent from the kernel process table, which also answers for root-owned processes such as login
    private static func parent(of pid: pid_t) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func ancestors(of pid: pid_t) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        for _ in 0..<16 {
            guard let parent = parent(of: current), parent > 1, !chain.contains(parent) else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// The first ancestor that is a regular app. Below Gitrochi itself the ancestor right under it is a terminal tab's
    /// shell; an agent Gitrochi started directly (with no shell between) is left out.
    @MainActor static func resolve(_ raw: Raw) -> ExternalAgent? {
        let own = ProcessInfo.processInfo.processIdentifier
        for (index, pid) in raw.ancestors.enumerated() {
            if pid == own {
                guard index > 0 else { return nil }
                return ExternalAgent(pid: raw.pid, kind: raw.kind, cwd: raw.cwd, tty: raw.tty, started: raw.started,
                                     hostPID: own, hostName: "Gitrochi", hostBundleID: Bundle.main.bundleIdentifier,
                                     terminalPID: raw.ancestors[index - 1])
            }
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return ExternalAgent(pid: raw.pid, kind: raw.kind, cwd: raw.cwd, tty: raw.tty, started: raw.started,
                                 hostPID: pid, hostName: app.localizedName ?? app.bundleIdentifier ?? "?", hostBundleID: app.bundleIdentifier)
        }
        return ExternalAgent(pid: raw.pid, kind: raw.kind, cwd: raw.cwd, tty: raw.tty, started: raw.started,
                             hostPID: nil, hostName: String(localized: "Unknown app"), hostBundleID: nil)
    }

    /// The open terminal tab an agent was typed into, and the repository tab it belongs to
    @MainActor static func terminal(of agent: ExternalAgent) -> (store: RepoStore, session: TerminalSession)? {
        guard let shell = agent.terminalPID else { return nil }
        for store in Workspace.shared.openRepositories {
            if let session = store.terminals.first(where: { $0.shellPID == shell }) { return (store, session) }
        }
        return nil
    }

    /// Brings the app that runs the agent to the front; Terminal and iTerm also select the agent's tab,
    /// and an agent in Gitrochi's own terminal gets its tab selected and focused
    @MainActor static func bringForward(_ agent: ExternalAgent) {
        if agent.terminalPID != nil {
            if let found = terminal(of: agent) { found.store.focusTerminal(found.session) }
            return
        }
        if let tty = agent.tty, let script = tabScript(bundleID: agent.hostBundleID, tty: tty) {
            // selecting the tab can fail (automation not allowed); the app still comes forward below
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
        guard let pid = agent.hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [.activateAllWindows])
    }

    private static func tabScript(bundleID: String?, tty: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal":
            return """
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
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "/dev/\(tty)" then
                                select t
                                select w
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            return nil
        }
    }
}
