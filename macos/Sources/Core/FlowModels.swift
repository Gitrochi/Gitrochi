import Foundation

/// The app-side shape of the JSON the flow engine (gitch-flow) writes (tools/gitch-flow/schema/flow-*-v1.schema.json).
/// The app only reads what the engine wrote and never judges: verdicts, signatures and rollback always belong to the engine.

/// `gitch-flow list --json`
struct FlowList: Decodable, Equatable {
    struct Flow: Decodable, Identifiable, Equatable, Hashable {
        struct Last: Decodable, Equatable, Hashable {
            let runId: String
            let state: String
            let finishedAt: String?
            let durationMs: Int?
            let signed: Bool?
        }
        let name: String
        let description: String?
        let trigger: [String]
        let env: String?
        let nodes: Int
        let last: Last?
        var id: String { name }
    }
    struct Suite: Decodable, Equatable, Hashable {
        let name: String
        let use: String
        let tags: [String]
    }
    let project: String?
    let trusted: Bool
    let flows: [Flow]
    let suites: [Suite]
}

/// What the app uses from `gitch-flow plan <flow> --json`
struct FlowPlan: Decodable, Equatable {
    struct Trust: Decodable, Equatable {
        let trusted: Bool
        let changed: [String]?
        let approvedAt: String?
    }
    struct Reason: Decodable, Equatable, Hashable {
        let code: String?
        let message: String?
    }
    struct Node: Decodable, Identifiable, Equatable, Hashable {
        let id: String
        let title: String?
        let block: String
        let needs: [String]
        let decision: String
        let reason: Reason?
        let outward: Bool?
        let destructive: Bool?
        let branchOf: String?
        let group: String?
        let run: String?
        let undo: String?
        let executor: String?
        let src: String?
    }
    let flow: String
    let env: String
    let envClass: String?
    let trust: Trust
    let outward: [String]
    let gates: [String]
    let services: [String]
    let warnings: [String]
    let estimateMs: Int?
    let nodes: [Node]

    /// Whether a person must confirm an outward action (remote CI, deploy, notification) or a block that is hard to undo
    var needsConfirmation: Bool { !outward.isEmpty || nodes.contains { $0.destructive == true && $0.decision == "run" } }
}

/// The answer to `run --detach --json`
struct FlowDetached: Decodable, Equatable {
    let runId: String
    let pid: Int?
    let runDir: String
    let eventsPath: String
}

/// One line of `status --all --json`
struct FlowRunRow: Decodable, Identifiable, Equatable, Hashable {
    let runId: String
    let flow: String
    let env: String?
    let state: String
    let code: String?
    let running: Bool?
    let startedAt: String?
    let durationMs: Int?
    let signed: Bool?
    var id: String { runId }
}

/// `init --dry-run --json`: the flow file the engine proposes from reading the repository's files only
struct FlowInitProposal: Decodable, Equatable {
    struct Finding: Decodable, Equatable, Hashable {
        let kind: String
        let evidence: String
        let confidence: String
        let note: String?
    }
    let exists: Bool
    let valid: Bool
    let findings: [Finding]
    let yaml: String
}

/// `gate status --json`
struct FlowGate: Decodable, Equatable {
    /// OFF · OK · WARN
    let gate: String
    let flow: String?
}

/// The engine's error envelope (`{"schemaVersion":1,"error":{…}}`, on stderr)
struct FlowErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let flowCode: String?
        let message: String
        let exitCode: Int?
        let action: String?
    }
    let error: Body
}

/// One line of events.ndjson
struct FlowEvent: Decodable {
    let seq: Int
    let at: String
    let type: String
    let node: String?
    let data: FlowJSON
}

/// JSON whose shape varies, like event data
enum FlowJSON: Decodable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([FlowJSON]), object([String: FlowJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([FlowJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: FlowJSON].self)) }
    }

    subscript(key: String) -> FlowJSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [FlowJSON] { if case .array(let a) = self { return a }; return [] }
}

/// Node state (the same names as the engine's state table)
enum FlowNodeState: String, Equatable {
    case pending = "PENDING", running = "RUNNING", passed = "PASSED", failed = "FAILED", indeterminate = "INDETERMINATE"
    case skipped = "SKIPPED", cached = "CACHED", rejected = "REJECTED", cancelled = "CANCELLED"

