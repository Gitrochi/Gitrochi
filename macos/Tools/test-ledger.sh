#!/usr/bin/env bash
# The Ledger screens' logic without SwiftUI: the pure presentation rules (verdict order, countdowns, filters, Inbox
# grouping, undo, graph rows and coordinates), every demo backend answer decoded with the app's contract models,
# LedgerStore (polling by rev, operations, undo, prompts) and the large demo (1,000 sessions, 50,000 events) with timings.
# It builds the shared core (tools/build-core-native.sh) and reads the core's own demo through the app's client, Inbox,
# graph and store twice: through the command-line tool as an agent (GITROCHI_LEDGER_BIN, else the one just built), and
# through the C ABI in libgitrochi_core.a as the app (NativeLedgerBackend), with a person's operations, settings,
# projects, backups, both imports and the bundled command's MCP handshake, in temporary folders only.
#   macos/Tools/test-ledger.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

/// A clock the test moves by hand, so deadlines run out on purpose
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LedgerMs
    init(_ value: LedgerMs) { self.value = value }
    func now() -> LedgerMs { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ ms: LedgerMs) { lock.lock(); value += ms; lock.unlock() }
}

/// Counts the calls the store makes, and can answer one method with an error
final class SpyBackend: LedgerBackend, @unchecked Sendable {
    let inner: LedgerBackend
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var failing: String?
    init(_ inner: LedgerBackend) { self.inner = inner }
    func call(method: String, args: Data) -> Data {
        lock.lock(); counts[method, default: 0] += 1; let fail = failing == method; lock.unlock()
        if fail { return Data(#"{"error":{"code":"TEST","message":"Refused by the test"}}"#.utf8) }
        return inner.call(method: method, args: args)
    }
    func count(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[method] ?? 0 }
}

/// The real core through its command-line tool, as an agent: a person's operations answer NOT_ALLOWED there
final class CLIBackend: LedgerBackend, @unchecked Sendable {
    let binary: String
    let db: String
    init(binary: String, db: String) { self.binary = binary; self.db = db }
    func call(method: String, args: Data) -> Data { run(["call", method, String(decoding: args, as: UTF8.self)]) }
    func run(_ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["GITROCHI_LEDGER_DB": db]) { $1 }
        // JSON comes on standard output; standard error carries a line for people
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

var checks = 0
/// Evaluated where it is called, so a condition may `try` or `await`
func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    // an optimized build drops precondition messages, so say what failed before stopping
    if !condition {
        FileHandle.standardError.write(Data("FAIL (line \(line)): \(message())\n".utf8))
        exit(1)
    }
}

func call<T: Decodable>(_ backend: LedgerBackend, _ method: String, _ args: [String: LedgerJSON] = [:], as type: T.Type) throws -> T {
    try LedgerClient.decode(T.self, from: backend.call(method: method, args: JSONEncoder().encode(LedgerJSON.object(args))))
}

func failure(_ backend: LedgerBackend, _ method: String, _ args: [String: LedgerJSON] = [:]) -> LedgerFailure? {
    do { _ = try call(backend, method, args, as: LedgerJSON.self); return nil } catch { return error as? LedgerFailure }
}

func seconds(_ start: Date) -> Double { Date().timeIntervalSince(start) }
func ms(_ value: Double) -> String { String(format: "%.0f ms", value * 1000) }

let hour: LedgerMs = 3_600_000
let start: LedgerMs = 1_793_400_000_000

@main struct LedgerTests {
    @MainActor static func main() async throws {
        pureLogic()
        try graphRows()
        try demoContract()
        try await store()
        try await large()
        if let i = CommandLine.arguments.firstIndex(of: "--core"), i + 2 < CommandLine.arguments.count {
            try await core(binary: CommandLine.arguments[i + 1], folder: CommandLine.arguments[i + 2])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--native"), i + 3 < CommandLine.arguments.count {
            try await native(cli: CommandLine.arguments[i + 1], folder: CommandLine.arguments[i + 2], legacy: CommandLine.arguments[i + 3])
        }
        print("PASS: \(checks) checks — verdict order, countdowns, filters, Inbox groups, undo, graph rows and coordinates, every demo answer decoded, errors, deadlines, store polling by rev, operations with undo, prompts, settings, large demo, the core through its C ABI")
    }

    static func pureLogic() {
        check(Set(LedgerVerdict.displayOrder) == Set(LedgerVerdict.allCases) && LedgerVerdict.displayOrder.count == 8, "every verdict once")
        check(LedgerVerdict.displayOrder.first == .needsHuman && LedgerVerdict.displayOrder.last == .archived, "most urgent first")
        check(LedgerVerdict.needsHuman.rank < LedgerVerdict.pendingMerge.rank && LedgerVerdict.stale.rank < LedgerVerdict.active.rank, "rank")
        check(Set(LedgerVerdict.allCases.map(\.symbol)).count == 8 && LedgerVerdict.allCases.allSatisfy { !$0.title.isEmpty }, "symbols and titles")

        check(LedgerCountdown.text(deadline: start + 42_000, now: start) == "0:42", "seconds")
        check(LedgerCountdown.text(deadline: start + 125_000, now: start) == "2:05", "minutes")
        check(LedgerCountdown.text(deadline: start + 3_723_000, now: start) == "1:02:03", "hours")
        check(LedgerCountdown.text(deadline: start + 1, now: start) == "0:01", "rounds up")
        check(LedgerCountdown.text(deadline: start, now: start) == "0:00" && LedgerCountdown.text(deadline: start - 5_000, now: start) == "0:00", "time up")
        check(abs(LedgerCountdown.fraction(created: 0, deadline: 60_000, now: 15_000) - 0.75) < 1e-9, "fraction")
        check(LedgerCountdown.fraction(created: 0, deadline: 60_000, now: 90_000) == 0 && LedgerCountdown.fraction(created: 5, deadline: 5, now: 0) == 0, "fraction bounds")
        var prompt = LedgerPendingPrompt(id: 1, sessionId: nil, agentId: nil, kind: .permission, payload: [:], createdAt: 0, deadline: 10, state: .waiting, answer: nil, answeredBy: nil)
        check(LedgerCountdown.isCounting(prompt), "counting")
        prompt.deadline = 0
        check(!LedgerCountdown.isCounting(prompt), "a held prompt waits for a person")

        func session(_ id: String, _ title: String, verdict: LedgerVerdict, last: LedgerMs, stream: Bool = false, touches: [String] = [], branch: String? = nil) -> LedgerSession {
            LedgerSession(id: id, project: "p", title: title, kind: "fix", role: .other, status: .active, verdict: verdict, baseVersion: "v1.0.0",
                          baseCurrent: "v1.0.0", mergedInto: nil, touches: touches, related: [], chatUrl: nil, links: .init(branch: branch), color: 0,
                          createdAt: 0, lastAt: last, lastAgentAt: last, ackAt: nil, snoozeUntil: nil, archivedAt: nil, openQuestions: 0,
                          stream: stream ? .init(line: "Implementation") : nil, autoContinue: nil)
        }
        let list = [session("S1", "Retry sign-in after a timeout", verdict: .active, last: 5),
                    session("S2", "Add CSV export", verdict: .needsHuman, last: 1, touches: ["src/export/csv.swift"]),
                    session("S3", "Old work", verdict: .archived, last: 9),
                    session("S4", "Channel", verdict: .active, last: 9, stream: true),
                    session("S5", "Ünicode Résumé", verdict: .active, last: 7, branch: "feature/resume")]
        var filter = LedgerSessionFilter()
        check(filter.apply(list).map(\.id) == ["S2", "S5", "S1"], "urgent first, then newest; streams and archived left out: \(filter.apply(list).map(\.id))")
        filter.text = "SIGN retry"
        check(filter.apply(list).map(\.id) == ["S1"], "words in any order, case ignored")
        filter.text = "resume"
        check(filter.apply(list).map(\.id) == ["S5"], "accents ignored, branch searched")
        filter.text = "csv.swift"
        check(filter.apply(list).map(\.id) == ["S2"], "touches searched")
        filter = LedgerSessionFilter(verdicts: [.archived])
        check(filter.apply(list).map(\.id) == ["S3"], "the Archived chip shows archived sessions")
        filter = LedgerSessionFilter(verdicts: [.active, .needsHuman])
        check(filter.apply(list).map(\.id) == ["S2", "S5", "S1"], "several chips")
        check(LedgerSessionFilter.counts(list) == [.active: 2, .needsHuman: 1, .archived: 1], "counts leave streams out")

        var before = session("S9", "x", verdict: .confirm, last: 0)
        before.status = .merged
        before.mergedInto = "v1.2.0"
        check(LedgerUndo.inverse(of: .ack, before: before, now: 9) == [.unack], "undo confirm")
        check(LedgerUndo.inverse(of: .archive, before: before, now: 9) == [.unarchive], "undo archive")
        check(LedgerUndo.inverse(of: .stillActive, before: before, now: 9) == nil, "no Undo for Still active without a snooze to put back: the core snoozes into the future only")
        before.snoozeUntil = 77
        check(LedgerUndo.inverse(of: .stillActive, before: before, now: 9) == [.snooze(until: 77)], "undo Still active restores a snooze that still runs")
        check(LedgerUndo.inverse(of: .stillActive, before: before, now: 77) == nil, "a snooze that has ended cannot be put back")
        check(LedgerUndo.inverse(of: .setStatus(.active, version: nil), before: before, now: 9) == [.setStatus(.merged, version: "v1.2.0"), .unack], "undo reopen")
        before.ackAt = 5
        before.archivedAt = 6
        check(LedgerUndo.inverse(of: .setStatus(.closed, version: nil), before: before, now: 9) == [.setStatus(.merged, version: "v1.2.0"), .ack, .archive], "undo restores confirm and archive")
        check(LedgerUndo.inverse(of: .answer(questionId: 1, text: "a"), before: before, now: 9) == nil && LedgerUndo.inverse(of: .message(text: "m"), before: before, now: 9) == nil, "answers and messages are not undone")

        var linked = session("S7", "x", verdict: .active, last: 0)
        linked.project = "harbor"
        linked.links.repoPath = "~/Projects/harbor"
        let projects = [LedgerProject(key: "harbor", name: "Harbor", open: 1), LedgerProject(key: "meadow", name: "Meadow", open: 0)]
        check(LedgerProjects.key(forRepository: NSHomeDirectory() + "/Projects/harbor/", sessions: [linked], projects: projects) == "harbor", "linked repository, ~ expanded")
        check(LedgerProjects.key(forRepository: "/tmp/elsewhere/Meadow", sessions: [linked], projects: projects) == "meadow", "a project named like the folder")
        check(LedgerProjects.key(forRepository: "/tmp/elsewhere/unknown", sessions: [linked], projects: projects) == nil && LedgerProjects.key(forRepository: nil, sessions: [], projects: projects) == nil, "no project")
        let baselines = ["v1.9.2", "v1.10.0", "v1.2.0"].map { LedgerBaseline(project: "harbor", version: $0, ts: 0, source: .tag, note: nil, bySession: nil) }
        check(LedgerProjects.head("harbor", baselines: baselines) == "v1.10.0", "numeric version order")
        linked.baseCurrent = "v1.2.0"
        check(LedgerProjects.behind(linked, baselines: baselines) == 2, "behind")

        check(LedgerHumanAction.setStatus(.merged, version: "v2").arguments == ["action": "set_status", "status": "merged", "into": "v2"], "set_status shape")
        check(LedgerHumanAction.answer(questionId: 3, text: "yes").arguments == ["action": "answer", "questionId": 3, "answer": "yes"], "answer shape")
        check(LedgerHumanAction.link(field: "branch", value: nil).arguments == ["action": "link", "branch": .null], "link shape: null removes")
        check(LedgerHumanAction.stillActive.arguments == ["action": "snooze"], "Still active leaves the time to the core")
        check(LedgerHumanAction.snooze(until: 5).arguments == ["action": "snooze", "until": 5], "undo sends the old time")
        check(LedgerPromptReply.choices(["Q?": "A"]).answer == ["answers": ["Q?": "A"]] && LedgerPromptReply.holdAuto.answer == ["hold": true], "prompt answer shapes")
        check(LedgerPromptReply.deny(message: "").answer == ["decision": "deny"] && LedgerPromptReply.deny(message: "no").answer == ["decision": "deny", "message": "no"], "deny shape")
        let encoded = String(decoding: try! JSONEncoder().encode(LedgerJSON.object(["n": 3, "f": .number(1.5)])), as: UTF8.self)
        check(encoded.contains("\"n\":3") && encoded.contains("1.5"), "whole numbers stay whole: \(encoded)")
        check((try? JSONDecoder().decode([LedgerVerdict].self, from: Data(#"["needs_human","from_a_newer_core"]"#.utf8))) == [.needsHuman, .active], "unknown values fall back")
        let kinds = LedgerGlobalSettings.kindsArgument(["spike": .init(role: .research, line: "x", handoff: false), "build": .init(role: .implementation, line: " ", handoff: nil)])
        check(kinds == ["spike": ["role": "research"], "build": ["role": "implementation", "line": "core", "handoff": true]], "kinds: a line and hand-off only for implementation: \(kinds)")
        let rules = LedgerGlobalSettings(staleHours: 72, kinds: ["research": .init(role: .research)], autoContinue: nil, backupKeep: 14)
        check(rules.unassignedKinds(among: ["research", "spike", "", "spike", "Research"]) == ["Research", "spike"], "kinds without a rule, once each, as stored")
        let point = LedgerGraphPlot.point(lane: 2, row: 3, laneWidth: 22, rowHeight: 30, leftPad: 6)
        check(point.x == 61 && point.y == 105 && LedgerGraphPlot.point(lane: 0.5, row: 0, laneWidth: 22, rowHeight: 30, leftPad: 6).x == 28, "coordinates")
    }

    static func graphRows() throws {
        func node(_ id: String, _ lane: Int, _ ts: LedgerMs, _ kind: LedgerGraphNode.Kind, session: String? = nil) -> LedgerGraphNode {
            LedgerGraphNode(id: id, lane: lane, ts: ts, color: lane, kind: kind, sessionId: session)
        }
        let graph = LedgerGraph(lanes: 3, nodes: [
            node("b1", 0, 0, .baseline), node("b2", 0, 100, .baseline),
            node("s1", 1, 10, .start, session: "A"), node("s2", 1, 50, .event, session: "A"), node("s3", 1, 90, .merge, session: "A"),
            node("o1", 2, 60, .start, session: "B"), node("o2", 2, 70, .event, session: "B"),
        ], edges: [
            LedgerGraphEdge(from: "b1", to: "b2", kind: .trunk, color: 0),
            LedgerGraphEdge(from: "b1", to: "s1", kind: .branch, color: 1),
            LedgerGraphEdge(from: "s1", to: "s2", kind: .branch, color: 1),
            LedgerGraphEdge(from: "s2", to: "s3", kind: .branch, color: 1),
            LedgerGraphEdge(from: "s3", to: "b2", kind: .merge, color: 1),
            LedgerGraphEdge(from: "b0", to: "o1", kind: .branch, color: 2),
            LedgerGraphEdge(from: "o1", to: "o2", kind: .branch, color: 2),
        ], from: 0, to: 100)
        let plot = LedgerGraphPlot.plot(graph, openSessions: ["B"])
        check(plot.rows.map(\.id) == ["b2", "s3", "o2", "o1", "s2", "s1", "b1"] && plot.lanes == 3 && plot.hiddenRows == 0, "newest first: \(plot.rows.map(\.id))")
        func has(_ row: Int, _ s: LedgerGraphSegment) -> Bool { plot.rows[row].segments.contains(s) }
        func seg(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ color: Int, dashed: Bool = false) -> LedgerGraphSegment {
            LedgerGraphSegment(x1: x1, y1: y1, x2: x2, y2: y2, color: color, dashed: dashed)
        }
        check(has(0, seg(0, 0.5, 0, 1, 0)) && (1...5).allSatisfy { has($0, seg(0, 0, 0, 1, 0)) } && has(6, seg(0, 0, 0, 0.5, 0)), "the trunk runs through every row")
        check(has(6, seg(1, 0, 0, 0.5, 1)), "a fork curves into its base in the base's row, as in the commit graph")
        check(has(5, seg(1, 0.5, 1, 1, 1)), "the session's line leaves its start downward")
        check(has(0, seg(0, 0.5, 1, 1, 1)) && has(1, seg(1, 0, 1, 0.5, 1)), "a merge curves out of the baseline's row into the session's lane")
        check(has(3, seg(1, 0, 1, 1, 1)) && has(2, seg(1, 0, 1, 1, 1)) && has(4, seg(1, 0, 1, 0.5, 1)) && has(4, seg(1, 0.5, 1, 1, 1)),
              "the session line passes the rows in between and both sides of its own node")
        check(has(3, seg(2, 0.5, 2, 1, 2)) && has(6, seg(2, 0, 2, 1, 2)), "a base that is not drawn: the line runs on to the bottom")
        check(has(0, seg(2, 0, 2, 1, 2, dashed: true)) && has(1, seg(2, 0, 2, 1, 2, dashed: true)) && has(2, seg(2, 0, 2, 0.5, 2, dashed: true)), "an open session continues upward, dashed")
        check(!plot.rows.flatMap(\.segments).contains { $0.dashed && $0.x1 == 1 }, "a merged session has no tail")
        var ordered = graph
        ordered.nodes = graph.nodes.map { n in var n = n; n.row = ["b2", "s3", "o2", "o1", "s2", "s1", "b1"].firstIndex(of: n.id); return n }
        ordered.nodes.swapAt(0, 6)
        ordered.tails = [LedgerGraphTail(sessionId: "B", lane: 2, row: 2, color: 2)]
        let fromCore = LedgerGraphPlot.plot(ordered)
        check(fromCore.rows.map(\.id) == plot.rows.map(\.id) && fromCore.rows[0].segments.contains(seg(2, 0, 2, 1, 2, dashed: true)),
              "the core's rows and tails are used when it sends them")
        let cut = LedgerGraphPlot.plot(graph, openSessions: [], limit: 3)
        check(cut.rows.count == 3 && cut.hiddenRows == 4 && cut.rows[2].segments.contains(seg(0, 0, 0, 1, 0)), "past the limit the trunk runs to the bottom")
        let held = LedgerGraphPlot.plot(graph, openSessions: ["A"], limit: 1)
        check(held.rows.count == 1 && held.rows[0].segments.contains(seg(1, 0, 1, 1, 1, dashed: true)),
              "an open session with every node past the limit keeps its lane through the drawn rows")
        check(LedgerGraphPlot.plot(LedgerGraph(lanes: 1, nodes: [], edges: [], from: 0, to: 0)).rows.isEmpty, "empty graph")
    }

    static func demoContract() throws {
        let clock = TestClock(start)
        let demo = DemoLedgerBackend(clock: { clock.now() })
        let info = try call(demo, "info", as: LedgerInfo.self)
        check(info.schemaVersion == 1 && info.enabled, "info")
        let rev0 = try call(demo, "rev", as: LedgerRev.self).rev
        let state = try call(demo, "state", ["range": "7d"], as: LedgerState.self)
        check(state.schemaVersion == 1 && state.rev == rev0 && state.now == start, "state header")
        check(Set(state.sessions.map(\.verdict)) == Set(LedgerVerdict.allCases), "every verdict in the demo: \(Set(state.sessions.map(\.verdict)))")
        check(state.projects.map(\.key) == ["harbor", "meadow"], "two projects")
        check(state.sessions.filter { $0.stream != nil }.count == 1 && state.streams.map(\.state) == [.active, .skipped, .applied], "a stream with three cycles: \(state.streams.map(\.state))")
        let decision = state.sessions.first { $0.role == .decision }!
        check(state.streams.first?.releasedBy == decision.id && decision.verdict == .confirm, "the stream's sync handed the decision session over")
        check(state.overlaps.contains { $0.kind == .same && $0.paths == ["src/auth/session.swift"] } && state.overlaps.contains { $0.kind == .coupled }, "overlaps")
        check(state.pendingPrompts.count == 3 && state.pendingPrompts.allSatisfy { $0.state == .waiting } && state.autoReview?.count == 1, "waiting prompts, and one to review")
        let inbox = LedgerInbox.build(state)
        check(inbox.items(in: .questions).count == state.attention.questions && inbox.items(in: .tidy).count == state.attention.tidy
              && inbox.items(in: .decide).count == state.attention.decide && inbox.items(in: .autoReview).count == state.attention.autoReview
              && inbox.count == state.attention.total, "the Inbox agrees with the core's count: \(state.attention)")
        check(inbox.prompts.map(\.kind) == [.askUserQuestion, .permission, .exitPlanMode], "counting prompts first, soonest deadline first")
        let questions = inbox.items(in: .questions).compactMap { $0.sessionId }
        check(questions.count == 3 && questions[0] != questions[1] && questions[1] == questions[2], "questions stay together, the session asked last first")
        check(inbox.items(in: .tidy).first.flatMap { item in state.sessions.first { $0.id == item.sessionId } }?.verdict == .confirm, "To confirm before Ready to archive")
        let harbor = try call(demo, "state", ["project": "harbor", "range": "7d"], as: LedgerState.self)
        check(harbor.sessions.allSatisfy { $0.project == "harbor" } && harbor.baselines.allSatisfy { $0.project == "harbor" }, "project filter")
        check(harbor.attention.total < state.attention.total, "attention per project")
        let all = try call(demo, "state", ["range": "all"], as: LedgerState.self)
        check(all.hiddenBefore == 0 && all.sessions.count == state.sessions.count, "all")
        for s in state.sessions {
            let detail = try call(demo, "session", ["id": .string(s.id)], as: LedgerSessionDetail.self)
            check(detail.session.id == s.id && detail.session.verdict == s.verdict && !detail.events.isEmpty, "session \(s.id)")
            check(detail.events.map(\.ts) == detail.events.map(\.ts).sorted(), "events in time order")
            check(s.stream == nil || detail.cycles.count == 3, "stream cycles in the record")
        }
        for project in ["harbor", "meadow"] {
            for range in LedgerRange.allCases {
                let graph = try call(demo, "graph", ["project": .string(project), "range": .string(range.rawValue)], as: LedgerGraph.self)
                let ids = Set(graph.nodes.map(\.id))
                check(ids.count == graph.nodes.count && graph.nodes.allSatisfy { $0.lane < graph.lanes } && graph.nodes.contains { $0.lane == 0 }, "graph \(project) \(range)")
                check(graph.edges.allSatisfy { ids.contains($0.to) && (ids.contains($0.from) || $0.kind == .branch) }, "edges point at drawn nodes")
                _ = LedgerGraphPlot.plot(graph, openSessions: Set(state.sessions.map(\.id)))
            }
        }
        let harborGraph = try call(demo, "graph", ["project": "harbor", "range": "all"], as: LedgerGraph.self)
        check(harborGraph.edges.contains { $0.kind == .merge } && harborGraph.edges.contains { $0.kind == .handoff } && harborGraph.nodes.contains { $0.kind == .release }, "joins, hand-offs and a release")

        let hits = try call(demo, "search", ["query": "retry"], as: LedgerSearchResult.self).hits
        check(hits.contains { $0.kind == .session } && hits.contains { $0.kind == .question } && hits.contains { $0.kind == .event }, "search kinds: \(hits.map(\.kind))")
        check(try call(demo, "search", ["query": "v1.4"], as: LedgerSearchResult.self).hits.contains { $0.kind == .baseline }, "versions are found")
        check(try call(demo, "search", ["query": "retry", "limit": 2], as: LedgerSearchResult.self).hits.count == 2, "search limit")
        check(try call(demo, "search", ["query": " "], as: LedgerSearchResult.self).hits.isEmpty, "empty query")

        let paste = """
        Some conversation text.
        ```ledger
        {"event": "start", "title": "Pasted work", "kind": "research", "project": "meadow", "summary": "Started elsewhere"}
        ```
        ```ledger
        {"event": "sync"}
        ```
        ```ledger
        not json
        ```
        """
        let first = try call(demo, "import", ["text": .string(paste)], as: LedgerImportResult.self).results
        check(first.map(\.ok) == [true, false, false] && first[1].error?.contains("version") == true && first[2].error != nil && first[0].sessionId != nil, "import blocks: \(first)")
        let again = try call(demo, "import", ["text": .string(paste)], as: LedgerImportResult.self).results
        check(again[0].duplicate && again[0].ok, "a block imported before is a duplicate, ok and skipped")
        let pastedID = first[0].sessionId!
        let jsonLines = "{\"event\": \"note\", \"session\": \"\(pastedID)\", \"summary\": \"a\"}\n{\"event\": \"progress\", \"session\": \"\(pastedID)\", \"summary\": \"b\"}"
        let lines = try call(demo, "import", ["text": .string(jsonLines)], as: LedgerImportResult.self).results
        check(lines.count == 2 && lines.allSatisfy(\.ok) && lines.allSatisfy { $0.sessionId == first[0].sessionId }, "JSON lines")

        // a person's operations change the demo and move rev
        let confirm = state.sessions.first { $0.verdict == .confirm }!
        var rev = try call(demo, "rev", as: LedgerRev.self).rev
        let wrote = try call(demo, "human", ["action": "ack", "sessionId": .string(confirm.id)], as: LedgerWriteResult.self)
        check(wrote.ok && wrote.rev == rev + 1, "ack bumps rev")
        func verdict(_ id: String) throws -> LedgerVerdict { try call(demo, "session", ["id": .string(id)], as: LedgerSessionDetail.self).session.verdict }
        check(try verdict(confirm.id) == .expirable, "confirmed → ready to archive")
        _ = try call(demo, "human", ["action": "archive", "sessionId": .string(confirm.id)], as: LedgerWriteResult.self)
        check(try verdict(confirm.id) == .archived, "archived")
        _ = try call(demo, "human", ["action": "unarchive", "sessionId": .string(confirm.id)], as: LedgerWriteResult.self)
        _ = try call(demo, "human", ["action": "unack", "sessionId": .string(confirm.id)], as: LedgerWriteResult.self)
        check(try verdict(confirm.id) == .confirm, "back to To confirm")
        let pending = state.sessions.first { $0.verdict == .pendingMerge && $0.project == "harbor" }!
        _ = try call(demo, "human", ["action": "set_status", "sessionId": .string(pending.id), "status": "merged"], as: LedgerWriteResult.self)
        let merged = try call(demo, "session", ["id": .string(pending.id)], as: LedgerSessionDetail.self).session
        check(merged.status == .merged && merged.mergedInto == "v1.4.2" && merged.verdict == .expirable, "a status a person picks counts as confirmed; HEAD by default")
        _ = try call(demo, "human", ["action": "set_status", "sessionId": .string(pending.id), "status": "active"], as: LedgerWriteResult.self)
        let reopened = try call(demo, "session", ["id": .string(pending.id)], as: LedgerSessionDetail.self).session
        check(reopened.status == .active && reopened.ackAt == nil && reopened.mergedInto == nil, "reopen clears confirmation")
        let stale = state.sessions.first { $0.verdict == .stale }!
        _ = try call(demo, "human", ["action": "snooze", "sessionId": .string(stale.id)], as: LedgerWriteResult.self)
        let snoozed = try call(demo, "session", ["id": .string(stale.id)], as: LedgerSessionDetail.self).session
        check(snoozed.verdict == .active && snoozed.snoozeUntil == start + 72 * hour, "Still active: not stale for the stale hours")
        let pastSnooze = failure(demo, "human", ["action": "snooze", "sessionId": .string(stale.id), "until": .number(Double(start))])
        let stillSnoozed = try verdict(stale.id)
        check(pastSnooze?.code == "INVALID_ARGUMENT" && stillSnoozed == .active, "like the core, a snooze ends in the future")
        let asked = state.questions.first { $0.state == .open }!
        _ = try call(demo, "human", ["action": "answer", "sessionId": .string(asked.sessionId), "questionId": .number(Double(asked.id)), "answer": "Yes, both."], as: LedgerWriteResult.self)
        let answered = try call(demo, "session", ["id": .string(asked.sessionId)], as: LedgerSessionDetail.self)
        check(answered.questions.first { $0.id == asked.id }?.state == .answered && answered.events.last?.type == "answer" && answered.events.last?.actor == .human, "answer recorded")
        check(failure(demo, "human", ["action": "answer", "sessionId": .string(asked.sessionId), "questionId": .number(Double(asked.id)), "answer": "again"])?.code == "CONFLICT", "answering twice")
        for (action, extra) in [("shelve", [String: LedgerJSON]()), ("link", ["branch": "feature/x"]), ("message", ["text": "Please add tests."])] {
            var args = extra
            args["action"] = .string(action)
            args["sessionId"] = .string(pending.id)
            check(try call(demo, "human", args, as: LedgerWriteResult.self).ok, action)
        }
        check(try call(demo, "session", ["id": .string(pending.id)], as: LedgerSessionDetail.self).session.links.branch == "feature/x", "link")
        check(failure(demo, "human", ["action": "fly", "sessionId": .string(pending.id)])?.code == "INVALID_ARGUMENT", "unknown action")
        check(failure(demo, "human", ["action": "ack", "sessionId": "S0000-99"])?.code == "NOT_FOUND", "unknown session")
        check(failure(demo, "nope")?.code == "INVALID_ARGUMENT", "unknown method")
        check(try call(demo, "backup", as: LedgerBackupResult.self).path.hasSuffix(".sqlite3"), "backup")
        check((try? LedgerClient.decode(LedgerRev.self, from: Data(#"{"result":{"rev":7}}"#.utf8)))?.rev == 7, "a {result} envelope is unwrapped")
        check((try? LedgerClient.decode(LedgerRev.self, from: Data(#"{"rev":"x"}"#.utf8))) == nil, "a malformed answer throws")

        // prompts: answers, release, hold, and auto-continue when the deadline runs out
        let before = try call(demo, "state", [:], as: LedgerState.self)
        let prompts = before.pendingPrompts
        let ask = prompts.first { $0.kind == .askUserQuestion }!
        let permission = prompts.first { $0.kind == .permission }!
        let plan = prompts.first { $0.kind == .exitPlanMode }!
        let auto = before.autoReview!.first!
        check(try call(demo, "prompt_answer", ["id": .number(Double(permission.id)), "answer": .object(LedgerPromptReply.holdAuto.answer)], as: LedgerWriteResult.self).ok, "hold")
        check(try call(demo, "state", [:], as: LedgerState.self).pendingPrompts.first { $0.id == permission.id }?.deadline == 0, "held: no deadline")
        _ = try call(demo, "prompt_answer", ["id": .number(Double(plan.id)), "answer": .object(LedgerPromptReply.answerInTerminal.answer)], as: LedgerWriteResult.self)
        check(!(try call(demo, "state", [:], as: LedgerState.self).pendingPrompts.contains { $0.id == plan.id }), "released to the terminal")
        check(try call(demo, "prompt_answer", ["id": .number(Double(plan.id)), "answer": ["decision": "allow"]], as: LedgerWriteResult.self).ok == false,
              "an answer to a prompt that no longer waits does not win")
        _ = try call(demo, "prompt_review", ["id": .number(Double(auto.id))], as: LedgerWriteResult.self)
        let reviewedState = try call(demo, "state", [:], as: LedgerState.self)
        check(reviewedState.attention.autoReview == 0 && reviewedState.autoReview?.isEmpty == true, "reviewed")
        check(failure(demo, "prompt_review", ["id": 999])?.code == "NOT_FOUND", "reviewing a prompt that was not auto-continued")
        rev = try call(demo, "rev", as: LedgerRev.self).rev
        clock.advance(46_000)
        let after = try call(demo, "state", [:], as: LedgerState.self)
        let expired = after.autoReview?.first { $0.id == ask.id }
        check(after.rev > rev && expired?.state == .auto && expired?.answeredBy == .auto && !after.pendingPrompts.contains { $0.id == ask.id },
              "the deadline ran out: auto-continue answered")
        check(expired?.answer?["answers"]?.object?.values.first?.string == "3 times (Recommended)", "the recommended option")
        check(after.attention.autoReview == 1, "to review")
        let retry = try call(demo, "session", ["id": .string(ask.sessionId!)], as: LedgerSessionDetail.self)
        check(retry.events.last?.type == "auto_reply" && retry.events.last?.actor == .auto, "auto_reply event")
        clock.advance(21_000)
        let arrived = try call(demo, "state", [:], as: LedgerState.self).pendingPrompts.filter { $0.state == .waiting && $0.deadline > clock.now() }
        check(arrived.contains { $0.kind == .stopQuestion }, "a new prompt arrives after a while")
        let stopQuestion = arrived.first { $0.kind == .stopQuestion }!
        check(try call(demo, "prompt_answer", ["id": .number(Double(stopQuestion.id)), "answer": .object(LedgerPromptReply.text("Open it now.").answer)], as: LedgerWriteResult.self).ok, "typed answer")
        let empty = DemoLedgerBackend(mode: .empty, clock: { clock.now() })
        let nothing = try call(empty, "state", [:], as: LedgerState.self)
        check(nothing.sessions.isEmpty && nothing.pendingPrompts.isEmpty && nothing.attention.total == 0, "empty demo")

        // Settings › Ledger on the demo: the same shapes as the core
        let rules = DemoLedgerBackend(clock: { clock.now() })
        let stored = try call(rules, "settings", as: LedgerGlobalSettings.self)
        check(stored == DemoLedgerBackend.defaultSettings && stored.kinds["implementation"]?.line == "core", "demo settings")
        let spike = LedgerGlobalSettings.kindsArgument(["spike": .init(role: .implementation, line: "", handoff: false)])
        let saved = try call(rules, "settings_set", ["values": ["staleHours": 24, "kinds": spike]], as: LedgerSettingsWrite.self).settings
        check(saved.staleHours == 24 && saved.kinds == ["spike": .init(role: .implementation, line: "core", handoff: false)], "demo settings_set: \(saved)")
        check(failure(rules, "settings_set", ["values": ["backupKeep": 0]])?.code == "INVALID_ARGUMENT", "a value out of range is refused")
        check(failure(rules, "settings_set", ["values": ["colour": 1]])?.code == "INVALID_ARGUMENT", "an unknown setting is refused")
        let reset = try call(rules, "settings_set", ["values": ["staleHours": .null, "kinds": .null]], as: LedgerSettingsWrite.self).settings
        check(reset == DemoLedgerBackend.defaultSettings, "null puts the defaults back")
        let projects = try call(rules, "projects", as: LedgerProjectList.self).projects
        check(projects.map(\.key) == ["harbor", "meadow"] && projects.allSatisfy { $0.baselineSource == .tags && $0.baselinePattern == DemoLedgerBackend.defaultPattern }, "demo projects")
        let renamed = try call(rules, "project_set", ["project": "harbor", "name": "Harbour", "baselineSource": "folder", "scanSubdirs": ["specs"]], as: LedgerProjectWrite.self).project
        let named = try call(rules, "state", [:], as: LedgerState.self).projects.first { $0.key == "harbor" }?.name
        check(renamed.name == "Harbour" && renamed.baselineSource == .folder && renamed.scanSubdirs == ["specs"] && named == "Harbour", "demo project_set")
        check(failure(rules, "project_set", ["project": "harbor", "baselineSource": "ftp"])?.code == "INVALID_ARGUMENT", "an unknown source is refused")
        let scanned = try call(rules, "scan", ["project": "harbor"], as: LedgerScanResult.self).results
        check(scanned.count == 1 && scanned[0].found > 0 && scanned[0].source == "folder", "demo scan")
        check(failure(rules, "import_legacy", ["path": "/nowhere"])?.code == "INVALID_ARGUMENT", "the demo cannot import a database")
    }

    @MainActor static func store() async throws {
        let clock = TestClock(start)
        let spy = SpyBackend(DemoLedgerBackend(clock: { clock.now() }))
        let suite = "dev.gitrochi.ledger-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = LedgerStore(client: LedgerClient(backend: spy), defaults: defaults, interval: .seconds(60))
        check(ledger.range == .week, "the default period")
        await ledger.poll()
        check(ledger.state != nil && spy.count("state") == 1 && ledger.inbox.count == ledger.state?.attention.total, "first read")
        await ledger.poll()
        await ledger.poll()
        check(spy.count("rev") == 3 && spy.count("state") == 1, "rev unchanged: the state is not read again")
        await ledger.setRange(.month)
        check(defaults.string(forKey: "ledgerRange") == "30d" && spy.count("state") == 2, "the period is remembered and read")
        check(LedgerStore(client: LedgerClient(backend: spy), defaults: defaults).range == .month, "and read back")

        let confirm = ledger.state!.sessions.first { $0.verdict == .confirm }!
        ledger.selection = confirm.id
        await ledger.perform(.ack, on: [confirm.id], message: "Confirmed")
        check(ledger.session(confirm.id)?.verdict == .expirable && ledger.toast?.canUndo == true && ledger.canUndo, "confirm, with Undo")
        check(ledger.detail?.session.id == confirm.id && ledger.detail?.session.verdict == .expirable, "the open record follows")
        await ledger.perform(.archive, on: [confirm.id], message: "Archived")
        check(ledger.session(confirm.id)?.verdict == .archived, "archived")
        await ledger.undo()
        check(ledger.session(confirm.id)?.verdict == .expirable, "undo archive")
        await ledger.undo()
        check(ledger.session(confirm.id)?.verdict == .confirm && !ledger.canUndo, "undo confirm")

        let live = ledger.state!.sessions.first { $0.verdict == .active && $0.stream == nil }!
        await ledger.perform(.setStatus(.closed, version: nil), on: [live.id], message: "Closed")
        check(ledger.session(live.id)?.verdict == .expirable, "a closed session a person closed is confirmed")
        await ledger.undo()
        let restored = ledger.session(live.id)
        check(restored?.status == .active && restored?.ackAt == nil && restored?.verdict == .active, "undo close")

        let bulk = ledger.state!.sessions.filter { $0.verdict == .pendingMerge || $0.verdict == .stale }.map(\.id)
        await ledger.perform(.setStatus(.closed, version: nil), on: bulk, message: "Closed")
        check(bulk.count == 3 && ledger.inbox.items(in: .decide).isEmpty && bulk.allSatisfy { ledger.session($0)?.verdict == .expirable }, "bulk close")
        await ledger.undo()
        check(Set(ledger.inbox.items(in: .decide).compactMap(\.sessionId)) == Set(bulk), "bulk undo")
        let stale = ledger.state!.sessions.first { $0.verdict == .stale }!
        await ledger.perform(.stillActive, on: [stale.id], message: "Still active")
        check(ledger.session(stale.id)?.verdict == .active && !ledger.inbox.items.contains { $0.sessionId == stale.id }, "Still active leaves the Inbox")
        check(ledger.toast?.canUndo == false && !ledger.canUndo && ledger.actionError == nil, "no Undo without a snooze to put back")
        let firstSnooze = ledger.session(stale.id)!.snoozeUntil!
        await ledger.perform(.snooze(until: firstSnooze + hour), on: [stale.id], message: "Snoozed")
        check(ledger.toast?.canUndo == true && ledger.session(stale.id)?.snoozeUntil == firstSnooze + hour, "a later snooze can put the running one back")
        await ledger.undo()
        check(ledger.session(stale.id)?.snoozeUntil == firstSnooze && ledger.session(stale.id)?.verdict == .active && ledger.actionError == nil, "undo Still active")

        let question = ledger.inbox.items(in: .questions).compactMap { item -> LedgerQuestion? in if case .question(let q) = item.content { return q }; return nil }.first!
        ledger.drafts[question.id] = "  "
        check(await !ledger.answer(question), "an empty answer is not sent")
        ledger.drafts[question.id] = "Both, please."
        spy.failing = "human"
        check(await !ledger.answer(question) && ledger.drafts[question.id] == "Both, please." && ledger.actionError == "Refused by the test", "a failed answer keeps the draft")
        spy.failing = nil
        ledger.actionError = nil
        check(await ledger.answer(question) && ledger.drafts[question.id] == nil, "answered")
        check(!ledger.inbox.items.contains { $0.id == "q\(question.id)" }, "the question leaves the Inbox")

        let prompt = ledger.inbox.prompts.first { $0.kind == .permission }!
        await ledger.reply(prompt, .holdAuto)
        check(ledger.inbox.prompts.first { $0.id == prompt.id }.map { !LedgerCountdown.isCounting($0) } == true, "auto off for this prompt")
        await ledger.reply(prompt, .allow)
        check(!ledger.inbox.prompts.contains { $0.id == prompt.id } && ledger.toast?.canUndo == false, "allowed")
        let review = ledger.inbox.items(in: .autoReview).compactMap { item -> LedgerPendingPrompt? in if case .autoReply(let p) = item.content { return p }; return nil }.first!
        await ledger.review(review, correction: "Keep them for 30 days instead.")
        check(ledger.inbox.items(in: .autoReview).isEmpty, "a correction also counts as reviewed")

        clock.advance(46_000)
        await ledger.poll()
        check(ledger.inbox.items(in: .autoReview).count == 1, "polling sees the deadline run out")

        await ledger.follow(repository: "/tmp/somewhere/Meadow")
        check(ledger.project == "meadow" && ledger.state?.sessions.allSatisfy { $0.project == "meadow" } == true, "follows the open repository")
        await ledger.choose(project: nil)
        await ledger.follow(repository: "/tmp/somewhere/Meadow")
        check(ledger.project == nil && ledger.projectChosen, "a person's choice wins")
        await ledger.follow(repository: "/tmp/somewhere/harbor")
        check(ledger.project == "harbor" && !ledger.projectChosen && ledger.repositoryProject == "harbor", "another repository follows again")
        await ledger.choose(project: nil)
        await ledger.resumeFollowing()
        check(ledger.project == "harbor", "back to the repository's project")
        await ledger.choose(project: nil)

        ledger.page = .graph
        await ledger.loadGraph()
        check(ledger.graph != nil && !ledger.plot.rows.isEmpty && ledger.graphProject == "harbor", "graph of the first project")
        await ledger.chooseGraphProject("meadow")
        check(!ledger.plot.rows.isEmpty && ledger.plot.rows.compactMap { $0.node.lane > 0 ? $0.node.sessionId : nil }.allSatisfy { ledger.session($0)?.project == "meadow" }, "graph of another project")
        let hits = await ledger.search("cache")
        check(!hits.isEmpty && hits.allSatisfy { !$0.title.isEmpty }, "search")
        if let event = hits.first(where: { $0.kind == .event }) {
            ledger.open(event)
            check(ledger.selection == event.sessionId && ledger.highlightedEvent != nil, "a report result opens its session at the report")
        }
        check(await ledger.search("x").isEmpty, "one letter is not searched")
        let imported = try await ledger.importReports("```ledger\n{\"event\": \"start\", \"title\": \"From a paste\", \"project\": \"harbor\"}\n```")
        check(imported.first?.ok == true, "import through the store")
        check(try await ledger.info().schemaVersion == 1, "connection test")

        var filter = ledger.filter
        filter.text = "export"
        ledger.filter = filter
        try await Task.sleep(for: .milliseconds(100))
        check(!ledger.boardRows.isEmpty && ledger.boardRows.allSatisfy { ($0.title + $0.id + $0.kind + ($0.links.branch ?? "") + $0.touches.joined()).localizedStandardContains("export") }, "the Board follows the filter")
    }

    /// The core's demo read by the app: every answer decodes, and the client's grouping agrees with the core's counts
    @MainActor static func core(binary: String, folder: String) async throws {
        let backend = CLIBackend(binary: binary, db: folder + "/ledger.sqlite3")
        _ = backend.run(["demo", folder + "/ledger.sqlite3"])
        let client = LedgerClient(backend: backend)
        let info = try await client.info()
        check(info.schemaVersion == 1 && info.enabled, "core info")
        let rev = try await client.rev()
        let state = try await client.state(project: nil, range: .all)
        check(state.rev == rev && !state.sessions.isEmpty && state.autoReview != nil, "core state: \(state.sessions.count) sessions")
        check(Set(state.sessions.map(\.verdict)).count >= 7, "the core's demo has the verdicts: \(Set(state.sessions.map(\.verdict)))")
        let inbox = LedgerInbox.build(state)
        check(inbox.items(in: .questions).count == state.attention.questions && inbox.items(in: .autoReview).count == state.attention.autoReview
              && inbox.items(in: .tidy).count == state.attention.tidy && inbox.items(in: .decide).count == state.attention.decide,
              "the app's Inbox groups agree with the core's counts: \(state.attention), app \(LedgerInbox.Group.allCases.map { inbox.items(in: $0).count })")
        _ = try await client.state(project: nil, range: .week)
        for s in state.sessions {
            let detail = try await client.session(s.id)
            check(detail.session.id == s.id, "core session \(s.id)")
        }
        for p in state.projects {
            for range in LedgerRange.allCases {
                let graph = try await client.graph(project: p.key, range: range)
                let plot = LedgerGraphPlot.plot(graph)
                check(plot.rows.count == graph.nodes.count && plot.lanes >= graph.lanes, "core graph \(p.key) \(range)")
            }
        }
        check(!(try await client.search("v1", project: nil)).isEmpty, "core search")
        do {
            _ = try await client.human(.ack, sessionId: state.sessions[0].id)
            check(false, "an agent caller cannot confirm")
        } catch let failure as LedgerFailure {
            check(failure.code == "NOT_ALLOWED", "a person's operation through the CLI: \(failure.code)")
        }
        let suite = "dev.gitrochi.ledger-core-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LedgerStore(client: client, defaults: defaults, interval: .seconds(600))
        await store.poll()
        check(store.state != nil && store.inbox.count == store.attentionTotal && store.loadError == nil, "the store reads the core")
        print("Core contract: \(state.sessions.count) sessions, \(state.projects.count) projects, attention \(state.attention.total) — decoded and grouped like the core")
    }

    /// The core through its C ABI, as the app reads it: the same ledger the command line sees, a person's operations,
    /// settings and projects, backups, both imports, several threads at once, the switch that turns it off, and the
    /// bundled command's MCP handshake. Every call names a database in `folder`.
    @MainActor static func native(cli: String, folder: String, legacy: String) async throws {
        let db = folder + "/ledger.sqlite3"
        _ = CLIBackend(binary: cli, db: db).run(["demo", db])
        let native = NativeLedgerBackend(database: db)
        let client = LedgerClient(backend: native)
        check(LedgerStore.makeBackend(environment: [:]) is NativeLedgerBackend && LedgerStore.makeBackend(environment: ["GITROCHI_LEDGER_DEMO": ""]) is NativeLedgerBackend,
              "the preview reads the core")
        check(LedgerStore.makeBackend(environment: ["GITROCHI_LEDGER_DEMO": "empty"]) is DemoLedgerBackend, "GITROCHI_LEDGER_DEMO still picks a demo")
        let info = try await client.info()
        check(info.schemaVersion == 1 && info.enabled && info.dbPath == db, "C ABI info: \(info.dbPath)")
        let state = try await client.state(project: nil, range: .all)
        let agent = try await LedgerClient(backend: CLIBackend(binary: cli, db: db)).state(project: nil, range: .all)
        check(!state.sessions.isEmpty && state.rev == agent.rev && state.sessions.map(\.id) == agent.sessions.map(\.id) && state.attention == agent.attention,
              "the C ABI and the command line read the same ledger")
        let inbox = LedgerInbox.build(state)
        check(inbox.items(in: .questions).count == state.attention.questions && inbox.items(in: .tidy).count == state.attention.tidy
              && inbox.items(in: .decide).count == state.attention.decide, "the Inbox groups agree with the core's counts")
        for s in state.sessions.prefix(8) {
            let detail = try await client.session(s.id)
            check(detail.session.id == s.id, "session \(s.id) through the C ABI")
        }
        for p in state.projects {
            let graph = try await client.graph(project: p.key, range: .all)
            check(LedgerGraphPlot.plot(graph).rows.count == graph.nodes.count, "graph \(p.key) through the C ABI")
        }
        let reads = await withTaskGroup(of: Int?.self) { group in
            for i in 0..<24 { group.addTask { i % 4 == 0 ? try? await client.state(project: nil, range: .week).rev : try? await client.rev() } }
            return await group.reduce(into: [Int?]()) { $0.append($1) }
        }
        check(reads.count == 24 && reads.allSatisfy { $0 == state.rev }, "calls from several threads at once: \(reads)")

        // A person's operations, which the command line refuses
        guard let confirm = state.sessions.first(where: { $0.verdict == .confirm }) else { return check(false, "the core's demo has a session to confirm") }
        let written = try await client.human(.ack, sessionId: confirm.id)
        let confirmed = try await client.session(confirm.id).session
        check(written.ok && (written.rev ?? 0) > state.rev && confirmed.verdict == .expirable, "a person's operation through the C ABI")
        let suite = "dev.gitrochi.ledger-native-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LedgerStore(client: client, defaults: defaults, interval: .seconds(600))
        await store.poll()
        check(store.state != nil && store.loadError == nil && store.inbox.count == store.attentionTotal, "the store reads the core")
        if let stale = store.state?.sessions.first(where: { $0.verdict == .stale }) {
            await store.perform(.stillActive, on: [stale.id], message: "Still active")
            let first = store.session(stale.id)?.snoozeUntil
            check(store.session(stale.id)?.verdict == .active && first != nil && store.actionError == nil, "Still active in the core")
            try await Task.sleep(for: .milliseconds(20))
            await store.perform(.stillActive, on: [stale.id], message: "Still active")
            check(store.toast?.canUndo == true && store.session(stale.id)?.snoozeUntil != first, "a second Still active")
            await store.undo()
            check(store.session(stale.id)?.snoozeUntil == first && store.actionError == nil, "the core takes the running snooze back: \(store.actionError ?? "")")
        } else {
            check(false, "the core's demo has a stale session")
        }

        // Settings: the demo's defaults are the core's; verdicts follow the stale hours
        let initial = try await client.settings()
        check(initial == DemoLedgerBackend.defaultSettings, "the demo's default settings are the core's: \(initial)")
        let now = try await client.state(project: nil, range: .all)
        let quiet = now.sessions.first { $0.verdict == .active && $0.stream == nil && $0.lastAt < now.now - 2 * hour && ($0.snoozeUntil ?? 0) < now.now }
        let hourly = try await client.setSettings(["staleHours": 1])
        let afterHourly = try await client.state(project: nil, range: .all)
        check(hourly.staleHours == 1 && quiet.map { q in afterHourly.sessions.first { $0.id == q.id }?.verdict == .stale } ?? true, "verdicts follow the stale hours")
        var kinds = hourly.kinds
        kinds["spike"] = .init(role: .research)
        kinds["review"] = nil
        let custom = try await client.setSettings(["kinds": LedgerGlobalSettings.kindsArgument(kinds), "backupKeep": 3])
        check(custom.kinds["spike"]?.role == .research && custom.kinds["review"] == nil && custom.backupKeep == 3, "kinds are replaced as a whole")
        check(failure(native, "settings_set", ["values": ["staleHours": -1]])?.code == "INVALID_ARGUMENT", "a bad value is refused")
        let reset = try await client.setSettings(["staleHours": .null, "kinds": .null, "backupKeep": .null])
        check(reset == initial, "null puts the defaults back")

        // Projects and their baseline sources
        let projects = try await client.projects()
        check(!projects.isEmpty && projects.allSatisfy { $0.baselineSource == .tags && $0.baselinePattern == DemoLedgerBackend.defaultPattern }, "projects: \(projects.map(\.key))")
        let key = projects[0].key
        let renamed = try await client.setProject(key, ["name": "Renamed", "baselineSource": "manual"])
        check(renamed.name == "Renamed" && renamed.baselineSource == .manual, "project_set")
        try FileManager.default.createDirectory(atPath: folder + "/specs/v9.9.0", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: folder + "/v9.8.7", withIntermediateDirectories: true)
        let fromFolder = try await client.setProject(key, ["baselineSource": "folder", "baselineDir": .string(folder), "scanSubdirs": ["specs"]])
        check(fromFolder.baselineSource == .folder && fromFolder.baselineDir == folder && fromFolder.scanSubdirs == ["specs"], "a folder source")
        check(failure(native, "project_set", ["project": .string(key), "baselinePattern": "(unclosed"])?.code == "INVALID_ARGUMENT", "a bad pattern is refused")
        let scanned = try await client.scan(project: key)
        let trunk = try await client.state(project: key, range: .all).baselines.filter { $0.project == key }.map(\.version)
        check(scanned.count == 1 && scanned[0].found == 2 && scanned[0].added == 2 && scanned[0].error == nil && trunk.contains("9.9.0") && trunk.contains("9.8.7"),
              "a scan finds folder versions: \(scanned), \(trunk)")
        let cleared = try await client.setProject(key, ["name": .null, "baselineSource": .null, "baselineDir": .null, "scanSubdirs": []])
        check(cleared.name == key && cleared.baselineSource == .tags && cleared.baselineDir == nil && cleared.scanSubdirs.isEmpty, "null clears")

        // Backups and imports
        let backup = try await client.backup()
        check(backup.hasPrefix(folder + "/backups/") && FileManager.default.fileExists(atPath: backup), "a backup next to the database: \(backup)")
        let block = "```ledger\n{\"event\": \"start\", \"session\": \"native-paste\", \"title\": \"From a paste\", \"project\": \"harbor\"}\n```"
        let pasted = try await client.importReports(block, project: nil)
        let again = try await client.importReports(block, project: nil)
        check(pasted.first?.ok == true && pasted.first?.duplicate == false && again.first?.duplicate == true, "a pasted report, then the same again")
        let original = try Data(contentsOf: URL(fileURLWithPath: legacy))
        let revBefore = try await client.rev()
        let preview = try await client.importLegacy(path: legacy, dryRun: true)
        let revPreview = try await client.rev()
        check(preview.ok && preview.dryRun && revPreview == revBefore && preview.counts.sessions == 2 && preview.counts.events == 2
              && preview.counts.questions == 1 && preview.counts.baselines == 1 && preview.counts.projects == 1, "a dry run counts without writing: \(preview.counts)")
        let imported = try await client.importLegacy(path: legacy, dryRun: false)
        let revImported = try await client.rev()
        check(!imported.dryRun && imported.counts == preview.counts && revImported > revBefore && imported.skipped.isEmpty && imported.errors.isEmpty, "the import")
        let twice = try await client.importLegacy(path: legacy, dryRun: true)
        check(twice.counts.sessions == 0 && Set(twice.skipped) == ["legacy-one", "legacy-two"], "sessions the ledger has are skipped: \(twice.skipped)")
        check((try Data(contentsOf: URL(fileURLWithPath: legacy))) == original, "the claude-ledger file is left as it was")
        let all = try await client.state(project: nil, range: .all).sessions.map(\.kind)
        check(try await client.settings().unassignedKinds(among: all).contains("spike"), "an imported kind without a role is listed for Settings")
        check(failure(native, "import_legacy", ["path": .string(folder + "/missing.db")])?.code == "INVALID_ARGUMENT", "a missing file is refused")

        // Errors, and the switch that turns the core off
        check(failure(native, "no_such_method")?.code == "INVALID_ARGUMENT", "an unknown method")
        let garbled = String(decoding: native.call(method: "rev", args: Data("{".utf8)), as: UTF8.self)
        check(garbled.contains("INVALID_ARGUMENT"), "arguments that are not JSON: \(garbled)")
        setenv("GITROCHI_LEDGER", "0", 1)
        let off = try call(native, "info", as: LedgerInfo.self)
        let refused = failure(native, "state")
        unsetenv("GITROCHI_LEDGER")
        check(!off.enabled && refused?.code == "DISABLED", "GITROCHI_LEDGER=0 turns the core off: \(refused?.code ?? "")")

        // The command Connect Claude Code points at
        let tools = try await LedgerCommandLine.tools(binary: URL(fileURLWithPath: cli))
        check(tools == ["ledger_overview", "ledger_report", "ledger_session"], "the command's MCP tools: \(tools)")
        do {
            _ = try await LedgerCommandLine.tools(binary: URL(fileURLWithPath: folder + "/missing"))
            check(false, "a missing command is reported")
        } catch let missing as LedgerFailure {
            check(missing.code == "NOT_FOUND", "a missing command: \(missing.code)")
        }
        print("C ABI: \(state.sessions.count) sessions read as the app; operations, settings, projects, scan, backup, both imports and the MCP handshake checked")
    }

    @MainActor static func large() async throws {
        var clock = Date()
        let demo = DemoLedgerBackend(mode: .large)
        let seed = seconds(clock)
        let client = LedgerClient(backend: demo)
        clock = Date()
        let state = try await client.state(project: nil, range: .all)
        let stateTime = seconds(clock)
        check(state.sessions.count == 1_000, "1,000 sessions")
        var events = 0
        for project in ["harbor", "meadow"] {
            let graph = try await client.graph(project: project, range: .all)
            events += graph.nodes.filter { $0.lane > 0 }.count
        }
        check(events == 50_000, "50,000 events: \(events)")
        clock = Date()
        let inbox = LedgerInbox.build(state)
        let inboxTime = seconds(clock)
        check(inbox.count == state.attention.total, "large Inbox agrees with the count")
        clock = Date()
        var filter = LedgerSessionFilter()
        filter.text = "export"
        let rows = filter.apply(state.sessions)
        filter.text = ""
        filter.verdicts = [.archived]
        let archived = filter.apply(state.sessions)
        let counts = LedgerSessionFilter.counts(state.sessions)
        let filterTime = seconds(clock) / 3
        check(!rows.isEmpty && !archived.isEmpty && counts.values.reduce(0, +) == state.sessions.filter { $0.stream == nil }.count, "large filters")
        clock = Date()
        let graph = try await client.graph(project: "harbor", range: .all)
        let graphTime = seconds(clock)
        let open = Set(state.sessions.filter { !$0.status.isFinished && $0.status != .shelved }.map(\.id))
        clock = Date()
        let window = LedgerGraphPlot.plot(graph, openSessions: open, limit: 1_500)
        let plotTime = seconds(clock)
        clock = Date()
        let whole = LedgerGraphPlot.plot(graph, openSessions: open)
        let wholeTime = seconds(clock)
        check(window.rows.count == 1_500 && window.hiddenRows == graph.nodes.count - 1_500 && whole.rows.count == graph.nodes.count, "graph rows")
        clock = Date()
        let week = try await client.state(project: nil, range: .week)
        let weekTime = seconds(clock)
        check(week.hiddenBefore > 0 && week.sessions.count < state.sessions.count, "the period hides old, finished sessions: \(week.hiddenBefore)")
        clock = Date()
        let hits = try await client.search("item 999", project: nil, limit: 30)
        let searchTime = seconds(clock)
        check(!hits.isEmpty, "large search")
        clock = Date()
        let detail = try await client.session(state.sessions[500].id)
        let detailTime = seconds(clock)
        check(detail.events.count == 50, "a large session's record")
        check(stateTime < 2 && inboxTime < 0.5 && filterTime < 0.5 && plotTime < 2 && searchTime < 2, "large mode stays responsive")
        print("Large demo: seed \(ms(seed)); state(all, 1,000 sessions) \(ms(stateTime)); state(7 days) \(ms(weekTime)), \(week.sessions.count) sessions, \(week.hiddenBefore) hidden; "
              + "Inbox \(ms(inboxTime)); Board filter \(ms(filterTime)); graph(all, \(graph.nodes.count) nodes, \(graph.lanes) lanes) \(ms(graphTime)); "
              + "rows for 1,500 \(ms(plotTime)), for all \(ms(wholeTime)); search \(ms(searchTime)); session record \(ms(detailTime))")
    }
}
SWIFT
ARCH="$(uname -m)"
case "$ARCH" in arm64) TRIPLE=aarch64-apple-darwin ;; *) TRIPLE=x86_64-apple-darwin ;; esac
# The library the app links (the ledger's C ABI is re-exported there) and the gitrochi-ledger command next to it
cp "$(bash "$ROOT/../tools/build-core-native.sh" "$ARCH")" "$TASK_TMP/core.a"
swiftc -O -parse-as-library -swift-version 5 -target "$ARCH-apple-macos15.0" -I "$ROOT/../crates/gitrochi-core/include" \
    "$ROOT/Sources/Core/LedgerModels.swift" "$ROOT/Sources/Services/LedgerBackend.swift" "$ROOT/Sources/Services/LedgerDemoBackend.swift" \
    "$ROOT/Sources/Services/LedgerNativeBackend.swift" "$ROOT/Sources/Services/LedgerCommandLine.swift" \
    "$ROOT/Sources/Store/LedgerStore.swift" "$ROOT/Sources/Views/Ledger/LedgerPresentation.swift" "$ROOT/Sources/Views/Ledger/LedgerGraphLayout.swift" \
    "$TASK_TMP/main.swift" "$TASK_TMP/core.a" -o "$TASK_TMP/test-ledger"
CORE="${GITROCHI_LEDGER_BIN:-$ROOT/../crates/target/$TRIPLE/release/gitrochi-ledger}"
[[ -x "$CORE" ]] || { echo "No gitrochi-ledger command at $CORE" >&2; exit 1; }
mkdir -p "$TASK_TMP/core" "$TASK_TMP/native"
# A call that names no database would use this one, never the person's ledger
export GITROCHI_LEDGER_DB="$TASK_TMP/default.sqlite3"
sqlite3 "$TASK_TMP/claude-ledger.db" < "$ROOT/Tools/fixtures/claude-ledger.sql"
"$TASK_TMP/test-ledger" --core "$CORE" "$TASK_TMP/core" --native "$CORE" "$TASK_TMP/native" "$TASK_TMP/claude-ledger.db"
