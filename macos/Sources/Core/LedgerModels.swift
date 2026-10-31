import Foundation

// The Ledger contract, version 0: what the shared core (crates/gitrochi-ledger) answers for each method.
// Times are epoch milliseconds. (Windows: entities/ledger/model/types.ts)

/// Epoch milliseconds, as the core sends them
typealias LedgerMs = Int

/// A contract enum: a value from a newer core that this app does not know decodes as `fallback`
/// instead of failing the whole answer
protocol LedgerEnum: RawRepresentable, Codable, Hashable where RawValue == String {
    static var fallback: Self { get }
}

extension LedgerEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .fallback
    }
}

/// What a person should do with a session. The core computes it; the first match wins in this order.
enum LedgerVerdict: String, LedgerEnum, CaseIterable {
    case archived
    case needsHuman = "needs_human"
    case expirable, confirm, shelved
    case pendingMerge = "pending_merge"
    case stale, active
    static let fallback = LedgerVerdict.active
}

enum LedgerStatus: String, LedgerEnum, CaseIterable {
    case active, done, merged, closed, dropped, shelved
    static let fallback = LedgerStatus.active
    /// Finished one way or another: a person confirms it, then archives the conversation
    var isFinished: Bool { self == .merged || self == .closed || self == .dropped }
}

enum LedgerRole: String, LedgerEnum, CaseIterable {
    case decision, implementation, research, document, other
    static let fallback = LedgerRole.other
}

enum LedgerActor: String, LedgerEnum {
    case agent, human, auto, hook
    static let fallback = LedgerActor.agent
}

/// Who answered a question or a prompt
enum LedgerAnswerer: String, LedgerEnum {
    case human, auto
    static let fallback = LedgerAnswerer.human
}

/// The period the state and the graph cover; the core takes the raw value as `range`
enum LedgerRange: String, LedgerEnum, CaseIterable, Identifiable {
    case week = "7d", month = "30d", all
    static let fallback = LedgerRange.week
    var id: String { rawValue }
    /// The next wider period, for "show more"
    var wider: LedgerRange? { self == .week ? .month : self == .month ? .all : nil }
    /// The oldest time the period covers
    func start(now: LedgerMs) -> LedgerMs {
        switch self {
        case .week: return now - 7 * 86_400_000
        case .month: return now - 30 * 86_400_000
        case .all: return .min
        }
    }
}

/// JSON whose shape varies: event data, prompt payloads and answers, call arguments
enum LedgerJSON: Codable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([LedgerJSON]), object([String: LedgerJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([LedgerJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: LedgerJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // whole numbers go out without a fraction, as the core writes times and IDs
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> LedgerJSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [LedgerJSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: LedgerJSON]? { if case .object(let o) = self { return o }; return nil }
}

extension LedgerJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: LedgerJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, LedgerJSON)...) { self = .object(Dictionary(elements) { $1 }) }
}

/// One unit of agent work, usually one conversation; a branch in the graph
struct LedgerSession: Codable, Identifiable, Hashable {
    struct PullRequest: Codable, Hashable {
        var host: String
        var number: Int
        var url: String
    }
    struct Links: Codable, Hashable {
        var repoPath: String?
        var branch: String?
        var worktree: String?
        var pr: PullRequest?
        var agentId: String?
        var agentSessionId: String?
        var cwd: String?
    }
    struct Stream: Codable, Hashable { var line: String }
    struct AutoContinue: Codable, Hashable {
        var enabled: Bool
        var delaySec: Int
    }

    var id: String
    var project: String
    var title: String
    var kind: String
    var role: LedgerRole
    var status: LedgerStatus
    var verdict: LedgerVerdict
    var baseVersion: String?
    var baseCurrent: String?
    /// Baselines newer than `baseCurrent`, when the core counts them
    var behind: Int?
    var mergedInto: String?
    var touches: [String]
    var related: [String]
    var chatUrl: String?
    var links: Links
    var color: Int
    var createdAt: LedgerMs
    var lastAt: LedgerMs
    var lastAgentAt: LedgerMs?
    var ackAt: LedgerMs?
    var snoozeUntil: LedgerMs?
    var archivedAt: LedgerMs?
    var openQuestions: Int
    var stream: Stream?
    var autoContinue: AutoContinue?
}

struct LedgerEvent: Codable, Identifiable, Hashable {
    struct Artifact: Codable, Hashable {
        var name: String
        var ssot: String?
        var ver: String?
    }

    var id: Int
    var sessionId: String
    var ts: LedgerMs
    var type: String
    var actor: LedgerActor
    var summary: String?
    var body: String?
    var version: String?
    var artifacts: [Artifact]?
    var data: [String: LedgerJSON]?
    var deliveredAt: LedgerMs?
}

