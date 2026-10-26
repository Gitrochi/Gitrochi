import SwiftUI
import AppKit
import Darwin
import SwiftTerm

/// 그래프 아래 터미널 패널의 셸 하나. 패널을 숨겨도 셸은 계속 살아 있다.
@MainActor @Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let view: ShellView
    /// 셸의 현재 폴더(출력이 있을 때마다 확인)
    private(set) var directory: String
    /// 탭 이름: 셸이 정한 제목 > 실행 중인 프로그램 > 현재 폴더 이름
    private(set) var title: String
    private(set) var running = false
    private(set) var exitCode: Int32?
    /// 보고 있지 않을 때 새 출력이 있었는지(탭에 점 표시)
    var unseenOutput = false
    var isVisible = false

    @ObservationIgnored private var relay: Relay?
    @ObservationIgnored private var shellTitle: String?
    @ObservationIgnored private var refreshScheduled = false

    /// A program run instead of the login shell (agent sessions)
    struct Command {
        let program: String
        let args: [String]
        var env: [String: String] = [:]
        let title: String
        /// Gets the program's pid each time it starts
        var pidFile: String?
    }

    let command: Command?

    init(directory: String, command: Command? = nil) {
        self.directory = directory
        self.command = command
        self.title = URL(fileURLWithPath: directory).lastPathComponent
        view = ShellView(frame: NSRect(x: 0, y: 0, width: 640, height: 260))
        _ = ShellView.controlReturnMonitor
        _ = ShellView.clickMonitor
        let relay = Relay(owner: self)
        self.relay = relay
        view.processDelegate = relay
        view.onOutput = { [weak self] in self?.noteOutput() }
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.optionAsMetaKey = false        // ⌥ 로 특수문자·한글 입력이 되도록
        applyColors(for: NSApp.effectiveAppearance)
        if let command { title = command.title }
    }

    func start() {
        exitCode = nil
        running = true
        let shell = ToolPaths.shared.get(.shell) ?? Self.loginShell
        let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        if let command {
            // An interactive login shell sets up PATH like Terminal does (Homebrew, nvm …); exec leaves the program with the shell's pid
            let line = (["exec", Launcher.quote(command.program)] + command.args.map(Launcher.quote)).joined(separator: " ")
            view.startProcess(executable: shell, args: ["-i", "-c", line],
                              environment: Self.environment() + command.env.map { "\($0.key)=\($0.value)" },
                              execName: execName, currentDirectory: directory)
            if let pidFile = command.pidFile, let pid = view.process?.shellPid, pid > 0 {
                try? String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)
            }
        } else {
            view.startProcess(executable: shell, args: [], environment: Self.environment(), execName: execName, currentDirectory: directory)
        }
        refreshInfo()
    }

    /// 셸과 그 안에서 돌고 있는 프로그램을 끝낸다(터미널을 닫을 때처럼 SIGHUP).
    func terminate() {
        let pid = view.process?.shellPid ?? 0
        if running, pid > 0 {
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        if running {
            view.terminate()
            if pid > 0 { Self.reap(pid) }
        }
        running = false
    }

    /// SwiftTerm 은 직접 끝낸 셸을 거두지 않아 좀비로 남으므로 여기서 거둔다(2초 안에 안 끝나면 SIGKILL).
    nonisolated private static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    func focus() {
        guard let w = view.window else { return }
        w.makeFirstResponder(view)
    }

    /// 어두운/밝은 모드에 맞춘 글자·배경색(SwiftTerm 은 색을 넣을 때 한 번만 읽는다)
    func applyColors(for appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            view.nativeBackgroundColor = Self.background.usingColorSpace(.sRGB) ?? .textBackgroundColor
            view.nativeForegroundColor = NSColor.textColor.usingColorSpace(.sRGB) ?? .textColor
            view.caretColor = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
            view.selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? .selectedTextBackgroundColor
        }
    }

    static let background = NSColor(name: "terminalBackground") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1)
    }

    /// 실행 중인 프로그램(셸 자신이 아니면). 닫기 전에 물어볼 때 쓴다.
    var foregroundProgram: String? {
        guard running, let p = view.process, p.childfd >= 0 else { return nil }
        let pgid = tcgetpgrp(p.childfd)
        guard pgid > 0, pgid != p.shellPid else { return nil }
        return Self.processName(pgid)
    }

    // MARK: 상태 갱신

    fileprivate func setShellTitle(_ t: String) {
        shellTitle = t.trimmed.isEmpty ? nil : t.trimmed
        refreshInfo()
    }

    fileprivate func processEnded(_ code: Int32?) {
        running = false
        exitCode = code
    }

    /// 출력이 쏟아질 때마다 확인하지 않도록 0.4초에 한 번만
    private func noteOutput() {
        if !isVisible, !unseenOutput { unseenOutput = true }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refreshInfo()
            }
        }
    }

    private func refreshInfo() {
        guard let p = view.process, p.shellPid > 0 else { return }
        if let cwd = Self.currentDirectory(p.shellPid), cwd != directory { directory = cwd }
        let name = shellTitle ?? foregroundProgram ?? command?.title ?? URL(fileURLWithPath: directory).lastPathComponent
        if name != title { title = name }
    }

    // MARK: 셸·환경

    nonisolated static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    /// Finder 에서 띄운 앱은 환경 변수가 거의 없으므로 터미널에 필요한 것만 채운다(PATH 등은 로그인 셸이 읽는다).
    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_SESSION_ID", "__CFBundleIdentifier", "XPC_SERVICE_NAME"] {
            env.removeValue(forKey: k)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Gitrochi"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if env["LANG"] == nil {
            env["LANG"] = Locale.current.language.languageCode?.identifier == "ko" ? "ko_KR.UTF-8" : "en_US.UTF-8"
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["SHELL"] == nil { env["SHELL"] = loginShell }
        return env.map { "\($0.key)=\($0.value)" }
    }

    static func currentDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            let s = String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            return s.isEmpty ? nil : s
        }
    }

    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }
}

