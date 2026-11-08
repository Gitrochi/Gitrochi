import SwiftUI

/// Insights…: how long questions wait, how automatic answers fare, where sessions stand and how often agents report,
/// over a period, from the core's `insights` (counts and durations only). Stat tiles and plain bars, no chart library.
/// (Windows: widgets/ledger-workspace/ui/LedgerInsights.tsx)
struct LedgerInsightsSheet: View {
    let ledger: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var range: LedgerRange = .month
    /// nil: every project
    @ViewState private var project: String?
    @ViewState private var insights: LedgerInsights?
    @ViewState private var error: String?
    @ViewState private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 640)
        .task {
            // the page's project and period to start with
            project = ledger.project
            range = ledger.range
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Insights").font(.title3.weight(.semibold))
            if loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            Picker("Project", selection: Binding(get: { project ?? "" }, set: { key in
                project = key.isEmpty ? nil : key
                Task { await load() }
            })) {
                Text("All projects").tag("")
                ForEach(ledger.state?.projects ?? []) { Text(verbatim: $0.name).tag($0.key) }
            }
            .fixedSize()
            Picker("Period", selection: Binding(get: { range }, set: { value in
                range = value
                Task { await load() }
            })) {
                ForEach(LedgerRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("The period the numbers cover")
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var content: some View {
        if let error {
            WorkspaceEmptyState(title: "The ledger cannot be read", systemImage: "exclamationmark.triangle", description: error,
                                actionTitle: "Try again", action: { Task { await load() } })
        } else if let insights {
            if insights.isEmpty {
                WorkspaceEmptyState(title: "Nothing to measure yet", systemImage: "chart.bar",
                                    description: "Insights appear once agents report in this period. Choose a longer period or another project.")
            } else {
                ScrollView { report(insights).padding(20) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func report(_ i: LedgerInsights) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            tiles(i)
            section("Agent reports per day") { reportsChart(i.reportsPerDay) }
            HStack(alignment: .top, spacing: 20) {
                verdictBars(i.sessions)
                roleBars(i.sessions)
            }
            section("Automatic answers by kind") {
                if i.autoAnswers.byKind.isEmpty {
                    Text("No automatic answers in this period.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(i.autoAnswers.byKind) { kind in autoRow(kind) }
                    HStack(spacing: 12) {
                        legend("Reviewed", .passed)
                        legend("Corrected", .waiting)
                        legend("Not reviewed", .neutral)
                    }
                    .padding(.top, 2)
                }
            }
            questionFacts(i.questions)
        }
    }

    private func tiles(_ i: LedgerInsights) -> some View {
        let q = i.questions
        let waitCaption: String = q.wait.count == 0 ? String(localized: "None settled")
            : String(localized: "Median · p90 \(LedgerInsightFormat.duration(q.wait.p90Ms))")
        let openCaption: String = q.open.count == 0 ? String(localized: "Nothing waiting")
            : String(localized: "Oldest \(LedgerInsightFormat.duration(q.open.maxMs))")
        let autoCaption = String(localized: "\(i.autoAnswers.reviewed) reviewed · \(i.autoAnswers.corrected) corrected")
        let staleCaption = String(localized: "\(i.sessions.staleUnreported) never reported")
        let reportsCaption = String(localized: "\(i.sessions.total) sessions")
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
            LedgerStatTile(title: "Question wait", value: LedgerInsightFormat.duration(q.wait.medianMs), caption: waitCaption, symbol: "hourglass")
            LedgerStatTile(title: "Open questions", value: "\(q.open.count)", caption: openCaption, symbol: "questionmark.bubble",
                           tone: q.open.count > 0 ? .waiting : nil)
            LedgerStatTile(title: "Automatic answers", value: "\(i.autoAnswers.total)", caption: autoCaption, symbol: "bolt.badge.clock")
            LedgerStatTile(title: "Stale sessions", value: "\(i.sessions.stale)", caption: staleCaption, symbol: "clock.badge.exclamationmark",
                           tone: i.sessions.stale > 0 ? .failed : nil)
            LedgerStatTile(title: "Agent reports", value: "\(i.reports)", caption: reportsCaption, symbol: "text.bubble")
        }
    }

    private func verdictBars(_ sessions: LedgerInsights.Sessions) -> some View {
        let max = sessions.byVerdict.values.max() ?? 0
        return section("Sessions by verdict") {
            ForEach(LedgerInsightFormat.verdicts, id: \.self) { verdict in
                LedgerInsightBar(label: verdict.title, symbol: verdict.symbol, value: sessions.byVerdict[verdict.rawValue] ?? 0,
                                 max: max, tone: verdict.tone)
            }
        }
    }

    private func roleBars(_ sessions: LedgerInsights.Sessions) -> some View {
        let max = sessions.byRole.values.max() ?? 0
        return section("Sessions by role") {
            ForEach(LedgerRole.allCases, id: \.self) { role in
                LedgerInsightBar(label: role.title, symbol: nil, value: sessions.byRole[role.rawValue] ?? 0, max: max, tone: .info)
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reportsChart(_ days: [LedgerInsights.Day]) -> some View {
        let max = days.map(\.reports).max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: days.count > 40 ? 1 : 3) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(day.reports == 0 ? StudioStyle.border : StudioStyle.Tone.info.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: LedgerInsightFormat.barLength(day.reports, of: max, in: 96))
                        .help(Text(verbatim: "\(day.day) · \(day.reports)"))
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: day.day))
                        .accessibilityValue(Text("\(day.reports) reports"))
                }
            }
            .frame(height: 96, alignment: .bottom)
            HStack {
                Text(verbatim: days.first?.day ?? "")
                Spacer()
                Text("Most in a day: \(max)")
                Spacer()
                Text(verbatim: days.last?.day ?? "")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).strokeBorder(StudioStyle.border))
    }

    private func autoRow(_ kind: LedgerInsights.AutoKind) -> some View {
        let title = LedgerPendingPrompt.Kind(rawValue: kind.kind)?.title ?? kind.kind
        let parts: [(Int, StudioStyle.Tone)] = [(kind.reviewed - kind.corrected, .passed), (kind.corrected, .waiting), (kind.unreviewed, .neutral)]
        return HStack(spacing: 10) {
            Text(verbatim: title).font(.system(size: 12)).frame(width: 150, alignment: .leading).lineLimit(1)
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        if part.0 > 0 {
                            Rectangle().fill(part.1.text.opacity(0.85))
                                .frame(width: LedgerInsightFormat.barLength(part.0, of: kind.total, in: proxy.size.width))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 10)
            Text(verbatim: "\(kind.total)").font(.system(size: 12).monospacedDigit()).frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: String(localized: "\(kind.reviewed) reviewed · \(kind.corrected) corrected") + " · "
                                 + String(localized: "\(kind.unreviewed) not reviewed")))
    }

    private func legend(_ title: LocalizedStringKey, _ tone: StudioStyle.Tone) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(tone.text.opacity(0.85)).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(title)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func questionFacts(_ q: LedgerInsights.Questions) -> some View {
        section("Questions in this period") {
            HStack(spacing: 18) {
                fact("Asked", q.asked)
                fact("Answered", q.answered)
                fact("Dismissed", q.dismissed)
                fact("Closed by their agent", q.resolvedByAgent)
            }
        }
    }

    private func fact(_ title: LocalizedStringKey, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(value)").font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            insights = try await ledger.client.insights(project: project, range: range)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One number with its title and a line of context, as the Insights sheet shows it
private struct LedgerStatTile: View {
    let title: LocalizedStringKey
    let value: String
    let caption: String
    let symbol: String
    var tone: StudioStyle.Tone?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                SymbolIcon(symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tone?.text ?? Color.secondary).accessibilityHidden(true)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(verbatim: value).font(.system(size: 22, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: StudioStyle.cornerRadius).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .combine)
    }
}

/// A labelled horizontal bar: its share of the largest value in the group
private struct LedgerInsightBar: View {
    let label: String
    let symbol: String?
    let value: Int
    let max: Int
    let tone: StudioStyle.Tone

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if let symbol { SymbolIcon(symbol).font(.system(size: 11)).foregroundStyle(tone.text).accessibilityHidden(true) }
                Text(verbatim: label).font(.system(size: 12)).lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(StudioStyle.border.opacity(0.6))
                    if value > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(tone.text.opacity(0.85))
                            .frame(width: LedgerInsightFormat.barLength(value, of: max, in: proxy.size.width))
                    }
                }
            }
            .frame(height: 10)
            Text(verbatim: "\(value)").font(.system(size: 12).monospacedDigit()).frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: "\(value)"))
    }
}