struct LedgerQuestion: Codable, Identifiable, Hashable {
    enum State: String, LedgerEnum {
        case open, answered, dismissed
        static let fallback = State.open
    }

    var id: Int
    var sessionId: String
    var text: String
    var state: State
    var answer: String?
    var answeredBy: LedgerAnswerer?
    var createdAt: LedgerMs
    var answeredAt: LedgerMs?
    var deliveredAt: LedgerMs?
}

/// A version of the source of truth a project's work starts from
struct LedgerBaseline: Codable, Hashable {
    enum Source: String, LedgerEnum {
        case tag, folder, registered, release, inferred
        static let fallback = Source.inferred
    }

    var project: String
    var version: String
    var ts: LedgerMs
    var source: Source
    var note: String?
    var bySession: String?
}

/// One baseline cycle of an implementation stream: synced, worked on, applied
struct LedgerStreamCycle: Codable, Hashable {
    enum State: String, LedgerEnum {
        case applied, active, skipped
        static let fallback = State.active
    }

    var sessionId: String
    var line: String
    var version: String
    var state: State
    var syncedAt: LedgerMs?
    var appliedAt: LedgerMs?
    var releasedBy: String?
    var eventIds: [Int]
}

/// Two live sessions that work on the same thing
struct LedgerOverlap: Codable, Hashable {
    enum Kind: String, LedgerEnum {
        case same, coupled
        static let fallback = Kind.same
    }

    var a: String
    var b: String
    var paths: [String]
    var kind: Kind
}

/// An agent waiting for a person (a question at the end of a turn, AskUserQuestion, a plan, a permission);
/// auto-continue answers it at `deadline` unless a person does first
struct LedgerPendingPrompt: Codable, Identifiable, Hashable {
    enum Kind: String, LedgerEnum {
        case stopQuestion = "stop_question"
        case askUserQuestion = "ask_user_question"
        case exitPlanMode = "exit_plan_mode"
        case permission
        static let fallback = Kind.stopQuestion
    }
    enum State: String, LedgerEnum {
        case waiting, answered, auto, released, expired
        static let fallback = State.waiting
    }

    var id: Int
    var sessionId: String?
    var agentId: String?
    var kind: Kind
    var payload: [String: LedgerJSON]
    var createdAt: LedgerMs
    var deadline: LedgerMs
    var state: State
    var answer: [String: LedgerJSON]?
    var answeredBy: LedgerAnswerer?
    var answeredAt: LedgerMs?
    var reviewedAt: LedgerMs?
}

/// What needs a person, as the core counts it (the sidebar badge is `total`)
struct LedgerAttention: Codable, Hashable {
    var questions: Int
    var tidy: Int
    var decide: Int
    var autoReview: Int
    var total: Int
}

struct LedgerProject: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var open: Int
    var id: String { key }
}

/// `state`: everything the Inbox, Board and Streams show for one project (or all) and period
struct LedgerState: Codable, Hashable {
    var schemaVersion: Int
    var rev: Int
    var now: LedgerMs
    var projects: [LedgerProject]
    var baselines: [LedgerBaseline]
    var sessions: [LedgerSession]
    var questions: [LedgerQuestion]
    var streams: [LedgerStreamCycle]
    var overlaps: [LedgerOverlap]
    /// Waiting prompts only
    var pendingPrompts: [LedgerPendingPrompt]
    /// Prompts auto-continue answered that a person has not reviewed yet (the core's contract adds this list)
    var autoReview: [LedgerPendingPrompt]?
    var attention: LedgerAttention
    var hiddenBefore: Int
}

/// `session`: one session with its whole record
struct LedgerSessionDetail: Codable, Hashable {
    var session: LedgerSession
    var events: [LedgerEvent]
    var questions: [LedgerQuestion]
    var overlaps: [LedgerOverlap]
    var cycles: [LedgerStreamCycle]
}

struct LedgerGraphNode: Codable, Identifiable, Hashable {
    enum Kind: String, LedgerEnum {
        case baseline, start, event, merge, release, end
        static let fallback = Kind.event
    }

    var id: String
    var lane: Int
    /// The row the core placed it in, newest first
    var row: Int?
    var ts: LedgerMs
    var color: Int
    var kind: Kind
    var sessionId: String?
    var version: String?
    var label: String?
}

struct LedgerGraphEdge: Codable, Hashable {
    enum Kind: String, LedgerEnum {
        case trunk, branch, merge, handoff
        static let fallback = Kind.branch
    }

    var from: String
    var to: String
    var kind: Kind
    var color: Int
}

