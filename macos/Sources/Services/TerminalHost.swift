import Foundation
import Darwin

/// A failure the terminal host reported, or a broken connection to it
struct TerminalHostError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The terminal host's frames: a little-endian UInt32 length of the rest, a kind byte, then a JSON message (kind 0)
/// or a session id and raw terminal bytes (kind 1). crates/gitrochi-terminal/README.md
enum TerminalHostFrame {
    case control([String: Any])
    case data(id: String, bytes: Data)

    static let maxLength = 16 << 20

    func encoded() throws -> Data {
        var body = Data()
        switch self {
        case .control(let message):
            body.append(0)
            body.append(try JSONSerialization.data(withJSONObject: message))
        case .data(let id, let bytes):
            let idBytes = Data(id.utf8)
            guard idBytes.count <= Int(UInt16.max) else { throw TerminalHostError(message: "The session id is too long") }
            body.append(1)
            withUnsafeBytes(of: UInt16(idBytes.count).littleEndian) { body.append(contentsOf: $0) }
            body.append(idBytes)
            body.append(bytes)
        }
        guard body.count <= Self.maxLength else { throw TerminalHostError(message: "The frame is too large") }
        var out = Data()
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// The frame a body holds (everything after the length)
    static func decode(body: Data) throws -> TerminalHostFrame {
        let bytes = [UInt8](body)
        guard let kind = bytes.first else { throw TerminalHostError(message: "Empty frame") }
        switch kind {
        case 0:
            guard let message = try JSONSerialization.jsonObject(with: Data(bytes[1...])) as? [String: Any] else {
                throw TerminalHostError(message: "The control frame is not an object")
            }
            return .control(message)
        case 1:
            guard bytes.count >= 3 else { throw TerminalHostError(message: "The data frame is truncated") }
            let idLength = Int(bytes[1]) | Int(bytes[2]) << 8
            guard bytes.count >= 3 + idLength, let id = String(bytes: bytes[3..<3 + idLength], encoding: .utf8) else {
                throw TerminalHostError(message: "The data frame is truncated")
            }
            return .data(id: id, bytes: Data(bytes[(3 + idLength)...]))
        default:
            throw TerminalHostError(message: "Unknown frame kind")
        }
    }
}

/// One connection to a running host. Requests block until their reply; output and endings arrive through onEvent on
/// a reader thread.
final class TerminalHostClient: @unchecked Sendable {
    struct Session {
        let id: String
        let pid: Int32?
        let cols: Int
        let rows: Int
        let running: Bool
        let exitCode: Int32?
        let meta: Any?

        init?(_ json: Any?) {
            guard let o = json as? [String: Any], let id = o["id"] as? String else { return nil }
            self.id = id
            pid = (o["pid"] as? NSNumber)?.int32Value
            cols = (o["cols"] as? NSNumber)?.intValue ?? 80
            rows = (o["rows"] as? NSNumber)?.intValue ?? 24
            running = o["running"] as? Bool ?? false
            exitCode = (o["exit_code"] as? NSNumber)?.int32Value
            meta = o["meta"]
        }
    }

    enum Event {
        case output(id: String, bytes: Data)
        case exited(id: String, code: Int32?)
        case closed
    }

    static let version = 1
    static let endpointFile = "terminal-host.json"

    private let fd: Int32
    private let writing = NSLock()
    /// Held for a whole request, so each reply goes to the request that asked
    private let requesting = NSLock()
    private let replies = NSCondition()
    private var queued: [[String: Any]] = []
    private var ended = false

