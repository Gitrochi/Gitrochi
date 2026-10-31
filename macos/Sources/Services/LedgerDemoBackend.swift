import Foundation

/// Ledger data in memory, in the contract's shapes, so the screens work before the core is linked: two projects, a
/// session in every verdict, an implementation stream with cycles, questions, prompts whose deadlines run out
/// (auto-continue answers them and a new one arrives a little later), overlaps and the graph. A person's operations
/// change it and bump `rev`. `.large` makes 1,000 sessions and 50,000 events; `.empty` starts with nothing.
/// Verdicts, attention counts and the graph are computed here the way the core does it, so the app never computes them.
/// (Windows: entities/ledger/api/demo-backend.ts)
final class DemoLedgerBackend: LedgerBackend, @unchecked Sendable {
    enum Mode: String, Sendable { case standard, large, empty }

    static let hour: LedgerMs = 3_600_000
    static let day: LedgerMs = 86_400_000
    static let staleMs: LedgerMs = 72 * hour
    static let systemClock: @Sendable () -> LedgerMs = { LedgerMs((Date().timeIntervalSince1970 * 1000).rounded()) }

    private let lock = NSLock()
    private let clock: @Sendable () -> LedgerMs
    private var rev = 1
    private var projects: [LedgerProject] = []
    private var baselines: [LedgerBaseline] = []
    private var sessions: [String: LedgerSession] = [:]
    /// Session IDs in creation order
    private var order: [String] = []
    private var events: [String: [LedgerEvent]] = [:]
    private var questions: [LedgerQuestion] = []
    private var prompts: [LedgerPendingPrompt] = []
    /// Auto-continued prompts a person has looked at
    private var reviewed: Set<Int> = []
    private var coupled: [LedgerOverlap] = []
    private var importHashes: Set<String> = []
    private var nextEventID = 1, nextQuestionID = 1, nextPromptID = 1
    private var nextPromptAt: LedgerMs?
    private var promptCycle = 0
    private var colorCounters: [String: Int] = [:]
    private var idCounters: [String: Int] = [:]
    /// Settings and baseline sources are stored and answered as the core does; the demo's verdicts keep 72 hours
    private var settings = DemoLedgerBackend.defaultSettings
    private var projectSettings: [String: LedgerProjectSettings] = [:]
    private let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMdd"
        return f
    }()

    init(mode: Mode = .standard, clock: @escaping @Sendable () -> LedgerMs = DemoLedgerBackend.systemClock) {
        self.clock = clock
        let now = clock()
        switch mode {
        case .standard: seedStandard(now)
        case .large: seedLarge(now)
        case .empty: projects = [LedgerProject(key: "harbor", name: "Harbor", open: 0)]
        }
    }

    func call(method: String, args: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        advance(now)
        let a = (try? JSONDecoder().decode(LedgerJSON.self, from: args)) ?? .object([:])
        do {
            switch method {
            case "info": return try encode(LedgerInfo(schemaVersion: 1, dbPath: "demo (in memory)", rev: rev, enabled: true))
            case "rev": return try encode(LedgerRev(rev: rev))
            case "state": return try encode(state(project: a["project"].string, range: range(a), now: now))
            case "session": return try encode(detail(try existing(a["id"]), now: now))
            case "graph": return try encode(graph(project: a["project"].string ?? projects.first?.key ?? "", range: range(a), now: now))
            case "search":
                return try encode(LedgerSearchResult(hits: search(a["query"].string ?? "", project: a["project"].string, limit: a["limit"].int ?? 30)))
            case "import": return try encode(LedgerImportResult(results: importText(a["text"].string ?? "", project: a["project"].string, now: now)))
            case "human": return try encode(human(a, now: now))
            case "prompt_answer": return try encode(answerPrompt(a, now: now))
            case "prompt_review": return try encode(reviewPrompts(a))
            case "backup": return try encode(LedgerBackupResult(path: "ledger-demo-" + dayFormat.string(from: date(now)) + ".sqlite3"))
            case "settings": return try encode(settings)
            case "settings_set": return try encode(setSettings(a))
            case "projects": return try encode(LedgerProjectList(projects: projects.map { project($0.key) }))
            case "project_set": return try encode(setProject(a))
            case "scan":
                let keys = a["project"].string.map { [$0] } ?? projects.map(\.key)
                return try encode(LedgerScanResult(results: keys.map { key in
                    LedgerScanResult.Project(project: key, source: project(key).baselineSource.rawValue, found: baselines.filter { $0.project == key }.count, added: 0)
                }))
            case "import_legacy": throw LedgerFailure(code: "INVALID_ARGUMENT", message: "The demo cannot import a database")
            default: throw LedgerFailure(code: "INVALID_ARGUMENT", message: "Unknown method: \(method)")
            }
        } catch let failure as LedgerFailure {
            return (try? encode(LedgerErrorEnvelope(error: .init(code: failure.code, message: failure.message)))) ?? Data()
        } catch {
            return (try? encode(LedgerErrorEnvelope(error: .init(code: "INTERNAL", message: "\(error)")))) ?? Data()
        }
    }

    /// The core's verdict rule, first match wins (the demo's copy: the app itself never computes verdicts)
    static func verdict(_ s: LedgerSession, now: LedgerMs) -> LedgerVerdict {
        if s.archivedAt != nil { return .archived }
        if s.openQuestions > 0 { return .needsHuman }
        if s.status.isFinished { return s.ackAt != nil ? .expirable : .confirm }
        if s.status == .shelved { return .shelved }
        if s.status == .done { return .pendingMerge }
        // a snooze runs while now is before snoozeUntil
        if now > s.lastAt + staleMs, now >= s.snoozeUntil ?? .min { return .stale }
        return .active
    }

    /// Versions compare as numbers: v1.10.0 is newer than v1.9.2
    static func versionKey(_ version: String) -> [Int] {
        version.split { !$0.isNumber }.compactMap { Int($0) }
    }

    // MARK: - Reads

    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private func date(_ ms: LedgerMs) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    private func range(_ a: LedgerJSON) -> LedgerRange { a["range"].string.flatMap(LedgerRange.init(rawValue:)) ?? .week }

    private func existing(_ value: LedgerJSON) throws -> String {
        guard let id = value.string, sessions[id] != nil else {
            throw LedgerFailure(code: "NOT_FOUND", message: "No session \(value.string ?? "")")
        }
        return id
    }

    private func openCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for q in questions where q.state == .open { counts[q.sessionId, default: 0] += 1 }
        return counts
    }

    private func decorate(_ session: LedgerSession, open: Int, now: LedgerMs) -> LedgerSession {
        var s = session
        s.openQuestions = open
        s.stream = s.role == .implementation && !s.status.isFinished ? .init(line: "Implementation") : nil
        s.verdict = Self.verdict(s, now: now)
        return s
    }

    private func head(of project: String) -> String? {
        baselines.filter { $0.project == project }.max { Self.versionKey($0.version).lexicographicallyPrecedes(Self.versionKey($1.version)) }?.version
    }

    private func state(project: String?, range: LedgerRange, now: LedgerMs) -> LedgerState {
        let from = range.start(now: now)
        let open = openCounts()
        var included: [LedgerSession] = []
        var hidden = 0
        for id in order {
            guard let raw = sessions[id], project == nil || raw.project == project else { continue }
            let s = decorate(raw, open: open[id] ?? 0, now: now)
            // only archived sessions older than the period are left out
            if s.verdict == .archived, s.lastAt < from { hidden += 1; continue }
            included.append(s)
        }
        let ids = Set(included.map(\.id))
        let shownQuestions = questions.filter { ids.contains($0.sessionId) && $0.state == .open }
        func inProject(_ p: LedgerPendingPrompt) -> Bool { project == nil || p.sessionId.flatMap { sessions[$0]?.project } == project }
        let waiting = prompts.filter { $0.state == .waiting && inProject($0) }
        let autoReview = prompts.filter { $0.state == .auto && !reviewed.contains($0.id) && inProject($0) }
        let byID = Dictionary(uniqueKeysWithValues: included.map { ($0.id, $0) })
        let openQuestions = shownQuestions.filter { $0.state == .open && byID[$0.sessionId]?.verdict != .archived }.count
        let flat = included.filter { $0.stream == nil }
        let tidy = flat.filter { $0.verdict == .confirm || $0.verdict == .expirable }.count
        let decide = flat.filter { $0.verdict == .pendingMerge || $0.verdict == .stale }.count
        let allLive = order.compactMap { sessions[$0] }.map { decorate($0, open: open[$0.id] ?? 0, now: now) }
        return LedgerState(
            schemaVersion: 1, rev: rev, now: now,
            projects: projects.map { p in
                LedgerProject(key: p.key, name: p.name, open: allLive.filter { $0.project == p.key && $0.stream == nil && ($0.status == .active || $0.status == .done) && $0.archivedAt == nil }.count)
            },
            baselines: baselines.filter { project == nil || $0.project == project }.sorted { $0.ts < $1.ts },
            sessions: included,
            questions: shownQuestions,
            streams: included.filter { $0.stream != nil }.flatMap { cycles(of: $0) },
            overlaps: overlaps(among: included),
            pendingPrompts: waiting,
            autoReview: autoReview,
            attention: LedgerAttention(questions: openQuestions, tidy: tidy, decide: decide, autoReview: autoReview.count,
                                       total: openQuestions + tidy + decide + autoReview.count),
            hiddenBefore: hidden)
    }

    private func detail(_ id: String, now: LedgerMs) -> LedgerSessionDetail {
        let s = decorate(sessions[id]!, open: openCounts()[id] ?? 0, now: now)
        return LedgerSessionDetail(session: s, events: events[id] ?? [], questions: questions.filter { $0.sessionId == id },
                                   overlaps: overlaps(among: liveSessions(now: now)).filter { $0.a == id || $0.b == id },
                                   cycles: s.stream != nil ? cycles(of: s) : [])
    }

    private func liveSessions(now: LedgerMs) -> [LedgerSession] {
        let open = openCounts()
        return order.compactMap { sessions[$0] }.map { decorate($0, open: open[$0.id] ?? 0, now: now) }
    }

    /// Cycles of a stream: a sync to vX starts the vX cycle, its own `applied` vX closes it; newest first
    private func cycles(of s: LedgerSession) -> [LedgerStreamCycle] {
        var list: [LedgerStreamCycle] = []
        for e in events[s.id] ?? [] where e.actor == .agent {
            if e.type == "sync", let v = e.version {
                list.append(LedgerStreamCycle(sessionId: s.id, line: s.stream?.line ?? "Implementation", version: v, state: .skipped,
                                              syncedAt: e.ts, appliedAt: nil,
                                              releasedBy: baselines.first { $0.project == s.project && $0.version == v }?.bySession, eventIds: [e.id]))
            } else if e.type == "applied", let v = e.version, let i = list.lastIndex(where: { $0.version == v }) {
                list[i].appliedAt = e.ts
                list[i].state = .applied
                list[i].eventIds.append(e.id)
            } else if !list.isEmpty {
                list[list.count - 1].eventIds.append(e.id)
            }
        }
        if let last = list.indices.last, list[last].state != .applied { list[last].state = .active }
        return list.reversed()
    }

    /// Live sessions outside streams that share a touch, plus the "usually change together" pairs
    private func overlaps(among list: [LedgerSession]) -> [LedgerOverlap] {
        let live = list.filter { $0.stream == nil && ($0.status == .active || $0.status == .done) && $0.archivedAt == nil }
        var byPath: [String: [String]] = [:]
        for s in live { for path in s.touches { byPath[s.project + "\u{1F}" + path, default: []].append(s.id) } }
        var pairs: [String: LedgerOverlap] = [:]
        for (key, ids) in byPath where ids.count > 1 {
            let path = String(key.split(separator: "\u{1F}", maxSplits: 1).last ?? "")
            for i in ids.indices { for j in ids.indices where j > i {
                let (a, b) = ids[i] < ids[j] ? (ids[i], ids[j]) : (ids[j], ids[i])
                pairs[a + "|" + b, default: LedgerOverlap(a: a, b: b, paths: [], kind: .same)].paths.append(path)
            } }
        }
        let liveIDs = Set(live.map(\.id))
        let sorted = pairs.values.map { var o = $0; o.paths.sort(); return o }.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
        return sorted + coupled.filter { liveIDs.contains($0.a) && liveIDs.contains($0.b) }
    }

    /// Lane 0 is the trunk of baselines; each session gets the lowest lane free since its first node in the period
    /// (an open session keeps its lane up to now). Joins and hand-offs point at baselines.
    private func graph(project: String, range: LedgerRange, now: LedgerMs) -> LedgerGraph {
        let from = range.start(now: now)
        var nodes: [LedgerGraphNode] = []
        var edges: [LedgerGraphEdge] = []
        let trunk = baselines.filter { $0.project == project }.sorted { ($0.ts, $0.version) < ($1.ts, $1.version) }
        // the newest baseline before the period stays at the bottom, so sessions forked from it start somewhere
        let anchor = trunk.last { $0.ts < from }
        var previous: String?
        for b in (anchor.map { [$0] } ?? []) + trunk.filter({ $0.ts >= from }) {
            let id = "b:" + b.version
            nodes.append(LedgerGraphNode(id: id, lane: 0, ts: b.ts, color: 0, kind: b.source == .release ? .release : .baseline,
                                         sessionId: b.bySession, version: b.version, label: b.version))
            if let previous { edges.append(LedgerGraphEdge(from: previous, to: id, kind: .trunk, color: 0)) }
            previous = id
        }
        let present = Set(nodes.map(\.id))
        struct Span { let id: String; let start: LedgerMs; let end: LedgerMs; let events: [LedgerEvent] }
        var spans: [Span] = []
        for id in order {
            guard let s = sessions[id], s.project == project else { continue }
            let list = (events[id] ?? []).filter { $0.ts >= from && $0.type != "heartbeat" && $0.actor != .human }
            guard let first = list.first, let last = list.last else { continue }
            let open = !s.status.isFinished && s.status != .shelved && s.archivedAt == nil
            spans.append(Span(id: id, start: first.ts, end: open ? now : last.ts, events: list))
        }
        spans.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        var laneEnds: [LedgerMs] = []
        var targets: [(edge: LedgerGraphEdge, required: String)] = []
        for span in spans {
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 < span.start }) {
                laneEnds[free] = span.end
                lane = free + 1
            } else {
                laneEnds.append(span.end)
                lane = laneEnds.count
            }
            let s = sessions[span.id]!
            var previousNode: String?
            for e in span.events {
                let id = "e:\(e.id)"
                nodes.append(LedgerGraphNode(id: id, lane: lane, ts: e.ts, color: s.color, kind: Self.nodeKind(e.type),
                                             sessionId: s.id, version: e.version, label: e.summary ?? e.type))
                if let previousNode {
                    edges.append(LedgerGraphEdge(from: previousNode, to: id, kind: .branch, color: s.color))
                } else if e.type != "start" || s.baseVersion != nil {
                    // a session that started before the period continues below the last row
                    edges.append(LedgerGraphEdge(from: "b:" + (s.baseVersion ?? ""), to: id, kind: .branch, color: s.color))
                }
                previousNode = id
                switch e.type {
                case "merged", "release":
                    if let v = e.version ?? s.mergedInto { targets.append((LedgerGraphEdge(from: id, to: "b:" + v, kind: .merge, color: s.color), "b:" + v)) }
                case "sync", "applied":
                    if let v = e.version { targets.append((LedgerGraphEdge(from: id, to: "b:" + v, kind: .handoff, color: s.color), "b:" + v)) }
                default: break
                }
            }
        }
        // joins only where the baseline is drawn; a join into an older, hidden version would point nowhere
        edges += targets.filter { present.contains($0.required) }.map(\.edge)
        return LedgerGraph(lanes: laneEnds.count + 1, nodes: nodes, edges: edges, from: max(from, nodes.map(\.ts).min() ?? now), to: now)
    }

    private static func nodeKind(_ type: String) -> LedgerGraphNode.Kind {
        switch type {
        case "start": return .start
        case "merged": return .merge
        case "release": return .release
        case "closed", "dropped": return .end
        default: return .event
        }
    }

    private func search(_ query: String, project: String?, limit: Int) -> [LedgerSearchHit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }
        func matches(_ text: String) -> Bool {
            let lower = text.lowercased()
            return words.allSatisfy { lower.contains($0) }
        }
        func inProject(_ sessionId: String) -> Bool { project == nil || sessions[sessionId]?.project == project }
        var hits: [LedgerSearchHit] = []
        for id in order.reversed() {
            guard let s = sessions[id], inProject(id), matches(s.id + " " + s.title + " " + s.kind) else { continue }
            hits.append(LedgerSearchHit(kind: .session, id: s.id, sessionId: s.id, title: s.title, snippet: s.id + " · " + s.kind))
            if hits.count >= limit { return hits }
        }
        for q in questions.reversed() where inProject(q.sessionId) && matches(q.text) {
            hits.append(LedgerSearchHit(kind: .question, id: "q\(q.id)", sessionId: q.sessionId, title: q.text, snippet: q.sessionId))
            if hits.count >= limit { return hits }
        }
        for b in baselines.reversed() where (project == nil || b.project == project) && matches(b.version + " " + (b.note ?? "")) {
            hits.append(LedgerSearchHit(kind: .baseline, id: "b:" + b.project + ":" + b.version, sessionId: b.bySession, title: b.version,
                                        snippet: (projects.first { $0.key == b.project }?.name ?? b.project) + " · " + b.source.rawValue))
            if hits.count >= limit { return hits }
        }
        for id in order.reversed() where inProject(id) {
            for e in (events[id] ?? []).reversed() {
                let text = (e.summary ?? "") + "\n" + (e.body ?? "")
                guard matches(text) else { continue }
                hits.append(LedgerSearchHit(kind: .event, id: "e\(e.id)", sessionId: id, title: e.summary ?? e.type,
                                            snippet: Self.excerpt(text, around: words[0])))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    private static func excerpt(_ text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: word, options: .caseInsensitive) else { return String(flat.prefix(90)) }
        let start = flat.index(r.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 50, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
    }

    // MARK: - Writes

    private func human(_ a: LedgerJSON, now: LedgerMs) throws -> LedgerWriteResult {
        let id = try existing(a["sessionId"])
        var s = sessions[id]!
        let action = a["action"].string ?? ""
        var summary: String?
        switch action {
        case "ack": s.ackAt = now
        case "unack": s.ackAt = nil
        case "archive": s.archivedAt = now
        case "unarchive": s.archivedAt = nil
        case "set_status":
            guard let status = a["status"].string.flatMap(LedgerStatus.init(rawValue:)) else {
                throw LedgerFailure(code: "INVALID_ARGUMENT", message: "set_status needs a status")
            }
            s.status = status
            summary = status.rawValue
            switch status {
            // a status a person chooses counts as confirmed
            case .merged:
                s.mergedInto = a["into"].string ?? head(of: s.project)
                s.baseCurrent = s.mergedInto ?? s.baseCurrent
                s.ackAt = now
                summary = "merged " + (s.mergedInto ?? "")
            case .closed, .dropped: s.ackAt = now
            case .active: s.ackAt = nil; s.archivedAt = nil; s.mergedInto = nil
            case .done, .shelved: break
            }
        case "answer", "dismiss":
            guard let qid = a["questionId"].int, let i = questions.firstIndex(where: { $0.id == qid && $0.sessionId == id }) else {
                throw LedgerFailure(code: "NOT_FOUND", message: "No such question")
            }
            guard questions[i].state == .open else { throw LedgerFailure(code: "CONFLICT", message: "The question was already answered.") }
            if action == "answer" {
                guard let text = a["answer"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw LedgerFailure(code: "INVALID_ARGUMENT", message: "An answer needs text")
                }
                questions[i].state = .answered
                questions[i].answer = text
                questions[i].answeredBy = .human
                summary = text
            } else {
                questions[i].state = .dismissed
            }
            questions[i].answeredAt = now
        case "snooze":
            // Still active sends no time: now plus the stale hours. Like the core, a snooze ends in the future.
            let until = a["until"].int ?? a["hours"].int.map { now + LedgerMs($0) * Self.hour } ?? now + Self.staleMs
            guard until > now else { throw LedgerFailure(code: "INVALID_ARGUMENT", message: "until must be in the future") }
            s.snoozeUntil = until
        case "shelve": s.status = .shelved
        case "link":
            // each link the request names is set; null removes it
            let fields = a.object ?? [:]
            if let v = fields["branch"] { s.links.branch = v.string }
            if let v = fields["worktree"] { s.links.worktree = v.string }
            if let v = fields["repoPath"] { s.links.repoPath = v.string }
            if let v = fields["agentId"] { s.links.agentId = v.string }
            if let v = fields["chatUrl"] { s.chatUrl = v.string }
        case "message":
            guard let text = a["text"].string, !text.isEmpty else { throw LedgerFailure(code: "INVALID_ARGUMENT", message: "A message needs text") }
            summary = text
        default:
            throw LedgerFailure(code: "INVALID_ARGUMENT", message: "Unknown action: \(action)")
        }
        sessions[id] = s
        var data = a.object ?? [:]
        data["sessionId"] = nil
        data["action"] = nil
        record(id, action, at: now, actor: .human, summary: summary, data: data.isEmpty ? nil : data)
        rev += 1
        return LedgerWriteResult(ok: true, rev: rev)
    }

    /// `prompt_review {id}` or `{all: true}`
    private func reviewPrompts(_ a: LedgerJSON) throws -> ReviewResult {
        let ids = a["all"].bool == true ? prompts.filter { $0.state == .auto }.map(\.id) : [a["id"].int].compactMap { $0 }
        guard !ids.isEmpty, ids.allSatisfy({ id in prompts.contains { $0.id == id && $0.state == .auto } }) else {
            throw LedgerFailure(code: "NOT_FOUND", message: "No auto-continued prompt to review")
        }
        let new = ids.filter { !reviewed.contains($0) }
        reviewed.formUnion(new)
        for id in new { if let i = prompts.firstIndex(where: { $0.id == id }) { prompts[i].reviewedAt = clock() } }
        if !new.isEmpty { rev += 1 }
        return ReviewResult(ok: true, rev: rev, reviewed: new.count)
    }

    private struct ReviewResult: Encodable { let ok: Bool; let rev: Int; let reviewed: Int }

    /// The core's defaults (crates/gitrochi-ledger/src/settings.rs)
    static let defaultSettings = LedgerGlobalSettings(
        staleHours: 72,
        kinds: ["research": .init(role: .research), "decision": .init(role: .decision),
                "implementation": .init(role: .implementation, line: "core", handoff: true),
                "llm-implementation": .init(role: .implementation, line: "llm", handoff: false),
                "review": .init(role: .other), "document": .init(role: .document), "baseline": .init(role: .other), "other": .init(role: .other)],
        autoContinue: ["enabled": false, "delaySec": 30],
        backupKeep: 14)
    static let defaultPattern = #"^v?(\d+(?:\.\d+)+)$"#

    private func project(_ key: String) -> LedgerProjectSettings {
        projectSettings[key] ?? LedgerProjectSettings(key: key, name: projects.first { $0.key == key }?.name ?? key, baselineSource: .tags,
                                                      baselinePattern: Self.defaultPattern, scanFiles: false, scanSubdirs: [])
    }

    /// `settings_set {values}`: null puts a setting back to its default; a value out of range is refused as a whole
    private func setSettings(_ a: LedgerJSON) throws -> LedgerSettingsWrite {
        guard let values = a["values"].object else { throw LedgerFailure(code: "INVALID_ARGUMENT", message: "Give values") }
        var next = settings
        for (key, value) in values {
            let reset = value == .null
            switch key {
            case "staleHours":
                guard reset || value.number.map({ $0 > 0 && $0 <= 10_000 }) == true else {
                    throw LedgerFailure(code: "INVALID_ARGUMENT", message: "staleHours must be a number of hours (0–10000)")
                }
                next.staleHours = value.number ?? Self.defaultSettings.staleHours
            case "kinds":
                if reset { next.kinds = Self.defaultSettings.kinds; continue }
                var kinds: [String: LedgerGlobalSettings.KindRule] = [:]
                for (name, entry) in value.object ?? [:] {
                    guard let role = entry["role"].string.flatMap(LedgerRole.init(rawValue:)), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw LedgerFailure(code: "INVALID_ARGUMENT", message: "kinds.\(name).role must be decision, implementation, research, document or other")
                    }
                    kinds[name.trimmingCharacters(in: .whitespaces)] = role == .implementation
                        ? .init(role: role, line: entry["line"].string ?? "core", handoff: entry["handoff"].bool ?? true) : .init(role: role)
                }
                next.kinds = kinds
            case "backupKeep":
                guard reset || value.int.map({ (1...365).contains($0) }) == true else {
                    throw LedgerFailure(code: "INVALID_ARGUMENT", message: "backupKeep must be a whole number (1–365)")
                }
                next.backupKeep = value.int ?? Self.defaultSettings.backupKeep
            case "autoContinue": next.autoContinue = reset ? Self.defaultSettings.autoContinue : value
            default: throw LedgerFailure(code: "INVALID_ARGUMENT", message: "Unknown setting \(key)")
            }
        }
        settings = next
        rev += 1
        return LedgerSettingsWrite(ok: true, rev: rev, settings: settings)
    }

    /// `project_set {project, …}`: the fields given change, null clears one
    private func setProject(_ a: LedgerJSON) throws -> LedgerProjectWrite {
        guard let key = a["project"].string, !key.isEmpty else { throw LedgerFailure(code: "INVALID_ARGUMENT", message: "Missing project") }
        if !projects.contains(where: { $0.key == key }) { projects.append(LedgerProject(key: key, name: key, open: 0)) }
        var p = project(key)
        let fields = a.object ?? [:]
        if let name = fields["name"] { p.name = name.string ?? key }
        if let repo = fields["repoPath"] { p.repoPath = repo.string }
        if let source = fields["baselineSource"] {
            guard let value = LedgerProjectSettings.Source(rawValue: source.string ?? "tags") else {
                throw LedgerFailure(code: "INVALID_ARGUMENT", message: "baselineSource must be tags, folder or manual")
            }
            p.baselineSource = value
        }
        if let pattern = fields["baselinePattern"] { p.baselinePattern = pattern.string ?? Self.defaultPattern }
        if let dir = fields["baselineDir"] { p.baselineDir = dir.string }
        if let files = fields["scanFiles"]?.bool { p.scanFiles = files }
        if let subdirs = fields["scanSubdirs"] { p.scanSubdirs = subdirs.array.compactMap(\.string) }
        projectSettings[key] = p
        if let i = projects.firstIndex(where: { $0.key == key }) { projects[i].name = p.name }
        rev += 1
        return LedgerProjectWrite(ok: true, rev: rev, project: p)
    }

    private func answerPrompt(_ a: LedgerJSON, now: LedgerMs) throws -> LedgerWriteResult {
        guard let id = a["id"].int, let i = prompts.firstIndex(where: { $0.id == id }) else {
            throw LedgerFailure(code: "NOT_FOUND", message: "No such prompt")
        }
        // a prompt that no longer waits is not an error: the answer just did not win
        guard prompts[i].state == .waiting else { return LedgerWriteResult(ok: false, rev: rev) }
        let answer = a["answer"].object ?? [:]
        if answer["hold"]?.bool == true {
            prompts[i].deadline = 0
        } else if answer["release"]?.bool == true {
            prompts[i].state = .released
            prompts[i].answer = answer
        } else {
            prompts[i].state = .answered
            prompts[i].answeredBy = .human
            prompts[i].answeredAt = now
            prompts[i].answer = answer
            if let session = prompts[i].sessionId {
                record(session, "prompt_answer", at: now, actor: .human, summary: Self.describe(answer), data: ["promptId": .number(Double(id))])
            }
        }
        if nextPromptAt == nil { nextPromptAt = now + 30_000 }
        rev += 1
        return LedgerWriteResult(ok: true, rev: rev)
    }

    /// Runs out deadlines: auto-continue answers what nobody answered, and a new prompt arrives a little later
    private func advance(_ now: LedgerMs) {
        var changed = false
        for i in prompts.indices where prompts[i].state == .waiting && prompts[i].deadline > 0 && prompts[i].deadline <= now {
            let answer = Self.autoAnswer(prompts[i])
            prompts[i].state = .auto
            prompts[i].answeredBy = .auto
            prompts[i].answeredAt = prompts[i].deadline
            prompts[i].answer = answer
            if let session = prompts[i].sessionId {
                record(session, "auto_reply", at: prompts[i].deadline, actor: .auto, summary: Self.describe(answer),
                       data: ["promptId": .number(Double(prompts[i].id))])
            }
            if nextPromptAt == nil { nextPromptAt = now + 20_000 }
            changed = true
        }
        if let at = nextPromptAt, at <= now {
            nextPromptAt = nil
            let waiting = prompts.filter { $0.state == .waiting }.count
            let unreviewed = prompts.filter { $0.state == .auto && !reviewed.contains($0.id) }.count
            if waiting < 3, unreviewed < 4, addCyclePrompt(now) { changed = true }
        }
        if changed { rev += 1 }
    }

    /// The answer auto-continue sends: the recommended (else first) option, an allowed permission, "carry on"
    static func autoAnswer(_ p: LedgerPendingPrompt) -> [String: LedgerJSON] {
        switch p.kind {
        case .askUserQuestion:
            var answers: [String: LedgerJSON] = [:]
            for q in p.payload["questions"]?.array ?? [] {
                let options = q["options"].array.compactMap { $0["label"].string }
                let pick = options.first { $0.localizedCaseInsensitiveContains("recommended") } ?? options.first ?? ""
                answers[q["question"].string ?? ""] = .string(pick)
            }
            return ["answers": .object(answers)]
        case .permission, .exitPlanMode: return ["decision": "allow"]
        case .stopQuestion: return ["text": "Go ahead with what you recommended."]
        }
    }

    private static func describe(_ answer: [String: LedgerJSON]) -> String {
        if let text = answer["text"]?.string { return text }
        if let decision = answer["decision"]?.string { return decision == "allow" ? "Allowed" : "Denied" }
        if let answers = answer["answers"]?.object { return answers.values.compactMap(\.string).sorted().joined(separator: ", ") }
        return "Answered"
    }

    private func importText(_ text: String, project: String?, now: LedgerMs) -> [LedgerImportResult.Block] {
        let known: Set<String> = ["start", "progress", "artifact", "question", "decision", "sync", "done", "merged", "closed",
                                  "dropped", "shelved", "release", "applied", "note", "heartbeat"]
        var results: [LedgerImportResult.Block] = []
        for (index, raw) in Self.blocks(in: text).enumerated() {
            guard let json = try? JSONDecoder().decode(LedgerJSON.self, from: Data(raw.utf8)), let object = json.object else {
                results.append(.init(index: index, ok: false, duplicate: false, error: "Not a JSON object", sessionId: nil))
                continue
            }
            guard let event = object["event"]?.string, known.contains(event) else {
                results.append(.init(index: index, ok: false, duplicate: false, error: "Unknown or missing event", sessionId: nil))
                continue
            }
            if ["sync", "release", "applied"].contains(event), object["version"]?.string == nil {
                results.append(.init(index: index, ok: false, duplicate: false, error: "\(event) needs a version", sessionId: nil))
                continue
            }
            if event == "question", object["question"]?.string == nil {
                results.append(.init(index: index, ok: false, duplicate: false, error: "A question needs its text", sessionId: nil))
                continue
            }
            let hash = (try? JSONEncoder.sorted.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? raw
            if importHashes.contains(hash) {
                // as the core does: a duplicate is ok, and skipped
                results.append(.init(index: index, ok: true, duplicate: true, error: nil, sessionId: object["session"]?.string))
                continue
            }
            importHashes.insert(hash)
            let ts = now + LedgerMs(index)
            let id: String
            if let given = object["session"]?.string, sessions[given] != nil {
                id = given
            } else {
                let key = object["project"]?.string ?? project ?? projects.first?.key ?? "demo"
                if !projects.contains(where: { $0.key == key }) { projects.append(LedgerProject(key: key, name: key.capitalized, open: 0)) }
                id = add(object["session"]?.string, project: key, title: object["title"]?.string ?? object["summary"]?.string ?? "Imported session",
                         kind: object["kind"]?.string ?? "other", created: ts, base: object["base"]?.string ?? head(of: key))
            }
            record(id, event, at: ts, summary: object["summary"]?.string, body: object["body"]?.string, version: object["version"]?.string)
            if event == "question", let q = object["question"]?.string { addQuestion(id, q, at: ts) }
            if let status = LedgerStatus(rawValue: event) { sessions[id]?.status = status }
            results.append(.init(index: index, ok: true, duplicate: false, error: nil, sessionId: id))
        }
        if results.contains(where: { $0.ok && !$0.duplicate }) { rev += 1 }
        return results
    }

    /// Fenced ```ledger blocks; without fences the whole text as one JSON object, or each line that starts with { and names an event
    static func blocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current == nil, trimmed.hasPrefix("```"), trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces) == "ledger" {
                current = []
            } else if current != nil, trimmed == "```" {
                blocks.append(current!.joined(separator: "\n"))
                current = nil
            } else if current != nil {
                current!.append(line)
            }
        }
        if !blocks.isEmpty { return blocks }
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if whole.hasPrefix("{"), (try? JSONDecoder().decode(LedgerJSON.self, from: Data(whole.utf8)))?.object != nil { return [whole] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("{") && $0.contains("\"event\"") }
    }

    // MARK: - Building data

    private func newID(at ms: LedgerMs) -> String {
        let day = dayFormat.string(from: date(ms))
        let n = (idCounters[day] ?? 0) + 1
        idCounters[day] = n
        return "S\(day)-" + (n < 10 ? "0\(n)" : "\(n)")
    }

    @discardableResult
    private func add(_ given: String? = nil, project: String, title: String, kind: String, role: LedgerRole = .other,
                     created: LedgerMs, base: String?, configure: (inout LedgerSession) -> Void = { _ in }) -> String {
        let id = given ?? newID(at: created)
        let color = colorCounters[project] ?? 0
        colorCounters[project] = color + 1
        var s = LedgerSession(id: id, project: project, title: title, kind: kind, role: role, status: .active, verdict: .active,
                              baseVersion: base, baseCurrent: base, mergedInto: nil, touches: [], related: [], chatUrl: nil,
                              links: .init(), color: color % 8, createdAt: created, lastAt: created, lastAgentAt: nil, ackAt: nil,
                              snoozeUntil: nil, archivedAt: nil, openQuestions: 0, stream: nil, autoContinue: nil)
        configure(&s)
        sessions[id] = s
        order.append(id)
        return id
    }

    @discardableResult
    private func record(_ session: String, _ type: String, at ts: LedgerMs, actor: LedgerActor = .agent, summary: String? = nil,
                        body: String? = nil, version: String? = nil, artifacts: [LedgerEvent.Artifact]? = nil,
                        data: [String: LedgerJSON]? = nil) -> Int {
        let id = nextEventID
        nextEventID += 1
        events[session, default: []].append(LedgerEvent(id: id, sessionId: session, ts: ts, type: type, actor: actor, summary: summary,
                                                        body: body, version: version, artifacts: artifacts, data: data,
                                                        deliveredAt: actor == .human ? nil : ts))
        if actor != .human, var s = sessions[session] {
            s.lastAt = max(s.lastAt, ts)
            if actor == .agent { s.lastAgentAt = max(s.lastAgentAt ?? .min, ts) }
            sessions[session] = s
        }
        return id
    }

    private func addQuestion(_ session: String, _ text: String, at ts: LedgerMs, answer: String? = nil, answeredAt: LedgerMs? = nil) {
        questions.append(LedgerQuestion(id: nextQuestionID, sessionId: session, text: text, state: answer == nil ? .open : .answered,
                                        answer: answer, answeredBy: answer == nil ? nil : .human, createdAt: ts,
                                        answeredAt: answeredAt, deliveredAt: answeredAt))
        nextQuestionID += 1
    }

    @discardableResult
    private func addPrompt(_ kind: LedgerPendingPrompt.Kind, session: String, created: LedgerMs, deadline: LedgerMs,
                           payload: [String: LedgerJSON]) -> Int {
        let id = nextPromptID
        nextPromptID += 1
        prompts.append(LedgerPendingPrompt(id: id, sessionId: session, agentId: sessions[session]?.links.agentId, kind: kind,
                                           payload: payload, createdAt: created, deadline: deadline, state: .waiting,
                                           answer: nil, answeredBy: nil))
        return id
    }

    /// Prompts that keep arriving while the demo runs, so the countdown strip always has something to show
    private func addCyclePrompt(_ now: LedgerMs) -> Bool {
        let live = order.filter { sessions[$0]?.status == .active && sessions[$0]?.archivedAt == nil && sessions[$0]?.role != .implementation }
        guard !live.isEmpty else { return false }
        let session = live[promptCycle % live.count]
        let deadline = now + 45_000
        switch promptCycle % 3 {
        case 0:
            addPrompt(.stopQuestion, session: session, created: now, deadline: deadline, payload: [
                "question": "The tests pass. Should I open the pull request now, or wait for the review notes?",
                "autoReply": "Go ahead with what you recommended.",
            ])
        case 1:
            addPrompt(.askUserQuestion, session: session, created: now, deadline: deadline, payload: [
                "questions": [[
                    "question": "Which log level should the new messages use?", "header": "Logging", "multiSelect": false,
                    "options": [["label": "Info (Recommended)", "description": "Visible in normal runs"],
                                ["label": "Debug", "description": "Only with verbose logging"]],
                ]],
                "autoReply": "Info (Recommended)",
            ])
        default:
            addPrompt(.permission, session: session, created: now, deadline: deadline, payload: [
                "toolName": "Bash", "input": ["command": "git status --short"], "description": "Show the working tree status",
                "autoReply": "Allow",
            ])
        }
        promptCycle += 1
        return true
    }

    private func setStatus(_ session: String, _ status: LedgerStatus, into version: String? = nil, ackAt: LedgerMs? = nil,
                           archivedAt: LedgerMs? = nil) {
        sessions[session]?.status = status
        if let version { sessions[session]?.mergedInto = version; sessions[session]?.baseCurrent = version }
        if let ackAt { sessions[session]?.ackAt = ackAt }
        if let archivedAt { sessions[session]?.archivedAt = archivedAt }
    }

    private func seedStandard(_ now: LedgerMs) {
        let h = Self.hour, d = Self.day, m: LedgerMs = 60_000
        projects = [LedgerProject(key: "harbor", name: "Harbor", open: 0), LedgerProject(key: "meadow", name: "Meadow", open: 0)]
        baselines = [
            LedgerBaseline(project: "harbor", version: "v1.2.0", ts: now - 40 * d, source: .tag, note: nil, bySession: nil),
            LedgerBaseline(project: "harbor", version: "v1.3.0", ts: now - 21 * d, source: .tag, note: nil, bySession: nil),
            LedgerBaseline(project: "harbor", version: "v1.4.0", ts: now - 9 * d, source: .tag, note: nil, bySession: nil),
            LedgerBaseline(project: "harbor", version: "v1.4.1", ts: now - 4 * d, source: .tag, note: nil, bySession: nil),
            LedgerBaseline(project: "meadow", version: "v0.8.0", ts: now - 25 * d, source: .folder, note: nil, bySession: nil),
            LedgerBaseline(project: "meadow", version: "v0.9.0", ts: now - 6 * d, source: .registered, note: "Spring update", bySession: nil),
        ]
        let repo = "~/Projects/harbor"
        let pr = { (n: Int) in LedgerSession.PullRequest(host: "git.example.com", number: n, url: "https://git.example.com/demo/harbor/pull/\(n)") }

        let stream = add(project: "harbor", title: "Core implementation channel", kind: "implementation", role: .implementation,
                         created: now - 20 * d, base: "v1.3.0") { s in
            s.links = .init(repoPath: repo, branch: "main", agentId: "agent-2")
            s.autoContinue = .init(enabled: true, delaySec: 30)
        }
        let rename = add(project: "harbor", title: "Rename the settings keys", kind: "refactor", created: now - 10 * d, base: "v1.3.0") { s in
            s.links = .init(repoPath: repo, branch: "refactor/settings-keys")
        }
        let search = add(project: "harbor", title: "Compare search index options", kind: "research", role: .research,
                         created: now - 12 * d, base: "v1.3.0") { s in s.touches = ["src/search/index.swift"] }
        let guide = add(project: "harbor", title: "Write the export guide", kind: "document", role: .document, created: now - 8 * d,
                        base: "v1.3.0") { s in s.links = .init(repoPath: repo, branch: "docs/export-guide") }
        let decision = add(project: "harbor", title: "Choose the cache eviction policy", kind: "decision", role: .decision,
                           created: now - 6 * d, base: "v1.4.0") { s in
            s.touches = ["docs/cache-policy.md"]
            s.links = .init(repoPath: repo, agentId: "agent-4")
            s.chatUrl = "https://chat.example.com/c/cache-policy"
        }
        let flaky = add(project: "harbor", title: "Investigate the flaky upload test", kind: "fix", created: now - 6 * d - 3 * h,
                        base: "v1.4.0") { s in
            s.touches = ["tests/upload_test.swift"]
            s.links = .init(repoPath: repo, branch: "fix/flaky-upload")
        }
        let csv = add(project: "harbor", title: "Add CSV export", kind: "feature", created: now - 3 * d, base: "v1.4.1") { s in
            s.touches = ["src/export/csv.swift", "src/export/formats.swift"]
            s.links = .init(repoPath: repo, branch: "feature/csv-export", pr: pr(145))
        }
        let retry = add(project: "harbor", title: "Retry sign-in after a timeout", kind: "fix", created: now - 2 * d, base: "v1.4.0") { s in
            s.touches = ["src/auth/retry.swift", "src/auth/session.swift"]
            s.links = .init(repoPath: repo, branch: "fix/sign-in-retry", worktree: repo + "/.worktrees/sign-in-retry", pr: pr(142),
                            agentId: "agent-7", agentSessionId: "demo-session-7", cwd: repo + "/.worktrees/sign-in-retry")
            s.chatUrl = "https://chat.example.com/c/sign-in-retry"
            s.autoContinue = .init(enabled: true, delaySec: 60)
        }
        let drafts = add(project: "harbor", title: "Keep drafts offline", kind: "feature", created: now - 26 * h, base: "v1.4.1") { s in
            s.touches = ["src/drafts/store.swift", "src/auth/session.swift"]
            s.links = .init(repoPath: repo, branch: "feature/offline-drafts", worktree: repo + "/.worktrees/offline-drafts", agentId: "agent-9")
            s.autoContinue = .init(enabled: true, delaySec: 30)
        }
        let notes = add(project: "meadow", title: "Draft the release notes for 0.9", kind: "document", role: .document,
                        created: now - 5 * d, base: "v0.9.0")
        let outline = add(project: "meadow", title: "Outline the onboarding chapter", kind: "document", role: .document,
                          created: now - 2 * d, base: "v0.9.0") { s in
            s.touches = ["chapters/onboarding.md", "glossary.md"]
            s.chatUrl = "https://chat.example.com/c/onboarding"
        }
        let glossary = add(project: "meadow", title: "Review the glossary terms", kind: "review", created: now - 20 * h, base: "v0.9.0") { s in
            s.touches = ["glossary.md"]
            s.links = .init(agentId: "agent-12")
        }

        // In time order, as the agents reported
        record(stream, "start", at: now - 20 * d, summary: "Implementation channel for Harbor")
        record(search, "start", at: now - 12 * d, summary: "Compare two index layouts")
        record(rename, "start", at: now - 10 * d, summary: "Rename keys to the new scheme")
        record(search, "progress", at: now - 10 * d + 4 * h, summary: "Benchmarked both layouts on 50,000 documents")
        record(stream, "sync", at: now - 9 * d + h, summary: "Synced v1.4.0", version: "v1.4.0")
        record(guide, "start", at: now - 8 * d, summary: "Write the guide for CSV and JSON export")
        record(stream, "artifact", at: now - 8 * d + 3 * h, summary: "Schema migration for v1.4.0",
               artifacts: [.init(name: "migration-14.sql", ssot: "v1.4.0", ver: nil)])
        record(stream, "applied", at: now - 8 * d + 5 * h, summary: "Applied v1.4.0", version: "v1.4.0")
        record(guide, "artifact", at: now - 6 * d, summary: "Export guide draft", artifacts: [.init(name: "export-guide.md", ssot: "v1.3.0", ver: nil)])
        record(decision, "start", at: now - 6 * d, summary: "Compare LRU and size-based eviction")
        record(flaky, "start", at: now - 6 * d - 3 * h, summary: "Find out why the upload test fails")
        record(search, "shelved", at: now - 6 * d + 2 * h, summary: "Paused until the sync work lands")
        setStatus(search, .shelved)
        addQuestion(decision, "Is 200 MB a fair cache ceiling for the first release?", at: now - 5 * d,
                    answer: "Yes. 200 MB, and log a line when it is reached.", answeredAt: now - 5 * d + 3 * h)
        record(notes, "start", at: now - 5 * d, summary: "Collect the changes since 0.8")
        record(rename, "merged", at: now - 4 * d, summary: "Merged into v1.4.1", version: "v1.4.1")
        setStatus(rename, .merged, into: "v1.4.1", ackAt: now - 3 * d, archivedAt: now - 2 * d)
        record(decision, "decision", at: now - 4 * d, summary: "Use LRU with a 200 MB ceiling", body: Self.decisionBody)
        record(flaky, "progress", at: now - 4 * d - 2 * h, summary: "The test fails about one run in twenty")
        record(stream, "sync", at: now - 4 * d + 2 * h, summary: "Synced v1.4.1", version: "v1.4.1")
        record(guide, "closed", at: now - 3 * d, summary: "Published in the project wiki")
        setStatus(guide, .closed, ackAt: now - 2 * d)
        record(csv, "start", at: now - 3 * d, summary: "Export the visible table as CSV")
        record(retry, "start", at: now - 2 * d, summary: "Reproduce and fix the sign-in timeout")
        record(outline, "start", at: now - 2 * d, summary: "Outline the chapter for new members")
        record(retry, "progress", at: now - 40 * h, summary: "Reproduced the timeout against a slow server")
        record(retry, "sync", at: now - 36 * h, summary: "Moved to v1.4.1", version: "v1.4.1")
        sessions[retry]?.baseCurrent = "v1.4.1"
        baselines.append(LedgerBaseline(project: "harbor", version: "v1.4.2", ts: now - 30 * h, source: .release, note: "Cache policy",
                                        bySession: decision))
        record(decision, "release", at: now - 30 * h, summary: "Released v1.4.2", version: "v1.4.2")
        record(csv, "artifact", at: now - 30 * h, summary: "Exporter and its tests",
               artifacts: [.init(name: "csv.swift", ssot: "v1.4.1", ver: nil), .init(name: "csv_tests.swift", ssot: "v1.4.1", ver: nil)])
        record(stream, "sync", at: now - 28 * h, summary: "Synced v1.4.2", version: "v1.4.2")
        // the stream's sync hands the decision session over: merged, waiting for a person to confirm
        record(decision, "merged", at: now - 28 * h, summary: "Merged into v1.4.2 (synced by \(stream))", version: "v1.4.2",
               data: ["by": .string(stream), "via": "sync"])
        setStatus(decision, .merged, into: "v1.4.2")
        sessions[stream]?.baseCurrent = "v1.4.2"
        record(notes, "done", at: now - 26 * h, summary: "Notes ready for review")
        setStatus(notes, .done)
        record(drafts, "start", at: now - 26 * h, summary: "Save drafts locally when offline")
        record(retry, "artifact", at: now - 20 * h, summary: "Retry plan", body: Self.retryBody,
               artifacts: [.init(name: "retry-plan.md", ssot: "v1.4.1", ver: nil)])
        record(outline, "artifact", at: now - 20 * h, summary: "First outline", artifacts: [.init(name: "outline.md", ssot: "v0.9.0", ver: nil)])
        record(glossary, "start", at: now - 20 * h, summary: "Check every term against the style guide")
        record(stream, "artifact", at: now - 10 * h, summary: "Cycle report for v1.4.2", body: Self.cycleBody)
        record(outline, "question", at: now - 6 * h, summary: "Two questions about the audience")
        addQuestion(outline, "Which audience comes first: administrators or new members?", at: now - 6 * h)
        addQuestion(outline, "Keep the glossary inside the chapter, or link to it?", at: now - 6 * h + 1_000)
        record(csv, "done", at: now - 5 * h, summary: "Ready to merge")
        setStatus(csv, .done)
        record(drafts, "progress", at: now - 3 * h, summary: "The draft store saves to disk")
        record(retry, "question", at: now - 2 * h, summary: "Asked about the token refresh")
        addQuestion(retry, "Should the retry also cover the token refresh call?", at: now - 2 * h)
        record(glossary, "progress", at: now - 70 * m, summary: "Checked 120 of 180 terms")

        // answered by auto-continue an hour ago; a person has not looked at it yet
        let auto = addPrompt(.askUserQuestion, session: drafts, created: now - 56 * m, deadline: now - 55 * m, payload: [
            "questions": [[
                "question": "How long should offline drafts be kept?", "header": "Drafts", "multiSelect": false,
                "options": [["label": "7 days (Recommended)", "description": "Enough for a trip, small on disk"],
                            ["label": "30 days", "description": "Keeps more, uses more space"]],
            ]],
            "autoReply": "7 days (Recommended)",
        ])
        if let i = prompts.firstIndex(where: { $0.id == auto }) {
            prompts[i].state = .auto
            prompts[i].answeredBy = .auto
            prompts[i].answeredAt = now - 55 * m
            prompts[i].answer = Self.autoAnswer(prompts[i])
            record(drafts, "auto_reply", at: now - 55 * m, actor: .auto, summary: "7 days (Recommended)", data: ["promptId": .number(Double(auto))])
        }
        addPrompt(.askUserQuestion, session: retry, created: now - 15_000, deadline: now + 45_000, payload: [
            "questions": [[
                "question": "How many times should sign-in retry after a 503?", "header": "Retries", "multiSelect": false,
                "options": [["label": "3 times (Recommended)", "description": "Matches the other network calls"],
                            ["label": "5 times", "description": "Slower to fail, kinder to slow servers"],
                            ["label": "Until cancelled", "description": "Never gives up on its own"]],
            ]],
            "autoReply": "3 times (Recommended)",
        ])
        addPrompt(.permission, session: drafts, created: now - 20_000, deadline: now + 160_000, payload: [
            "toolName": "Bash", "input": ["command": "swift test --filter DraftStoreTests"],
            "description": "Run the draft store tests", "autoReply": "Allow",
        ])
        addPrompt(.exitPlanMode, session: glossary, created: now - 90_000, deadline: 0, payload: [
            "plan": .string(Self.planBody),
        ])
        coupled = [LedgerOverlap(a: csv, b: flaky, paths: ["src/export/formats.swift", "tests/upload_test.swift"], kind: .coupled)]
    }

    private func seedLarge(_ now: LedgerMs) {
        let h = Self.hour, d = Self.day
        var random = DemoRandom(state: 20_261_031)
        projects = [LedgerProject(key: "harbor", name: "Harbor", open: 0), LedgerProject(key: "meadow", name: "Meadow", open: 0)]
        for i in 0..<40 {
            baselines.append(LedgerBaseline(project: "harbor", version: "v2.\(i / 10).\(i % 10)", ts: now - 120 * d + LedgerMs(i) * 3 * d,
                                            source: .tag, note: nil, bySession: nil))
        }
        for i in 0..<20 {
            baselines.append(LedgerBaseline(project: "meadow", version: "v0.\(i + 1).0", ts: now - 118 * d + LedgerMs(i) * 6 * d,
                                            source: .registered, note: nil, bySession: nil))
        }
        let verbs = ["Add", "Fix", "Refine", "Investigate", "Document", "Speed up", "Remove", "Review"]
        let topics = ["sign-in retry", "CSV export", "draft sync", "search index", "settings keys", "upload queue", "cache policy",
                      "release notes", "glossary", "onboarding", "theme colors", "keyboard shortcuts"]
        let paths = (0..<40).map { "src/module\($0 / 8)/file\($0).swift" }
        let middle = ["progress", "artifact", "note", "progress", "decision", "progress"]
        for n in 0..<1_000 {
            let project = n % 10 < 7 ? "harbor" : "meadow"
            let created = now - 120 * d + LedgerMs(n) * (119 * d / 1_000) + LedgerMs(random.int(0..<Int(h)))
            let end = min(now - 10 * 60_000, created + LedgerMs(random.int(Int(2 * h)..<Int(6 * d))))
            let base = baselines.filter { $0.project == project && $0.ts <= created }.last?.version
            let recent = now - created < 14 * d
            let roll = random.int(0..<100)
            let status: LedgerStatus
            if n % 100 == 50 { status = .active }
            else if recent { status = roll < 50 ? .active : roll < 70 ? .done : roll < 85 ? .merged : roll < 95 ? .closed : .shelved }
            else { status = roll < 70 ? .merged : roll < 85 ? .closed : roll < 92 ? .dropped : .shelved }
            let role: LedgerRole = n % 100 == 50 ? .implementation : n % 7 == 0 ? .decision : n % 11 == 0 ? .research : .other
            let id = add(project: project, title: "\(verbs[n % verbs.count]) \(topics[(n / 3) % topics.count]) \(n + 1)",
                         kind: role == .implementation ? "implementation" : role == .decision ? "decision" : role == .research ? "research" : "feature",
                         role: role, created: created, base: base) { s in
                s.touches = (0..<(1 + n % 3)).map { paths[(n * 7 + $0 * 13) % paths.count] }
                s.links = .init(repoPath: "~/Projects/" + project, branch: "feature/item-\(n + 1)")
            }
            record(id, "start", at: created, summary: "Started \(topics[(n / 3) % topics.count])")
            let span = max(1, end - created)
            for k in 1...48 {
                let ts = created + span * LedgerMs(k) / 49
                let type = role == .implementation && k % 12 == 0 ? "sync" : middle[(n + k) % middle.count]
                let version = type == "sync" ? baselines.filter { $0.project == project && $0.ts <= ts }.last?.version : nil
                record(id, type == "sync" && version == nil ? "progress" : type, at: ts, summary: "Step \(k): \(type) for item \(n + 1)",
                       body: k % 16 == 0 ? "### Notes\n- Checked the edge cases\n- Updated `item-\(n + 1)`" : nil, version: version)
            }
            let last: String
            switch status {
            case .merged: last = "merged"
            case .closed: last = "closed"
            case .dropped: last = "dropped"
            case .done: last = "done"
            case .shelved: last = "shelved"
            case .active: last = "progress"
            }
            let into = baselines.filter { $0.project == project && $0.ts <= end }.last?.version
            record(id, last, at: end, summary: "Finished: \(last)", version: last == "merged" ? into : nil)
            if status.isFinished {
                setStatus(id, status, into: status == .merged ? into : nil,
                          ackAt: recent && roll % 2 == 0 ? nil : end + h, archivedAt: recent ? nil : end + 2 * h)
            } else if status != .active {
                setStatus(id, status)
            }
            if status == .active, recent, n % 13 == 0 { addQuestion(id, "Which option should item \(n + 1) take?", at: end) }
        }
        let live = order.filter { sessions[$0]?.status == .active && sessions[$0]?.role != .implementation }
        if let first = live.last {
            addPrompt(.permission, session: first, created: now - 10_000, deadline: now + 50_000, payload: [
                "toolName": "Bash", "input": ["command": "swift build"], "description": "Build the package", "autoReply": "Allow",
            ])
        }
    }

    private static let decisionBody = """
    ## Decision

    Use **LRU** eviction with a **200 MB** ceiling for the first release.

    | Option | Hit rate | Memory | Notes |
    |---|---|---|---|
    | LRU, 200 MB | 91% | bounded | simple, predictable |
    | Size-based | 88% | bounded | favours small items |
    | No limit | 94% | unbounded | rejected |

    ### Why
    - The hit rate is within three points of an unlimited cache.
    - The ceiling keeps older laptops responsive.
    - A log line when the ceiling is reached tells us whether to raise it.

    ### Follow-ups
    1. Expose the ceiling in Settings after the first release.
    2. Measure again with the offline drafts feature.
    3. Revisit size-based eviction if large attachments become common.

    ### Rejected
    An unbounded cache had the best hit rate but grew past 2 GB in a week of normal use, and a size-based policy
    evicted the items people reopen most.
    """

    private static let retryBody = """
    ### Retry plan
    - Retry a sign-in that times out, with exponential backoff (0.5 s, 1 s, 2 s).
    - Stop on 4xx answers; only timeouts and 503 are retried.
    - Show the retry in the status line so nobody thinks the app froze.
    """

    private static let cycleBody = """
    ## Cycle v1.4.2
    | Item | State |
    |---|---|
    | Cache eviction (LRU, 200 MB) | done |
    | Log line at the ceiling | done |
    | Settings toggle | next cycle |

    Tests: 412 passed, 0 failed.
    """

    private static let planBody = """
    ## Plan
    1. List every glossary term with its current definition.
    2. Mark terms that disagree with the style guide.
    3. Propose replacements in a table for review.
    4. Update `glossary.md` only after the review.
    """
}

private extension JSONEncoder {
    /// Canonical JSON for duplicate checks: keys in a fixed order
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

/// A small, fixed-seed generator so the large demo is the same on every run
private struct DemoRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}