/// SwiftTerm 콜백(메인 큐에서 온다)을 세션으로 넘긴다
private final class Relay: NSObject, LocalProcessTerminalViewDelegate {
    weak var owner: TerminalSession?
    init(owner: TerminalSession) { self.owner = owner }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { owner?.setShellTitle(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated { owner?.processEnded(exitCode) }
    }
}

/// 출력이 올 때 알려 주는 터미널 뷰
final class ShellView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?

    /// macOS treats Control-Return as "open the context menu", so the graph would take it as a key equivalent
    /// before the terminal sees it. While a terminal has focus, hand it straight to the terminal
    /// (Claude Code reads it as "send now" through the kitty keyboard protocol).
    static let controlReturnMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.command), let view = event.window?.firstResponder as? ShellView else { return event }
        view.keyDown(with: event)
        return nil
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    // MARK: Files dropped or pasted go in as paths, like Terminal.app

    private static let pathTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.pathTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.pathTypes)
    }

    /// ⌘V with files or an image on the clipboard types their paths (an image is saved as a PNG in the temp folder first)
    override func paste(_ sender: Any) {
        if let text = Self.pathsText(NSPasteboard.general) { type(text) } else { super.paste(sender) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasPaths(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = Self.pathsText(sender.draggingPasteboard) else { return false }
        type(text)
        window?.makeFirstResponder(self)
        onFocus?()
        return true
    }

    /// Sent as a paste, so a program in bracketed-paste mode (zsh, Claude Code) takes it as one piece
    private func type(_ text: String) {
        if terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[...])
            send(txt: text)
            send(data: EscapeSequences.bracketedPasteEnd[...])
        } else {
            send(txt: text)
        }
    }

    private static func hasPaths(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || (pb.string(forType: .string) == nil && NSImage.canInit(with: pb))
    }

    /// The paths on the pasteboard, escaped for the shell and each followed by a space; nil when it holds none
    private static func pathsText(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { shellEscape($0.path) + " " }.joined()
        }
        // an image with no text: a screenshot, or a picture copied from a browser
        guard pb.string(forType: .string) == nil, let path = saveImage(pb) else { return nil }
        return shellEscape(path) + " "
    }

    private static func saveImage(_ pb: NSPasteboard) -> String? {
        let png = pb.data(forType: .png)
            ?? pb.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitrochi-image-\(f.string(from: Date())).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return url.path
    }

    /// Terminal.app style: a backslash before each ASCII character the shell reads specially (space, quotes, $, & …)
    static func shellEscape(_ path: String) -> String {
        path.map { ch in
            ch.isASCII && !(ch.isLetter || ch.isNumber || "_-./+,:=@%".contains(ch)) ? "\\" + String(ch) : String(ch)
        }.joined()
    }

    /// Clicking into a pane makes its terminal the focused one
    var onFocus: (() -> Void)?

    /// SwiftTerm doesn't let subclasses override becomeFirstResponder, so watch clicks instead
    static let clickMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
        guard let content = event.window?.contentView else { return event }
        var view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        while let v = view, !(v is ShellView) { view = v.superview }
        (view as? ShellView)?.onFocus?()
        return event
    }
}