    /// Connects to the host named in stateDir; throws when none answers
    init(stateDir: URL, onEvent: @escaping @Sendable (Event) -> Void) throws {
        let file = stateDir.appendingPathComponent(Self.endpointFile)
        guard let data = try? Data(contentsOf: file),
              let endpoint = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = endpoint["name"] as? String, let token = endpoint["token"] as? String
        else { throw TerminalHostError(message: "No terminal host is running") }
        fd = try Self.connect(path)
        do {
            try Self.write(.control(["type": "hello", "version": Self.version, "token": token]), to: fd)
            guard case .control(let welcome)? = try Self.read(from: fd) else { throw TerminalHostError(message: "The terminal host did not answer") }
            guard welcome["type"] as? String == "welcome" else {
                throw TerminalHostError(message: welcome["message"] as? String ?? "The terminal host refused the connection")
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        let thread = Thread { [self] in readLoop(onEvent) }
        thread.name = "terminal-host-reader"
        thread.start()
    }

    deinit {
        Darwin.close(fd)
    }

    /// Says goodbye and closes; sessions keep running in the host
    func close() {
        try? send(.control(["type": "bye"]))
        shutdown(fd, SHUT_RDWR)
    }

    var isOpen: Bool {
        replies.lock()
        defer { replies.unlock() }
        return !ended
    }

    private func readLoop(_ onEvent: @Sendable (Event) -> Void) {
        while let frame = try? Self.read(from: fd) {
            switch frame {
            case .data(let id, let bytes):
                onEvent(.output(id: id, bytes: bytes))
            case .control(let message) where message["type"] as? String == "exited":
                guard let id = message["id"] as? String else { continue }
                onEvent(.exited(id: id, code: (message["exit_code"] as? NSNumber)?.int32Value))
            case .control(let message):
                replies.lock()
                queued.append(message)
                replies.signal()
                replies.unlock()
            }
        }
        replies.lock()
        ended = true
        replies.broadcast()
        replies.unlock()
        onEvent(.closed)
    }

    private func send(_ frame: TerminalHostFrame) throws {
        writing.lock()
        defer { writing.unlock() }
        try Self.write(frame, to: fd)
    }

    private func request(_ message: [String: Any]) throws -> [String: Any] {
        requesting.lock()
        defer { requesting.unlock() }
        try send(.control(message))
        replies.lock()
        defer { replies.unlock() }
        let deadline = Date().addingTimeInterval(15)
        while queued.isEmpty && !ended {
            guard replies.wait(until: deadline) else { throw TerminalHostError(message: "The terminal host did not answer") }
        }
        guard !queued.isEmpty else { throw TerminalHostError(message: "The terminal host went away") }
        let reply = queued.removeFirst()
        if reply["type"] as? String == "error" { throw TerminalHostError(message: reply["message"] as? String ?? "Terminal host error") }
        return reply
    }

    private func expectOK(_ message: [String: Any]) throws {
        guard try request(message)["type"] as? String == "ok" else { throw TerminalHostError(message: "Unexpected reply from the terminal host") }
    }

    func list() throws -> [Session] {
        ((try request(["type": "list"])["sessions"] as? [Any]) ?? []).compactMap(Session.init)
    }

    /// Starts a program in a new session; returns its process id
    func spawn(id: String, program: String, args: [String], cwd: String, env: [String: String], cols: Int, rows: Int, meta: Any) throws -> Int32? {
        let spec: [String: Any] = ["id": id, "program": program, "args": args, "cwd": cwd, "env": env, "cols": cols, "rows": rows, "meta": meta]
        return (try request(["type": "spawn", "spec": spec])["pid"] as? NSNumber)?.int32Value
    }

    /// Starts receiving a session's output: first its scrollback, then what follows, or its end when it has ended
    func attach(_ id: String) throws -> Session {
        guard let session = Session(try request(["type": "attach", "id": id])["session"]) else {
            throw TerminalHostError(message: "Unexpected reply from the terminal host")
        }
        return session
    }

    func resize(_ id: String, cols: Int, rows: Int) throws { try expectOK(["type": "resize", "id": id, "cols": cols, "rows": rows]) }
    func kill(_ id: String) throws { try expectOK(["type": "kill", "id": id]) }
    func forget(_ id: String) throws { try expectOK(["type": "forget", "id": id]) }

    /// Types into a session; not answered
    func input(_ id: String, _ bytes: Data) throws { try send(.data(id: id, bytes: bytes)) }

    // MARK: Socket

    private static func connect(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw TerminalHostError(message: "The terminal host's socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TerminalHostError(message: String(cString: strerror(errno))) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TerminalHostError(message: message)
        }
        return fd
    }

    private static func write(_ frame: TerminalHostFrame, to fd: Int32) throws {
        let data = try frame.encoded()
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw TerminalHostError(message: "The terminal host went away") }
                offset += n
            }
        }
    }

