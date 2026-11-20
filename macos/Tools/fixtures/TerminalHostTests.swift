import Foundation

/// The app's environment for the host it starts; the tests start their host themselves
enum TerminalSession {
    static func environment() -> [String] { [] }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var output: [String: Data] = [:]
    private var exits: [String: Int32?] = [:]

    func take(_ event: TerminalHostClient.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .output(let id, let bytes): output[id, default: Data()].append(bytes)
        case .exited(let id, let code): exits[id] = code
        case .closed: break
        }
    }

    func text(_ id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: output[id] ?? Data(), as: UTF8.self)
    }

    func exit(_ id: String) -> Int32?? {
        lock.lock()
        defer { lock.unlock() }
        return exits[id]
    }
}

func until(_ what: String, _ ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !ready() {
        precondition(Date() < deadline, "timed out waiting for \(what)")
        usleep(20_000)
    }
}

@main struct TerminalHostTests {
    static func main() throws {
        frames()
        meta()
        signalsReset()
        try sessions(stateDir: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("terminal host tests passed")
    }

    static func frames() {
        let control = TerminalHostFrame.control(["type": "kill", "id": "a"])
        let encoded = try! control.encoded()
        precondition(encoded.prefix(4) == Data([UInt8(encoded.count - 4), 0, 0, 0]))
        guard case .control(let message) = try! TerminalHostFrame.decode(body: encoded.dropFirst(4)) else { preconditionFailure() }
        precondition(message["type"] as? String == "kill" && message["id"] as? String == "a")

        let bytes = Data("한글 \u{1b}[1mbold\r\n".utf8)
        let data = try! TerminalHostFrame.data(id: "tab-1", bytes: bytes).encoded()
        guard case .data(let id, let back) = try! TerminalHostFrame.decode(body: data.dropFirst(4)) else { preconditionFailure() }
        precondition(id == "tab-1" && back == bytes)
        precondition((try? TerminalHostFrame.decode(body: Data([1, 9, 0]))) == nil, "a truncated id")
        precondition((try? TerminalHostFrame.decode(body: Data([7]))) == nil, "an unknown kind")
    }

    static func meta() {
        let m = TerminalHostMeta(repository: "/r", directory: "/r/wt", program: "claude", args: ["--resume"], env: ["A": "1"], title: "Claude")
        let json = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: m.json))
        precondition(TerminalHostMeta(json) == m)
        // the shape the Windows app writes, with its nulls
        let windows: [String: Any] = ["app": "gitrochi", "repository": "C:\\r", "spec": ["directory": "C:\\r", "program": NSNull(), "args": NSNull()]]
        precondition(TerminalHostMeta(windows) == TerminalHostMeta(repository: "C:\\r", directory: "C:\\r"))
        precondition(TerminalHostMeta(["app": "other", "repository": "/r", "spec": ["directory": "/r"]]) == nil)
        precondition(TerminalHostMeta(["app": "gitrochi", "repository": "/r", "spec": ["directory": "/r", "args": [1]]]) == nil)
        precondition(TerminalHostMeta(nil) == nil)
    }

    /// A host started by an app that ignores SIGTERM still ends on SIGTERM
    static func signalsReset() {
        signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, SIG_DFL) }
        guard let pid = TerminalHostLink.spawnDetached("/bin/sleep", args: ["30"], env: []) else { preconditionFailure("spawn") }
        precondition(getsid(pid) == pid, "a session of its own")
        kill(pid, SIGTERM)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        precondition(status & 0x7f == SIGTERM, "SIGTERM was still ignored (status \(status))")
    }

    /// A real host: a session outlives the connection and replays its output to the next one
    static func sessions(stateDir: URL) throws {
        let events = Events()
        var app: TerminalHostClient? = try TerminalHostClient(stateDir: stateDir) { events.take($0) }
        let meta = TerminalHostMeta(repository: "/demo", directory: NSTemporaryDirectory()).json
        let pid = try app!.spawn(id: "t1", program: "/bin/sh", args: ["-c", "echo ready; while read l; do echo \"got:$l\"; done"],
                                 cwd: NSTemporaryDirectory(), env: ["GREETING": "hi"], cols: 80, rows: 24, meta: meta)
        precondition((pid ?? 0) > 0)
        _ = try app!.attach("t1")
        until("the first line") { events.text("t1").contains("ready") }
        try app!.input("t1", Data("hello\n".utf8))
        until("the answer") { events.text("t1").contains("got:hello") }
        try app!.resize("t1", cols: 100, rows: 30)
        app!.close()
        app = nil

        let again = Events()
        let back = try TerminalHostClient(stateDir: stateDir) { again.take($0) }
        let listed = try back.list()
        precondition(listed.count == 1 && listed[0].running && listed[0].cols == 100)
        precondition(TerminalHostMeta(listed[0].meta)?.repository == "/demo")
        let session = try back.attach("t1")
        precondition(session.running && session.pid == pid)
        until("the replay") { again.text("t1").contains("ready") && again.text("t1").contains("got:hello") }
        try back.kill("t1")
        until("the ending") { again.exit("t1") != nil }
        try back.forget("t1")
        let left = try back.list()
        precondition(left.isEmpty)
        precondition((try? back.attach("t1")) == nil)
        back.close()
    }
}