// MARK: - 저장소 창과 연결

extension RepoStore {
    var activeTerminal: TerminalSession? {
        terminals.first { $0.id == activeTerminalID } ?? terminals.last
    }

    /// ⌃` : 터미널 패널 보이기/숨기기(처음이면 저장소 폴더에서 셸을 하나 연다)
    func toggleTerminal() {
        if showTerminal {
            showTerminal = false
        } else if terminals.isEmpty {
            newTerminal()
        } else {
            showTerminal = true
        }
    }

    private func makeTerminal(in dir: String, command: TerminalSession.Command?) -> TerminalSession {
        let s = TerminalSession(directory: dir, command: command)
        s.view.onFocus = { [weak self, weak s] in
            guard let self, let s, self.activeTerminalID != s.id else { return }
            self.selectTerminal(s)
        }
        terminals.append(s)
        activeTerminalID = s.id
        showTerminal = true
        return s
    }

    /// A new tab in the focused pane: a shell in path (default: the repository), or the given program in its place
    @discardableResult
    func newTerminal(in path: String? = nil, command: TerminalSession.Command? = nil) -> TerminalSession? {
        guard let dir = path ?? url?.path else { return nil }
        let focused = terminalLayout?.pane(of: activeTerminalID)?.id
        let s = makeTerminal(in: dir, command: command)
        terminalLayout = TerminalNode.adding(s.id, to: focused, in: terminalLayout)
        s.start()
        return s
    }

    /// The tab a pane shows
    func shownTerminal(in pane: TerminalNode.Pane) -> TerminalSession? {
        let id = pane.shown(active: activeTerminalID)
        return terminals.first { $0.id == id }
    }

    /// A new shell beside or below the pane, in the folder its terminal is in
    func splitTerminal(_ pane: TerminalNode.Pane, _ axis: TerminalNode.Axis) {
        guard let layout = terminalLayout, let dir = shownTerminal(in: pane)?.directory ?? url?.path else { return }
        let s = makeTerminal(in: dir, command: nil)
        terminalLayout = layout.splitting(pane.id, axis, with: s.id)
        s.start()
    }

    func resizeTerminalSplit(_ id: UUID, to ratio: Double) {
        terminalLayout = terminalLayout?.resizing(id, to: ratio)
    }

    func selectTerminal(_ s: TerminalSession) {
        activeTerminalID = s.id
        terminalLayout = terminalLayout?.selecting(s.id)
        s.unseenOutput = false
    }

    /// Brings this tab forward with the terminal shown, selected and focused
    func focusTerminal(_ s: TerminalSession) {
        guard terminals.contains(where: { $0.id == s.id }) else { return }
        selectTerminal(s)
        showTerminal = true
        window?.tabGroup?.selectedWindow = window
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.async { s.focus() }
    }

    /// 프로그램이 돌고 있으면 한 번 묻고 닫는다
    func requestCloseTerminal(_ s: TerminalSession) {
        // an agent tab runs its program in place of the shell, so ask while it runs too
        if let program = s.foregroundProgram ?? (s.running ? s.command?.title : nil) {
            confirm = ConfirmRequest(title: String(localized: "Close the terminal?"),
                                     message: String(localized: "'\(program)' is still running. Closing it will stop it."),
                                     actionTitle: String(localized: "Close")) { [weak self] in self?.closeTerminal(s) }
        } else {
            closeTerminal(s)
        }
    }

    func closeTerminal(_ s: TerminalSession) {
        s.terminate()
        let sibling = terminalLayout?.pane(of: s.id)?.sessions.first { $0 != s.id }
        terminals.removeAll { $0.id == s.id }
        terminalLayout = terminalLayout?.removing(s.id)
        if activeTerminalID == s.id {
            // stay in the same pane if it still has tabs, otherwise move to the first pane
            activeTerminalID = (terminalLayout?.pane(of: sibling) ?? terminalLayout?.panes.first)?.selected ?? terminals.last?.id
        }
        if terminals.isEmpty { showTerminal = false }
    }

    func closeAllTerminals() {
        terminals.forEach { $0.terminate() }
        terminals = []
        terminalLayout = nil
        activeTerminalID = nil
        showTerminal = false
    }
}