    /// The next frame, or nil when the host closed between frames
    private static func read(from fd: Int32) throws -> TerminalHostFrame? {
        guard let header = try readExactly(4, from: fd) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length <= TerminalHostFrame.maxLength else { throw TerminalHostError(message: "The frame length is out of range") }
        guard let body = try readExactly(length, from: fd) else { throw TerminalHostError(message: "The terminal host went away") }
        return try TerminalHostFrame.decode(body: body)
    }

    private static func readExactly(_ count: Int, from fd: Int32) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n < 0 && errno == EINTR { continue }
                if n == 0 && offset == 0 { return }
                guard n > 0 else { throw TerminalHostError(message: "The terminal host went away") }
                offset += n
            }
        }
        return offset == count ? data : nil
    }
}

/// What the host keeps beside a session so a relaunched app can rebuild its tab: the repository and how it started.
/// The Windows app writes the same shape (windows/src/entities/terminal/lib/host-session.ts).
struct TerminalHostMeta: Equatable {
    var repository: String
    var directory: String
    var program: String?
    var args: [String]?
    var env: [String: String]?
    var title: String?

    var json: [String: Any] {
        var spec: [String: Any] = ["directory": directory]
        if let program { spec["program"] = program }
        if let args { spec["args"] = args }
        if let env { spec["env"] = env }
        if let title { spec["title"] = title }
        return ["app": "gitrochi", "repository": repository, "spec": spec]
    }

    init(repository: String, directory: String, program: String? = nil, args: [String]? = nil, env: [String: String]? = nil, title: String? = nil) {
        self.repository = repository
        self.directory = directory
        self.program = program
        self.args = args
        self.env = env
        self.title = title
    }

    /// The meta a session came back with, when it is ours and well formed
    init?(_ value: Any?) {
        guard let m = value as? [String: Any], m["app"] as? String == "gitrochi", let repository = m["repository"] as? String,
              let spec = m["spec"] as? [String: Any], let directory = spec["directory"] as? String else { return nil }
        let present = { (key: String) in spec[key] != nil && !(spec[key] is NSNull) }
        if present("program") && !(spec["program"] is String) { return nil }
        if present("args") && !(spec["args"] is [String]) { return nil }
        if present("env") && !(spec["env"] is [String: String]) { return nil }
        if present("title") && !(spec["title"] is String) { return nil }
        self.init(repository: repository, directory: directory, program: spec["program"] as? String, args: spec["args"] as? [String],
                  env: spec["env"] as? [String: String], title: spec["title"] as? String)
    }
}

/// Terminals run in gitrochi-terminal-host (#420), so they outlive the app and a relaunched app takes them up again.
/// When the host can't be started, TerminalSession runs its shell itself as before.
final class TerminalHostLink: @unchecked Sendable {
    static let shared = TerminalHostLink()

    struct Route {
        let output: @MainActor @Sendable (Data) -> Void
        let exited: @MainActor @Sendable (Int32?) -> Void
    }

    /// Every host call runs here, in order: typing, resizes and requests never block the main thread
    private let queue = DispatchQueue(label: "terminal-host")
    private var client: TerminalHostClient?
    private var launchFailed = false
    private let lock = NSLock()
    private var routes: [String: Route] = [:]

    /// A copy of the app under another bundle identifier (a review or development build) gets a host of its own: sharing
    /// one would let it take up the installed app's terminals and resize them to its own window
    let stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(TerminalHostLink.hostFolder(bundleID: Bundle.main.bundleIdentifier), isDirectory: true)

    /// "Gitrochi/terminal-host" for the app itself, "Gitrochi/terminal-host-<bundle id>" for a copy
    static func hostFolder(bundleID: String?) -> String {
        guard let id = bundleID, id != "com.ensnif.Gitrochi" else { return "Gitrochi/terminal-host" }
        return "Gitrochi/terminal-host-" + id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.map(String.init).joined()
    }

