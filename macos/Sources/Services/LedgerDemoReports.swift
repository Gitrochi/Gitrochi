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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
