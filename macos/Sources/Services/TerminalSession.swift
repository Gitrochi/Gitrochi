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
    /// A command or program runs in it (the tab's ring): the shell is not the terminal's foreground process, or the tab
    /// runs a program in place of the shell
    private(set) var busy = false

    @ObservationIgnored private var relay: Relay?
    /// The session in the terminal host while the tab runs there; nil when the app runs the shell itself
    private(set) var hostID: String?
    @ObservationIgnored private var hostPID: Int32?
    @ObservationIgnored private var hostRelay: HostRelay?
    /// The host session to take up on the first start (a tab restored after a relaunch)
    @ObservationIgnored private var resumeID: String?
    /// The repository whose panel the tab is in: a relaunched app restores it there
    let repository: String?
    /// The host session the tab shows, or will take up when it starts
    var hostSession: String? { hostID ?? resumeID }
    @ObservationIgnored private var shellTitle: String?
    @ObservationIgnored private var refreshScheduled = false
    /// Output came while a refresh was already scheduled; a command started in that window is seen by one more refresh
    @ObservationIgnored private var outputWhileScheduled = false

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

    init(directory: String, command: Command? = nil, repository: String? = nil, resume: String? = nil) {
        self.directory = directory
        self.command = command
        self.repository = repository
        self.resumeID = resume
        self.title = URL(fileURLWithPath: directory).lastPathComponent
        view = ShellView(frame: NSRect(x: 0, y: 0, width: 640, height: 260))
        _ = ShellView.controlReturnMonitor
        _ = ShellView.clickMonitor
        let relay = Relay(owner: self)
        self.relay = relay
        view.processDelegate = relay
        view.onOutput = { [weak self] in self?.noteOutput() }
        let savedSize = UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 13
        applyFont(size: savedSize)
        view.optionAsMetaKey = false        // ⌥ 로 특수문자·한글 입력이 되도록
        applyColors(for: NSApp.effectiveAppearance)
        if let command { title = command.title }
    }

    func start() {
        exitCode = nil
        running = true
        if let id = resumeID {
            resumeID = nil
            resume(id)
        } else if TerminalHostLink.shared.enabled {
            startHosted()
        } else {
            startLocal()
        }
    }

    private func startLocal() {
        view.terminalDelegate = view
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
        if let id = hostID {
            if running, let pid = hostPID, pid > 0 {
                kill(-pid, SIGHUP)
                kill(pid, SIGHUP)
            }
            // the host reports the end and forgets the session; the tab is gone by then
            TerminalHostLink.shared.unroute(id)
            if running { TerminalHostLink.shared.perform(launch: false) { try? $0?.kill(id) } }
            hostID = nil
            hostPID = nil
            running = false
            busy = false
            return
        }
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
        busy = false
    }

    /// Lets go of a host session without ending it: the app quits and the next run takes the tab up again. A shell
    /// the app runs itself ends as before.
    func release() {
        guard let id = hostID else { return terminate() }
        TerminalHostLink.shared.unroute(id)
        hostID = nil
        hostPID = nil
        running = false
        busy = false
    }

    // MARK: Terminal host

    /// What the host runs: the shell as a login shell (-l, as Terminal does), or the program through it
    private func hostedCommand() -> (program: String, args: [String], env: [String: String]) {
        let shell = ToolPaths.shared.get(.shell) ?? Self.loginShell
        var env = Dictionary(Self.environment().compactMap { pair -> (String, String)? in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        }, uniquingKeysWith: { _, last in last })
        guard let command else { return (shell, ["-l"], env) }
        command.env.forEach { env[$0.key] = $0.value }
        let line = (["exec", Launcher.quote(command.program)] + command.args.map(Launcher.quote)).joined(separator: " ")
        return (shell, ["-l", "-i", "-c", line], env)
    }

    private var hostMeta: TerminalHostMeta {
        TerminalHostMeta(repository: repository ?? directory, directory: directory, program: command?.program, args: command?.args,
                         env: command?.env, title: command?.title)
    }

    /// Sends typing and size changes to the host and its output to the view
    private func connectHost(_ id: String) {
        hostID = id
        let relay = HostRelay(view: view, id: id)
        hostRelay = relay
        view.terminalDelegate = relay
        TerminalHostLink.shared.route(id, .init(output: { [weak self] bytes in
            guard let self, self.hostID == id else { return }
            self.view.feed(byteArray: ArraySlice([UInt8](bytes)))
            self.noteOutput()
        }, exited: { [weak self] code in
            guard let self, self.hostID == id else { return }
            self.hostPID = nil
            self.processEnded(code)
        }))
    }

    private func startHosted() {
        let id = UUID().uuidString
        connectHost(id)
        let (program, args, env) = hostedCommand()
        let terminal = view.getTerminal()
        let cols = terminal.cols, rows = terminal.rows, cwd = directory, meta = hostMeta.json, pidFile = command?.pidFile
        TerminalHostLink.shared.perform(launch: true) { [weak self] client in
            let result: Result<Int32?, Error>? = client.map { c in
                Result { try c.spawn(id: id, program: program, args: args, cwd: cwd, env: env, cols: cols, rows: rows, meta: meta) }
                    .flatMap { pid in Result { _ = try c.attach(id); return pid } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.hostID == id else { return }
                    switch result {
                    case .success(let pid)?:
                        self.hostPID = pid
                        if let pidFile, let pid, pid > 0 { try? String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8) }
                        self.refreshInfo()
                    case .failure?, nil:
                        // no host, or it could not start the program: run the shell in the app as before
                        TerminalHostLink.shared.unroute(id)
                        self.hostID = nil
                        self.hostRelay = nil
                        self.startLocal()
                    }
                }
            }
        }
    }

    /// Takes up a session the host kept: its output so far, then what follows. Starting again later runs anew.
    private func resume(_ id: String) {
        connectHost(id)
        let terminal = view.getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        TerminalHostLink.shared.perform(launch: false) { [weak self] client in
            let result = client.map { c in
                Result { () -> TerminalHostClient.Session in
                    let session = try c.attach(id)
                    if session.running, (session.cols, session.rows) != (cols, rows) { try? c.resize(id, cols: cols, rows: rows) }
                    return session
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.hostID == id else { return }
                    switch result {
                    case .success(let session)?:
                        self.hostPID = session.pid
                        self.refreshInfo()
                    case .failure?, nil:
                        TerminalHostLink.shared.unroute(id)
                        self.hostID = nil
                        self.processEnded(nil)
                    }
                }
            }
        }
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

    /// Dictation and command shortcuts only fill the input; the user submits it in the terminal.
    func insertText(_ text: String) {
        let text = TerminalInput.singleLine(text)
        guard running, !text.isEmpty else { return }
        view.insertText(text)
    }

    func applyFont(size: Double) {
        let size = size.isFinite ? min(22, max(10, size)) : 13
        guard view.font.pointSize != size else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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

    static let background = NSColor.textBackgroundColor

    /// 실행 중인 프로그램(셸 자신이 아니면). 닫기 전에 물어볼 때 쓴다.
    var foregroundProgram: String? {
        guard running else { return nil }
        if hostID != nil {
            // the host holds the terminal; the shell's process info names the terminal's foreground group
            guard let pid = hostPID, pid > 0, let pgid = Self.terminalForeground(pid), pgid != pid else { return nil }
            return Self.processName(pgid)
        }
        guard let p = view.process, p.childfd >= 0 else { return nil }
        let pgid = tcgetpgrp(p.childfd)
        guard pgid > 0, pgid != p.shellPid else { return nil }
        return Self.processName(pgid)
    }

    /// The shell's pid while it runs; an agent typed into this tab has it as an ancestor
    var shellPID: Int32? {
        guard running, let pid = hostID != nil ? hostPID : view.process?.shellPid, pid > 0 else { return nil }
        return pid
    }

    static func terminalForeground(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tpgid > 0 else { return nil }
        return pid_t(info.e_tpgid)
    }

    // MARK: 상태 갱신

    fileprivate func setShellTitle(_ t: String) {
        shellTitle = t.trimmed.isEmpty ? nil : t.trimmed
        refreshInfo()
    }

    fileprivate func processEnded(_ code: Int32?) {
        running = false
        busy = false
        exitCode = code
    }

    /// 출력이 쏟아질 때마다 확인하지 않도록 0.4초에 한 번만
    private func noteOutput() {
        if !isVisible, !unseenOutput { unseenOutput = true }
        guard !refreshScheduled else {
            outputWhileScheduled = true
            return
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshScheduled = true
        outputWhileScheduled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.refreshInfo()
                // the echo of Return can land just before the command starts; look once more after it has
                if self.outputWhileScheduled { self.scheduleRefresh() }
            }
        }
    }

    private func refreshInfo() {
        guard let pid = hostID != nil ? hostPID : view.process?.shellPid, pid > 0 else { return }
        if let cwd = Self.currentDirectory(pid), cwd != directory { directory = cwd }
        let name = shellTitle ?? foregroundProgram ?? command?.title ?? URL(fileURLWithPath: directory).lastPathComponent
        if name != title { title = name }
        let nowBusy = running && (command != nil || foregroundProgram != nil)
        if nowBusy != busy { busy = nowBusy }
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
    nonisolated static func environment() -> [String] {
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

/// The view's delegate while the host runs the tab: typing and size changes go to the host, the rest to the view as
/// it handles them for a shell of its own (LocalProcessTerminalView's sizeChanged only talks to its own process)
private final class HostRelay: NSObject, TerminalViewDelegate {
    weak var view: ShellView?
    let id: String
    init(view: ShellView, id: String) {
        self.view = view
        self.id = id
    }

    private var own: TerminalViewDelegate? { view }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let id = id, bytes = Data(data)
        TerminalHostLink.shared.perform(launch: false) { try? $0?.input(id, bytes) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let id = id
        TerminalHostLink.shared.perform(launch: false) { try? $0?.resize(id, cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) { own?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { own?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func scrolled(source: TerminalView, position: Double) { own?.scrolled(source: source, position: position) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { own?.requestOpenLink(source: source, link: link, params: params) }
    func bell(source: TerminalView) { own?.bell(source: source) }
    func clipboardCopy(source: TerminalView, content: Data) { own?.clipboardCopy(source: source, content: content) }
    func clipboardRead(source: TerminalView) -> Data? { own?.clipboardRead(source: source) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { own?.iTermContent(source: source, content: content) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { own?.rangeChanged(source: source, startY: startY, endY: endY) }
}

/// 출력이 올 때 알려 주는 터미널 뷰
final class ShellView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    /// Takes a ⌘-clicked link or word (a URL or a file path); false leaves it to the default handler
    var onOpenLink: ((String) -> Bool)?
    /// Opens a path with spaces when that file exists; false when it does not
    var onOpenFile: ((String) -> Bool)?
    private var linkTaken = false

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if linkTaken { return }
        linkTaken = true
        if onOpenLink?(link) == true { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    /// SwiftTerm finds paths only with a ./, ../, ~/ or / prefix and ends them at a space; a ⌘-click first tries a
    /// path with spaces through the pointer, then on a bare name such as `schema.sql` or `src/app.ts` (ls, git status)
    /// offers the word under the pointer
    override func mouseUp(with event: NSEvent) {
        linkTaken = false
        let command = event.modifierFlags.contains(.command) && event.clickCount == 1 && !selectionActive
        let point = convert(event.locationInWindow, from: nil)
        if command, let (before, after) = text(at: point) {
            linkTaken = TerminalWord.spanned(before: before, after: after).contains { onOpenFile?($0) == true }
        }
        super.mouseUp(with: event)
        guard command, !linkTaken, let (before, after) = text(at: point),
              let word = TerminalWord.around(before: before, after: after) else { return }
        _ = onOpenLink?(word)
    }

    /// The line's text before and from the cell under the point, read from the visible buffer. The cell size is worked
    /// out the way SwiftTerm does (computeFontDimensions), since its own hit test is internal to the module.
    private func text(at point: CGPoint) -> (String, String)? {
        let scale = window?.backingScaleFactor ?? 2
        let ct = font as CTFont
        let cellHeight = ceil(ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * scale) / scale
        let cellWidth = (font.advancement(forGlyph: font.glyph(withName: "W")).width * scale).rounded() / scale
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let terminal = getTerminal()
        let col = Int(point.x / cellWidth), row = Int((frame.height - point.y) / cellHeight)
        guard col >= 0, col < terminal.cols, let line = terminal.getLine(row: row) else { return nil }
        let before = line.translateToString(trimRight: false, startCol: 0, endCol: col)
        let after = line.translateToString(trimRight: true, startCol: col, endCol: terminal.cols)
        return (before, after)
    }

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

    /// Reviewed input cannot carry terminal control characters or a submit key.
    func insertText(_ text: String) {
        type(TerminalInput.singleLine(text))
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
        } else if terminals.isEmpty && browsers.isEmpty {
            newTerminal()
        } else {
            showTerminal = true
        }
    }

    private func makeTerminal(in dir: String, command: TerminalSession.Command?, resume: String? = nil) -> TerminalSession {
        let s = TerminalSession(directory: dir, command: command, repository: url?.path, resume: resume)
        wire(s)
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

    /// Tabs of this repository's terminals that outlived an earlier run of the app (the terminal host kept them)
    func restoreHostTerminals(then done: (@MainActor () -> Void)? = nil) {
        guard let path = url?.path else { done?(); return }
        TerminalHostLink.shared.perform(launch: false) { client in
            let sessions = (try? client?.list()) ?? []
            let found = sessions.compactMap { s in TerminalHostMeta(s.meta).map { (id: s.id, meta: $0) } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    defer { done?() }
                    guard let self, self.url?.path == path else { return }
                    let shown = Set(self.terminals.compactMap(\.hostSession))
                    for (id, meta) in found where !shown.contains(id) && RepoStore.samePath(meta.repository, path) {
                        let command = meta.program.map {
                            TerminalSession.Command(program: $0, args: meta.args ?? [], env: meta.env ?? [:], title: meta.title ?? URL(fileURLWithPath: $0).lastPathComponent)
                        }
                        let focused = self.terminalLayout?.pane(of: self.activeTerminalID)?.id
                        let s = self.makeTerminal(in: meta.directory, command: command, resume: id)
                        self.terminalLayout = TerminalNode.adding(s.id, to: focused, in: self.terminalLayout)
                        s.start()
                    }
                }
            }
        }
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
        terminals.removeAll { $0.id == s.id }
        removeTab(s.id)
    }

    /// Takes a closed terminal or browser tab out of its pane
    func removeTab(_ id: UUID) {
        let sibling = terminalLayout?.pane(of: id)?.sessions.first { $0 != id }
        terminalLayout = terminalLayout?.removing(id)
        if activeTerminalID == id {
            // stay in the same pane if it still has tabs, otherwise move to the first pane
            activeTerminalID = (terminalLayout?.pane(of: sibling) ?? terminalLayout?.panes.first)?.selected ?? terminals.last?.id
        }
        if terminals.isEmpty && browsers.isEmpty { showTerminal = false }
    }

    func closeAllTerminals() {
        // quitting leaves the host's terminals running for the next launch
        let quitting = Workspace.shared.isTerminating
        terminals.forEach { quitting ? $0.release() : $0.terminate() }
        browsers.forEach { $0.close() }
        releaseTerminals()
    }

    /// Lets go of the terminals without ending them: the tab closed with the last window while Gitrochi keeps running
    /// in the menu bar, and Workspace holds them until the repository opens again
    func releaseTerminals() {
        terminals.forEach { $0.isVisible = false }
        terminals = []
        browsers = []
        terminalLayout = nil
        activeTerminalID = nil
        showTerminal = false
    }

    /// Takes back terminals that kept running while the repository had no window, with their panes as they were
    func adoptTerminals(_ sessions: [TerminalSession], browsers kept: [BrowserSession] = [], layout: TerminalNode?, active: UUID?, shown: Bool) {
        guard !sessions.isEmpty || !kept.isEmpty else { return }
        sessions.forEach(wire)
        if terminals.isEmpty && browsers.isEmpty {
            terminalLayout = layout
        } else {
            for id in sessions.map(\.id) + kept.map(\.id) { terminalLayout = TerminalNode.adding(id, to: nil, in: terminalLayout) }
        }
        terminals += sessions
        browsers += kept
        activeTerminalID = active ?? sessions.last?.id ?? kept.last?.id
        showTerminal = showTerminal || shown
    }

    /// Clicking into the terminal selects its tab
    private func wire(_ s: TerminalSession) {
        s.view.onFocus = { [weak self, weak s] in
            guard let self, let s, self.activeTerminalID != s.id else { return }
            self.selectTerminal(s)
        }
        s.view.onOpenFile = { [weak self, weak s] text in
            guard let self, let s else { return false }
            var isFolder: ObjCBool = false
            guard let path = TerminalWord.file(text, in: s.directory, exists: {
                FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && !isFolder.boolValue
            }) else { return false }
            self.previewInBrowserTab(URL(fileURLWithPath: path), beside: s.id)
            return true
        }
        s.view.onOpenLink = { [weak self, weak s] link in
            guard let self, let s else { return false }
            if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" {
                guard BrowserAddress.opensInPanel(url) else { return false }
                self.openInBrowserTab(url, beside: s.id)
                return true
            }
            // a file the shell's folder holds opens as a preview; folders keep the default (Finder)
            var isFolder: ObjCBool = false
            if let path = TerminalWord.file(link, in: s.directory, exists: {
                FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && !isFolder.boolValue
            }) {
                self.previewInBrowserTab(URL(fileURLWithPath: path), beside: s.id)
                return true
            }
            // a bare name from `ls sub/` and the like: look below the shell's folder, off the main thread
            let directory = s.directory, id = s.id
            guard link.contains(".") || link.contains("/"), !link.contains("://") else { return false }
            Task { [weak self] in
                guard let path = await Task.detached(priority: .userInitiated, operation: { TerminalWord.search(link, in: directory) }).value else { return }
                self?.previewInBrowserTab(URL(fileURLWithPath: path), beside: id)
            }
            return true
        }
    }
}
