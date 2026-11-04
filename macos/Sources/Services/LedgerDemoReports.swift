import Foundation

/// The demo's answers to the read-only report methods, worked out the way the core does it (crates/gitrochi-ledger:
/// release_notes.rs), so their sheets can be seen without a database. (Windows: entities/ledger/api/demo-reports.ts)
enum LedgerDemoReports {
    private static let groups: [(LedgerRole, String)] = [(.decision, "Decisions"), (.implementation, "Implementation"),
                                                          (.research, "Research"), (.document, "Documents"), (.other, "Other")]
    private static let summaryChars = 160

    /// The first line of a summary, spaces collapsed, cut to a readable length
    static func oneLine(_ text: String?) -> String? {
        guard let line = text?.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > summaryChars else { return collapsed }
        return String(collapsed.prefix(summaryChars - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func releaseNotes(project: String, version: String?, baselines: [LedgerBaseline], sessions: [LedgerSession],
                             events: [String: [LedgerEvent]]) throws -> LedgerReleaseNotes {
        let trunk = baselines.filter { $0.project == project }
            .sorted { DemoLedgerBackend.versionKey($0.version).lexicographicallyPrecedes(DemoLedgerBackend.versionKey($1.version)) }
        guard !trunk.isEmpty else { throw LedgerFailure(code: "NOT_FOUND", message: "No project \(project)") }
        // the demo's tags keep their "v": a version asked for with or without it is the same baseline
        let bare = { (text: String) in text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text }
        let asked = version.flatMap { ["latest", "head"].contains($0.lowercased()) ? nil : $0 }
        let index: Int
        if let asked {
            guard let found = trunk.firstIndex(where: { bare($0.version) == bare(asked) }) else {
                throw LedgerFailure(code: "NOT_FOUND", message: "No baseline \(asked) in \(project)")
            }
            index = found
        } else {
            index = trunk.count - 1
        }
        let found = trunk[index]
        let wanted = found.version
        var absorbed = Set<String>()
        for event in sessions.flatMap({ events[$0.id] ?? [] }) where event.type == "release" && event.version == wanted {
            let ids: [LedgerJSON] = event.data?["absorbs"]?.array ?? []
            absorbed.formUnion(ids.compactMap(\.string))
        }
        let rows: [LedgerSession] = sessions
            .filter { session in session.project == project && (session.mergedInto == wanted || absorbed.contains(session.id)) }
            .sorted { a, b in a.kind != b.kind ? a.kind < b.kind : a.createdAt < b.createdAt }
        var grouped: [LedgerReleaseNotes.Group] = groups.map { .init(role: $0.0, title: $0.1, sessions: []) }
        for session in rows {
            let own: [LedgerEvent] = (events[session.id] ?? [])
                .filter { $0.actor == .agent }
                .sorted { a, b in a.ts != b.ts ? a.ts < b.ts : a.id < b.id }
            var summary: String?
            for type in ["done", "decision", "merged"] where summary == nil {
                for event in own.reversed() where event.type == type && summary == nil {
                    if type == "merged", event.data?["by"] != nil { continue }
                    summary = oneLine(event.summary)
                }
            }
            var artifacts: [LedgerReleaseNotes.Artifact] = []
            for artifact in own.flatMap({ $0.artifacts ?? [] }) {
                let item = LedgerReleaseNotes.Artifact(name: artifact.name, ver: artifact.ver ?? artifact.ssot, path: nil)
                if let at = artifacts.firstIndex(where: { $0.name == artifact.name }) { artifacts[at] = item } else { artifacts.append(item) }
            }
            let entry = LedgerReleaseNotes.Entry(id: session.id, title: session.title, kind: session.kind,
                                                 how: absorbed.contains(session.id) ? "absorbed" : "merged", summary: summary, artifacts: artifacts)
            if let at = grouped.firstIndex(where: { $0.role == session.role }) { grouped[at].sessions.append(entry) }
        }
        grouped.removeAll { $0.sessions.isEmpty }
        let previous = index > 0 ? trunk[index - 1].version : nil
        let note = found.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var lines: [String] = ["# \(project) \(wanted)", ""]
        let day: String = Date(timeIntervalSince1970: Double(found.ts) / 1000).formatted(.iso8601.year().month().day())
        var released = "Released \(day)"
        if let by = found.bySession { released += " by \(by)" }
        if let previous { released += " · changes since \(previous)" }
        lines.append(released + ".")
        if let note {
            lines.append("")
            for line in note.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \(line)")
            }
        }
        if grouped.isEmpty { lines += ["", "No sessions were merged into \(wanted)."] }
        for group in grouped {
            lines += ["", "## \(group.title)", ""]
            for entry in group.sessions {
                let label: String = entry.kind == group.role.rawValue || entry.kind.isEmpty ? "`\(entry.id)`" : "`\(entry.id)` · \(entry.kind)"
                var line = "- **\(entry.title.isEmpty ? entry.id : entry.title)** (\(label))"
                if let summary = entry.summary { line += " — \(summary)" }
                lines.append(line)
                if !entry.artifacts.isEmpty {
                    let names: [String] = entry.artifacts.map { artifact in
                        artifact.ver.map { "`\(artifact.name)@\($0)`" } ?? "`\(artifact.name)`"
                    }
                    lines.append("  - Artifacts: " + names.joined(separator: ", "))
                }
            }
        }
        return LedgerReleaseNotes(project: project, version: wanted, previous: previous, releasedAt: found.ts, releasedBy: found.bySession,
                                  note: note, versions: trunk.map(\.version).reversed(), groups: grouped,
                                  markdown: lines.joined(separator: "\n") + "\n")
    }
}

extension LedgerDemoReports {
    /// Nearest-rank percentiles, as the core's insights.rs computes them
    static func spread(_ values: [LedgerMs]) -> LedgerInsights.Spread {
        let sorted = values.filter { $0 >= 0 }.sorted()
        guard let last = sorted.last else { return .init(count: 0) }
        func rank(_ p: Int) -> LedgerMs {
            let at = max(1, (p * sorted.count + 99) / 100)
            return sorted[min(sorted.count, at) - 1]
        }
        return .init(count: sorted.count, medianMs: rank(50), p90Ms: rank(90), maxMs: last)
    }

    /// The core's `insights` on the demo's records: counts and durations only. `sessions` carry their verdicts.
    static func insights(project: String?, range: LedgerRange, now: LedgerMs, sessions: [LedgerSession], questions: [LedgerQuestion],
                         prompts: [LedgerPendingPrompt], events: [String: [LedgerEvent]]) -> LedgerInsights {
        let from: LedgerMs? = range == .all ? nil : range.start(now: now)
        let projectOf = Dictionary(sessions.map { ($0.id, $0.project) }, uniquingKeysWith: { first, _ in first })
        func inProject(_ id: String?) -> Bool { project == nil || projectOf[id ?? ""] == project }
        func inRange(_ at: LedgerMs?) -> Bool { from.map { (at ?? 0) >= $0 } ?? true }

        let asked = questions.filter { inProject($0.sessionId) }
        var answered = 0, dismissed = 0
        var waits: [LedgerMs] = []
        for q in asked where q.state != .open && inRange(q.answeredAt) {
            guard let at = q.answeredAt else { continue }
            if q.state == .dismissed { dismissed += 1 } else { answered += 1 }
            waits.append(at - q.createdAt)
        }
        let archived = Set(sessions.filter { $0.archivedAt != nil }.map(\.id))
        let openAges = asked.filter { $0.state == .open && !archived.contains($0.sessionId) }.map { now - $0.createdAt }
        let questionStats = LedgerInsights.Questions(asked: asked.filter { inRange($0.createdAt) }.count, answered: answered,
                                                     dismissed: dismissed, resolvedByAgent: 0, wait: spread(waits), open: spread(openAges))

        var kinds: [String: LedgerInsights.AutoKind] = [:]
        for prompt in prompts where prompt.state == .auto && inProject(prompt.sessionId) && inRange(prompt.answeredAt ?? prompt.createdAt) {
            let key = prompt.kind.rawValue
            var kind = kinds[key] ?? .init(kind: key, total: 0, reviewed: 0, corrected: 0, unreviewed: 0)
            kind.total += 1
            if let reviewedAt = prompt.reviewedAt {
                kind.reviewed += 1
                let sent = prompt.answeredAt ?? prompt.createdAt
                let messages = (events[prompt.sessionId ?? ""] ?? []).filter { $0.type == "message" && $0.actor == .human }
                if messages.contains(where: { $0.ts >= sent && $0.ts <= reviewedAt }) { kind.corrected += 1 }
            } else {
                kind.unreviewed += 1
            }
            kinds[key] = kind
        }
        let byKind = kinds.values.sorted { $0.kind < $1.kind }
        let auto = LedgerInsights.AutoAnswers(total: byKind.reduce(0) { $0 + $1.total }, reviewed: byKind.reduce(0) { $0 + $1.reviewed },
                                              corrected: byKind.reduce(0) { $0 + $1.corrected },
                                              unreviewed: byKind.reduce(0) { $0 + $1.unreviewed }, byKind: byKind)

        var byVerdict = Dictionary(uniqueKeysWithValues: LedgerVerdict.allCases.map { ($0.rawValue, 0) })
        var byRole = Dictionary(uniqueKeysWithValues: LedgerRole.allCases.map { ($0.rawValue, 0) })
        var total = 0, stale = 0, staleUnreported = 0, unreported = 0
        for session in sessions where (project == nil || session.project == project) && (session.archivedAt == nil || inRange(session.archivedAt)) {
            total += 1
            byVerdict[session.verdict.rawValue, default: 0] += 1
            byRole[session.role.rawValue, default: 0] += 1
            if session.lastAgentAt == nil { unreported += 1 }
            if session.verdict == .stale {
                stale += 1
                if session.lastAgentAt == nil { staleUnreported += 1 }
            }
        }
        let sessionStats = LedgerInsights.Sessions(total: total, byVerdict: byVerdict, byRole: byRole, stale: stale,
                                                   staleUnreported: staleUnreported, unreported: unreported)

        let reports = sessions.filter { project == nil || $0.project == project }
            .flatMap { events[$0.id] ?? [] }
            .filter { $0.actor == .agent && $0.ts <= now }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1000))
        let count = range == .week ? 7 : range == .month ? 30 : 90
        var days: [LedgerInsights.Day] = []
        for back in stride(from: count - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let low = LedgerMs(start.timeIntervalSince1970 * 1000), high = LedgerMs(end.timeIntervalSince1970 * 1000)
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            days.append(.init(day: day, reports: reports.filter { $0.ts >= low && $0.ts < high }.count))
        }
        return LedgerInsights(project: project, range: range, from: from, to: now, questions: questionStats, autoAnswers: auto,
                              sessions: sessionStats, reports: reports.filter { inRange($0.ts) }.count, reportsPerDay: days)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