    /// GITROCHI_TERMINAL_HOST=off keeps terminals in the app; a path runs another host build
    private var override: String? { ProcessInfo.processInfo.environment["GITROCHI_TERMINAL_HOST"] }

    /// New tabs try the host first (they fall back to a shell of their own when it can't run)
    var enabled: Bool { override != "off" }

    private var executable: URL? {
        if let override { return override == "off" ? nil : URL(fileURLWithPath: override) }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gitrochi-terminal-host")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    func route(_ id: String, _ route: Route) {
        lock.lock()
        routes[id] = route
        lock.unlock()
    }

    func unroute(_ id: String) {
        lock.lock()
        routes[id] = nil
        lock.unlock()
    }

    /// Runs work on the host queue with the connected host, started first when launch is set; nil when there is none
    func perform(launch: Bool, _ work: @escaping @Sendable (TerminalHostClient?) -> Void) {
        queue.async { [self] in work(connected(launch: launch)) }
    }

    /// The host's sessions with the tab meta they carry, on the main queue; none when no host runs
    func sessions(_ done: @escaping @MainActor @Sendable ([(id: String, running: Bool, meta: TerminalHostMeta)]) -> Void) {
        perform(launch: false) { client in
            let found = ((try? client?.list()) ?? []).compactMap { s in TerminalHostMeta(s.meta).map { (id: s.id, running: s.running, meta: $0) } }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
        }
    }

    /// Ends every terminal the host runs, open in a tab or not ("Quit and End Terminals"), then calls done on the main queue
    func endAll(_ done: @escaping @MainActor @Sendable () -> Void) {
        perform(launch: false) { client in
            for session in (try? client?.list()) ?? [] where session.running { try? client?.kill(session.id) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    private func connected(launch: Bool) -> TerminalHostClient? {
        if let client, client.isOpen { return client }
        client = nil
        if override == "off" { return nil }
        if let c = try? TerminalHostClient(stateDir: stateDir, onEvent: { [weak self] in self?.deliver($0) }) {
            client = c
            return c
        }
        guard launch, !launchFailed, let executable, start(executable) else {
            if launch { launchFailed = true }
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            usleep(50_000)
            if let c = try? TerminalHostClient(stateDir: stateDir, onEvent: { [weak self] in self?.deliver($0) }) {
                client = c
                return c
            }
        }
        launchFailed = true
        return nil
    }

    /// Starts the host in a session of its own, so it outlives the app (and a Terminal window the app ran from)
    private func start(_ executable: URL) -> Bool {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // the host's own environment is what each session starts from
        guard let pid = Self.spawnDetached(executable.path, args: ["--state-dir", stateDir.path], env: TerminalSession.environment()) else {
            return false
        }
        // the host never ends while the app waits for it; reap it whenever it does, so it leaves no zombie
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return true
    }

    /// Runs a program in a new session with no terminal, standard streams on /dev/null, and every signal back at its
    /// default: a signal the app ignores (SIGPIPE, or SIGTERM as a launched app may have it) would otherwise stay ignored
    /// in the host, and `kill` or a logout could not end it
    static func spawnDetached(_ path: String, args: [String], env: [String]) -> pid_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        var pid: pid_t = 0
        let cArgs = ([path] + args).map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        return posix_spawn(&pid, path, &actions, &attributes, cArgs, cEnv) == 0 ? pid : nil
    }

    private func deliver(_ event: TerminalHostClient.Event) {
        switch event {
        case .output(let id, let bytes):
            guard let route = currentRoute(id) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { route.output(bytes) } }
        case .exited(let id, let code):
            if let route = currentRoute(id) {
                unroute(id)
                DispatchQueue.main.async { MainActor.assumeIsolated { route.exited(code) } }
            }
            // the tab has heard of it, or was closed: the host need not keep the ended session
            perform(launch: false) { try? $0?.forget(id) }
        case .closed:
            lock.lock()
            let all = routes
            routes = [:]
            lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { all.values.forEach { $0.exited(nil) } } }
        }
    }

    private func currentRoute(_ id: String) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return routes[id]
    }
}
