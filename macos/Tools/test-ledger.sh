#!/usr/bin/env bash
# The Ledger screens' logic without SwiftUI: the pure presentation rules (verdict order, countdowns, filters, Inbox
# grouping, undo, graph rows and coordinates), every demo backend answer decoded with the app's contract models,
# LedgerStore (polling by rev, operations, undo, prompts) and the large demo (1,000 sessions, 50,000 events) with timings.
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
        print("PASS: \(checks) checks — verdict order, countdowns, filters, Inbox groups, undo, graph rows and coordinates, every demo answer decoded, errors, deadlines, store polling by rev, operations with undo, prompts, large demo")
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
        check(LedgerUndo.inverse(of: .ack, before: before) == [.unack], "undo confirm")
        check(LedgerUndo.inverse(of: .archive, before: before) == [.unarchive], "undo archive")
        before.snoozeUntil = 77
        check(LedgerUndo.inverse(of: .stillActive, before: before) == [.snooze(until: 77)], "undo Still active restores the old time")
        check(LedgerUndo.inverse(of: .setStatus(.active, version: nil), before: before) == [.setStatus(.merged, version: "v1.2.0"), .unack], "undo reopen")
        before.ackAt = 5
        before.archivedAt = 6
        check(LedgerUndo.inverse(of: .setStatus(.closed, version: nil), before: before) == [.setStatus(.merged, version: "v1.2.0"), .ack, .archive], "undo restores confirm and archive")
        check(LedgerUndo.inverse(of: .answer(questionId: 1, text: "a"), before: before) == nil && LedgerUndo.inverse(of: .message(text: "m"), before: before) == nil, "answers and messages are not undone")

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

        check(LedgerHumanAction.setStatus(.merged, version: "v2").arguments == ["action": "set_status", "status": "merged", "version": "v2"], "set_status shape")
        check(LedgerHumanAction.reviewAuto(promptId: 4).arguments == ["action": "review", "promptId": 4], "review shape")
        check(LedgerHumanAction.stillActive.arguments == ["action": "snooze"], "Still active leaves the time to the core")
        check(LedgerHumanAction.snooze(until: nil).arguments == ["action": "snooze", "until": .null], "undo clears with null")
        check(LedgerPromptReply.choices(["Q?": "A"]).answer == ["answers": ["Q?": "A"]] && LedgerPromptReply.holdAuto.answer == ["hold": true], "prompt answer shapes")
        check(LedgerPromptReply.deny(message: "").answer == ["decision": "deny"] && LedgerPromptReply.deny(message: "no").answer == ["decision": "deny", "message": "no"], "deny shape")
        let encoded = String(decoding: try! JSONEncoder().encode(LedgerJSON.object(["n": 3, "f": .number(1.5)])), as: UTF8.self)
        check(encoded.contains("\"n\":3") && encoded.contains("1.5"), "whole numbers stay whole: \(encoded)")
        check((try? JSONDecoder().decode([LedgerVerdict].self, from: Data(#"["needs_human","from_a_newer_core"]"#.utf8))) == [.needsHuman, .active], "unknown values fall back")
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
        check(state.pendingPrompts.filter { $0.state == .waiting }.count == 3 && state.pendingPrompts.filter { $0.state == .auto }.count == 1, "prompts")
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
        check(again[0].duplicate && !again[0].ok, "a block imported before is a duplicate")
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
        _ = try call(demo, "human", ["action": "snooze", "sessionId": .string(stale.id), "until": .null], as: LedgerWriteResult.self)
        check(try verdict(stale.id) == .stale, "a null time clears it")
        let asked = state.questions.first { $0.state == .open }!
        _ = try call(demo, "human", ["action": "answer", "sessionId": .string(asked.sessionId), "questionId": .number(Double(asked.id)), "text": "Yes, both."], as: LedgerWriteResult.self)
        let answered = try call(demo, "session", ["id": .string(asked.sessionId)], as: LedgerSessionDetail.self)
        check(answered.questions.first { $0.id == asked.id }?.state == .answered && answered.events.last?.type == "answer" && answered.events.last?.actor == .human, "answer recorded")
        check(failure(demo, "human", ["action": "answer", "sessionId": .string(asked.sessionId), "questionId": .number(Double(asked.id)), "text": "again"])?.code == "CONFLICT", "answering twice")
        for (action, extra) in [("shelve", [String: LedgerJSON]()), ("link", ["kind": "branch", "value": "feature/x"]), ("message", ["text": "Please add tests."])] {
            var args = extra
            args["action"] = .string(action)
            args["sessionId"] = .string(pending.id)
            check(try call(demo, "human", args, as: LedgerWriteResult.self).ok, action)
        }
        check(try call(demo, "session", ["id": .string(pending.id)], as: LedgerSessionDetail.self).session.links.branch == "feature/x", "link")
        check(failure(demo, "human", ["action": "fly", "sessionId": .string(pending.id)])?.code == "BAD_REQUEST", "unknown action")
        check(failure(demo, "human", ["action": "ack", "sessionId": "S0000-99"])?.code == "NOT_FOUND", "unknown session")
        check(failure(demo, "nope")?.code == "UNKNOWN_METHOD", "unknown method")
        check(try call(demo, "backup", as: LedgerBackupResult.self).path.hasSuffix(".sqlite3"), "backup")
        check((try? LedgerClient.decode(LedgerRev.self, from: Data(#"{"result":{"rev":7}}"#.utf8)))?.rev == 7, "a {result} envelope is unwrapped")
        check((try? LedgerClient.decode(LedgerRev.self, from: Data(#"{"rev":"x"}"#.utf8))) == nil, "a malformed answer throws")

        // prompts: answers, release, hold, and auto-continue when the deadline runs out
        let prompts = try call(demo, "state", [:], as: LedgerState.self).pendingPrompts
        let ask = prompts.first { $0.kind == .askUserQuestion && $0.state == .waiting }!
        let permission = prompts.first { $0.kind == .permission }!
        let plan = prompts.first { $0.kind == .exitPlanMode }!
        let auto = prompts.first { $0.state == .auto }!
        check(try call(demo, "prompt_answer", ["id": .number(Double(permission.id)), "answer": .object(LedgerPromptReply.holdAuto.answer)], as: LedgerWriteResult.self).ok, "hold")
        check(try call(demo, "state", [:], as: LedgerState.self).pendingPrompts.first { $0.id == permission.id }?.deadline == 0, "held: no deadline")
        _ = try call(demo, "prompt_answer", ["id": .number(Double(plan.id)), "answer": .object(LedgerPromptReply.answerInTerminal.answer)], as: LedgerWriteResult.self)
        check(!(try call(demo, "state", [:], as: LedgerState.self).pendingPrompts.contains { $0.id == plan.id }), "released to the terminal")
        check(failure(demo, "prompt_answer", ["id": .number(Double(plan.id)), "answer": ["decision": "allow"]])?.code == "CONFLICT", "answering a released prompt")
        _ = try call(demo, "human", ["action": "review", "sessionId": .string(auto.sessionId!), "promptId": .number(Double(auto.id))], as: LedgerWriteResult.self)
        check(try call(demo, "state", [:], as: LedgerState.self).attention.autoReview == 0, "reviewed")
        rev = try call(demo, "rev", as: LedgerRev.self).rev
        clock.advance(46_000)
        let after = try call(demo, "state", [:], as: LedgerState.self)
        let expired = after.pendingPrompts.first { $0.id == ask.id }
        check(after.rev > rev && expired?.state == .auto && expired?.answeredBy == .auto, "the deadline ran out: auto-continue answered")
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
        await ledger.undo()
        check(ledger.session(stale.id)?.verdict == .stale && ledger.session(stale.id)?.snoozeUntil == nil, "undo Still active")

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
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Core/LedgerModels.swift" "$ROOT/Sources/Services/LedgerBackend.swift" "$ROOT/Sources/Services/LedgerDemoBackend.swift" \
    "$ROOT/Sources/Store/LedgerStore.swift" "$ROOT/Sources/Views/Ledger/LedgerPresentation.swift" "$ROOT/Sources/Views/Ledger/LedgerGraphLayout.swift" \
    "$TASK_TMP/main.swift" -o "$TASK_TMP/test-ledger"
"$TASK_TMP/test-ledger"