/// A live session's dashed line from its newest node (at `row`) up to the top
struct LedgerGraphTail: Codable, Hashable {
    var sessionId: String
    var lane: Int
    var row: Int
    var color: Int
}

/// `graph`: lanes laid out by the core; lane 0 is the baseline trunk
struct LedgerGraph: Codable, Hashable {
    var lanes: Int
    var rows: Int?
    var nodes: [LedgerGraphNode]
    var edges: [LedgerGraphEdge]
    var tails: [LedgerGraphTail]?
    var from: LedgerMs
    var to: LedgerMs
    var hiddenBefore: Int?
}

struct LedgerInfo: Codable, Hashable {
    var schemaVersion: Int
    var dbPath: String
    var rev: Int
    var enabled: Bool
}

struct LedgerRev: Codable, Hashable { var rev: Int }

struct LedgerSearchHit: Codable, Hashable, Identifiable {
    enum Kind: String, LedgerEnum {
        case session, question, event, baseline
        static let fallback = Kind.event
    }

    var kind: Kind
    var id: String
    var sessionId: String?
    var title: String
    var snippet: String
}

struct LedgerSearchResult: Codable, Hashable { var hits: [LedgerSearchHit] }

struct LedgerImportResult: Codable, Hashable {
    struct Block: Codable, Hashable, Identifiable {
        var index: Int
        var ok: Bool
        var duplicate: Bool
        var error: String?
        var sessionId: String?
        var id: Int { index }
    }
    var results: [Block]
}

struct LedgerWriteResult: Codable, Hashable {
    var ok: Bool
    var rev: Int?
}

struct LedgerBackupResult: Codable, Hashable { var path: String }

/// `{"error": {"code", "message"}}`
struct LedgerErrorEnvelope: Codable, Hashable {
    struct Body: Codable, Hashable {
        var code: String
        var message: String
    }
    var error: Body
}

/// A person's operation, sent as `human {action, sessionId, …}`. Every one is an event with actor `human`.
enum LedgerHumanAction: Hashable {
    case ack, unack, archive, unarchive
    case setStatus(LedgerStatus, version: String?)
    case answer(questionId: Int, text: String)
    case dismiss(questionId: Int)
    /// Still active: the core sets `snoozeUntil` to now plus the stale hours
    case stillActive
    /// Puts `snoozeUntil` back to a value it had; what undoes Still active
    case snooze(until: LedgerMs)
    case shelve
    /// Sets one link (`branch`, `worktree`, `repoPath`, `agentId`, `chatUrl` …); nil removes it
    case link(field: String, value: String?)
    case message(text: String)

    /// The arguments of `human`, without `sessionId`
    var arguments: [String: LedgerJSON] {
        switch self {
        case .ack: return ["action": "ack"]
        case .unack: return ["action": "unack"]
        case .archive: return ["action": "archive"]
        case .unarchive: return ["action": "unarchive"]
        case .setStatus(let status, let version):
            var args: [String: LedgerJSON] = ["action": "set_status", "status": .string(status.rawValue)]
            if let version { args["into"] = .string(version) }
            return args
        case .answer(let id, let text): return ["action": "answer", "questionId": .number(Double(id)), "answer": .string(text)]
        case .dismiss(let id): return ["action": "dismiss", "questionId": .number(Double(id))]
        case .stillActive: return ["action": "snooze"]
        case .snooze(let until): return ["action": "snooze", "until": .number(Double(until))]
        case .shelve: return ["action": "shelve"]
        case .link(let field, let value): return ["action": "link", field: value.map { .string($0) } ?? .null]
        case .message(let text): return ["action": "message", "text": .string(text)]
        }
    }
}

/// What a person sends for a waiting prompt with `prompt_answer {id, answer}`
enum LedgerPromptReply: Hashable {
    /// A typed answer to a question at the end of a turn
    case text(String)
    /// AskUserQuestion: question text → the chosen labels, comma-separated for multiple choice
    case choices([String: String])
    case allow
    case deny(message: String?)
    /// Leaves the prompt to the terminal: the agent shows its own question there
    case answerInTerminal
    /// Keeps waiting for a person: no automatic answer for this prompt
    case holdAuto

    var answer: [String: LedgerJSON] {
        switch self {
        case .text(let text): return ["text": .string(text)]
        case .choices(let answers): return ["answers": .object(answers.mapValues { .string($0) })]
        case .allow: return ["decision": "allow"]
        case .deny(let message):
            var answer: [String: LedgerJSON] = ["decision": "deny"]
            if let message, !message.isEmpty { answer["message"] = .string(message) }
            return answer
        case .answerInTerminal: return ["release": true]
        case .holdAuto: return ["hold": true]
        }
    }
}