    var isBad: Bool { [.failed, .indeterminate, .rejected, .cancelled].contains(self) }
    var isDone: Bool { self != .pending && self != .running }
}

/// The screen state of one run: feeding events in order builds up node states, log tails and rollback steps (lines with an equal or smaller seq are dropped).
struct FlowRunView: Equatable {
    struct Node: Identifiable, Equatable {
        let id: String
        var title: String
        var block: String
        var needs: [String]
        var branchOf: String?
        var state: FlowNodeState = .pending
        var code: String?
        var durationMs: Int?
        var testsPassed: Int?
        var testsExecuted: Int?
        var reason: String?
        var log: String?
        var tail: [String] = []
    }
    struct Step: Identifiable, Equatable {
        let id: Int
        let node: String?
        let text: String
        let state: String
    }

    var runId: String
    var flow = ""
    var state = "PENDING"
    var code: String?
    var exitCode: Int?
    var lastSeq = 0
    var nodes: [Node] = []
    /// Things that happen outside nodes, like services, rollback and engine notices
    var steps: [Step] = []
    var done = false

    static let tailLimit = 400

    init(runId: String) { self.runId = runId }

    mutating func apply(_ e: FlowEvent) {
        guard e.seq > lastSeq else { return }
        lastSeq = e.seq
        switch e.type {
        case "run.planned":
            flow = e.data["flow"].string ?? flow
            nodes = e.data["nodes"].array.compactMap { n in
                guard let id = n["id"].string else { return nil }
                return Node(id: id, title: n["title"].string ?? id, block: n["block"].string ?? "",
                            needs: n["needs"].array.compactMap(\.string), branchOf: n["branchOf"].string)
            }
        case "run.state":
            if let s = e.data["state"].string { state = s }
        case "node.state":
            guard let id = e.node, let i = nodes.firstIndex(where: { $0.id == id }) else { return }
            if let s = e.data["state"].string, let st = FlowNodeState(rawValue: s) { nodes[i].state = st }
            if let c = e.data["code"].string { nodes[i].code = c }
            if let d = e.data["durationMs"].int { nodes[i].durationMs = d }
            if let l = e.data["log"].string { nodes[i].log = l }
            if let t = e.data["tests"]["executed"].int { nodes[i].testsExecuted = t; nodes[i].testsPassed = e.data["tests"]["passed"].int }
            if let m = e.data["reason"]["message"].string ?? e.data["detail"].string { nodes[i].reason = m }
        case "log":
            guard let id = e.node, let i = nodes.firstIndex(where: { $0.id == id }) else { return }
            let lines = e.data["lines"].array.compactMap { $0.string ?? $0["t"].string }
            nodes[i].tail.append(contentsOf: lines)
            if nodes[i].tail.count > Self.tailLimit { nodes[i].tail.removeFirst(nodes[i].tail.count - Self.tailLimit) }
        case "service.state":
            let name = e.data["service"].string ?? "?"
            steps.append(Step(id: e.seq, node: nil, text: name, state: e.data["state"].string ?? ""))
        case "rollback.step":
            steps.append(Step(id: e.seq, node: e.node, text: e.data["title"].string ?? "", state: e.data["state"].string ?? ""))
        case "run.done":
            if let s = e.data["state"].string { state = s }
            code = e.data["code"].string
            exitCode = e.data["exitCode"].int
            done = true
        default:
            break
        }
    }

    /// Reads a newly written NDJSON chunk (an unfinished last line waits for next time). The read position moves by the returned count.
    mutating func consume(_ chunk: Data) -> Int {
        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = chunk[chunk.startIndex...lastNewline]
        let dec = JSONDecoder()
        for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let e = try? dec.decode(FlowEvent.self, from: Data(line)) { apply(e) }
        }
        return complete.count
    }

    var counts: (passed: Int, failed: Int, running: Int, total: Int) {
        let main = nodes.filter { $0.branchOf == nil }
        return (main.filter { $0.state == .passed || $0.state == .cached }.count,
                main.filter { $0.state.isBad }.count,
                main.filter { $0.state == .running }.count,
                main.count)
    }
}
