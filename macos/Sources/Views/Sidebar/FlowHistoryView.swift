import SwiftUI

/// The History tab: the selected flow's runs, newest first, one line each (how it ended, how long it took, when).
/// A row opens the run. (Windows: FlowHistory.tsx)
struct FlowHistoryView: View {
    /// The selected flow's runs only
    let runs: [FlowRunRow]
    let onOpen: (String) -> Void
    @ViewState private var search = ""
    @ViewState private var failuresOnly = false

    var body: some View {
        if runs.isEmpty {
            HostedListEmpty(symbol: "clock.arrow.circlepath", title: String(localized: "No runs yet"),
                            caption: String(localized: "Run a flow to see its steps, output and results here."))
        } else {
            let shown = FlowWorkspaceSummary.historyRuns(runs, search: search, failuresOnly: failuresOnly, title: FlowFormat.stateTitle)
            VStack(spacing: 0) {
                filters
                if shown.isEmpty {
                    HostedListEmpty(symbol: "magnifyingglass", title: String(localized: "No matching runs"),
                                    actionTitle: String(localized: "Clear filters")) { search = ""; failuresOnly = false }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { run in FlowHistoryRow(run: run) { onOpen(run.runId) } }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            FlowSearchField(prompt: "Filter runs", text: $search)
            Toggle("Failures only", isOn: $failuresOnly).toggleStyle(.button).controlSize(.large)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
    }
}

/// One run: its state icon, its id, how it ended in words, how long it took and when it started
private struct FlowHistoryRow: View {
    let run: FlowRunRow
    let open: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        let state = FlowRunHistory.presentationState(run)
        let failed = FlowWorkspaceSummary.tone(state) == .failed
        Button(action: open) {
            HStack(spacing: 10) {
                FlowStateIcon(state: state, size: 14, spins: true)
                Text(verbatim: run.runId).font(.system(size: 11, design: .monospaced)).foregroundStyle(HostedList.caption)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 190, alignment: .leading)
                HStack(spacing: 6) {
                    Text(verbatim: FlowFormat.stateTitle(state)).font(.system(size: 13))
                        .foregroundStyle(failed ? StudioStyle.Tone.failed.text : Color.primary).lineLimit(1)
                    if run.signed == false, run.running != true {
                        SymbolIcon("exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.waiting.text)
                            .help("This record isn't signed by the engine, so gates don't trust it")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: run.durationMs.map(FlowFormat.duration) ?? "").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HostedList.caption).frame(width: 60, alignment: .trailing)
                Text(verbatim: ListDate.parse(run.startedAt).map { ListDate.when($0) } ?? "").font(.system(size: 12))
                    .foregroundStyle(HostedList.caption).lineLimit(1).frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(hovered ? StudioStyle.hover : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioStyle.border).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show run details")
        .accessibilityElement(children: .combine)
    }
}
