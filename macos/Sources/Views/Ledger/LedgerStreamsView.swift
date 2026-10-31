import SwiftUI

/// Implementation sessions that keep reporting instead of finishing. Each baseline is a cycle: synced, worked on,
/// applied. The session that released the version is shown with its verdict, because syncing and applying hand it over.
/// (Windows: widgets/ledger-workspace/ui/LedgerStreamsView.tsx)
struct LedgerStreamsView: View {
    let ledger: LedgerStore
    let open: (String) -> Void
    /// Each stream's record, for the reports inside its cycles
    @ViewState private var details: [String: LedgerSessionDetail] = [:]

    private var streams: [LedgerSession] {
        (ledger.state?.sessions ?? []).filter { $0.stream != nil }.sorted { $0.lastAt > $1.lastAt }
    }

    var body: some View {
        Group {
            if streams.isEmpty {
                WorkspaceEmptyState(title: "No streams", systemImage: "arrow.triangle.2.circlepath",
                                    description: "Implementation sessions that sync every baseline and report in cycles show up here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(streams) { stream in
                            LedgerStreamCard(stream: stream, cycles: (ledger.state?.streams ?? []).filter { $0.sessionId == stream.id },
                                             events: details[stream.id]?.events ?? [], ledger: ledger, open: open)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 860, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .task(id: streams.map(\.id).joined(separator: ",") + "#\(ledger.state?.rev ?? 0)") {
            for stream in streams {
                if let detail = try? await ledger.client.session(stream.id), details[stream.id] != detail { details[stream.id] = detail }
            }
        }
    }
}

private struct LedgerStreamCard: View {
    let stream: LedgerSession
    let cycles: [LedgerStreamCycle]
    let events: [LedgerEvent]
    let ledger: LedgerStore
    let open: (String) -> Void

    var body: some View {
        Card(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LedgerSessionLabel(id: stream.id, color: stream.color)
                Text(stream.title).font(.headline).lineLimit(1).truncationMode(.tail)
                LedgerVerdictBadge(verdict: stream.verdict)
                Spacer(minLength: 6)
                Button("Open") { open(stream.id) }.controlSize(.small)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(cycles.enumerated()), id: \.element.version) { index, cycle in
                if index > 0 { Divider() }
                LedgerCycleRow(cycle: cycle, events: events.filter { cycle.eventIds.contains($0.id) }, newest: index == 0, ledger: ledger, open: open)
            }
            if cycles.isEmpty { Text("No cycle yet: the stream has not synced a baseline.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var subtitle: String {
        var parts = [stream.stream?.line ?? stream.kind]
        if let current = stream.baseCurrent { parts.append(String(localized: "on \(current)")) }
        parts.append(String(localized: "last report \(LedgerTime.short(stream.lastAgentAt ?? stream.lastAt))"))
        return parts.joined(separator: " · ")
    }
}

private struct LedgerCycleRow: View {
    let cycle: LedgerStreamCycle
    let events: [LedgerEvent]
    let newest: Bool
    let ledger: LedgerStore
    let open: (String) -> Void
    @ViewState private var expanded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(cycle.version, systemImage: "tag").font(.callout.weight(.semibold))
                stateChip
                Text(times).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if let by = cycle.releasedBy {
                    let releaser = ledger.session(by)
                    Button { open(by) } label: {
                        HStack(spacing: 4) {
                            Text("released by").font(.caption).foregroundStyle(.secondary)
                            LedgerSessionLabel(id: by, color: releaser?.color ?? 0)
                            if let releaser { LedgerVerdictBadge(verdict: releaser.verdict) }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open the session that released this version")
                }
            }
            if let report = events.last(where: { $0.body != nil }), let body = report.body {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.summary ?? LedgerEventText.title(report.type)).font(.caption.weight(.semibold))
                    MarkdownView(body)
                        .frame(maxHeight: isExpanded ? nil : 140, alignment: .top)
                        .clipped()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            if !events.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: { expanded = $0 })) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(events.reversed()) { e in
                            HStack(spacing: 6) {
                                Text(LedgerEventText.title(e.type)).font(.caption.weight(.medium))
                                Text(e.summary ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(LedgerTime.short(e.ts)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Reports in this cycle: \(events.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The newest cycle starts open
    private var isExpanded: Bool { expanded ?? newest }

    private var stateChip: some View {
        let (title, color): (String, Color) = {
            switch cycle.state {
            case .applied: return (String(localized: "Applied"), Color(nsColor: .systemGreen))
            case .active: return (String(localized: "In progress"), .accentColor)
            case .skipped: return (String(localized: "Skipped"), Color(nsColor: .tertiaryLabelColor))
            }
        }()
        return Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var times: String {
        var parts: [String] = []
        if let synced = cycle.syncedAt { parts.append(String(localized: "synced \(LedgerTime.short(synced))")) }
        if let applied = cycle.appliedAt { parts.append(String(localized: "applied \(LedgerTime.short(applied))")) }
        return parts.joined(separator: " → ")
    }
}
