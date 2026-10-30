import SwiftUI

/// Saved runs remain browsable independently of the command inspector.
struct FlowHistoryView: View {
    let runs: [FlowRunRow]
    let onOpen: (String) -> Void
    @ViewState private var search = ""
    @ViewState private var failuresOnly = false
    @ViewState private var selectedFlow = ""

    private static let failedStates: Set<String> = ["FAILED", "REJECTED", "INDETERMINATE", "ROLLBACK_FAILED", "ROLLED_BACK"]
    private var filtered: [FlowRunRow] {
        runs.filter {
            (selectedFlow.isEmpty || $0.flow == selectedFlow) &&
            (!failuresOnly || Self.failedStates.contains($0.state)) &&
            (search.isEmpty || ($0.flow + $0.runId + $0.state).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filtered.isEmpty {
                if runs.isEmpty {
                    ContentUnavailableView("No runs yet", systemImage: "clock.arrow.circlepath", description: Text("Run a flow to see its steps, output and results here."))
                } else {
                    ContentUnavailableView("No matching runs", systemImage: "magnifyingglass", description: Text("Try another search or filter."))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { run in row(run) }
                    }.padding(16)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Recent runs", systemImage: "clock.arrow.circlepath").font(.callout.weight(.semibold))
                Text("\(filtered.count)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Color.secondary.opacity(0.08), in: Capsule())
                Spacer(minLength: 8)
                metric("Passed", count: filtered.filter { ["PASSED", "SUCCEEDED", "CACHED"].contains($0.state) }.count, icon: "checkmark.circle", color: .green)
                metric("Failed", count: filtered.filter { Self.failedStates.contains($0.state) }.count, icon: "xmark.circle", color: .red)
            }
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search runs", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                .frame(minWidth: 90, maxWidth: .infinity)
                Picker("Flow", selection: $selectedFlow) {
                    Text("All flows").tag("")
                    ForEach(Array(Set(runs.map(\.flow))).sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 125)
                Toggle("Failures only", isOn: $failuresOnly).toggleStyle(.button).controlSize(.small).font(.system(size: 10))
            }
        }
        .padding(16)
    }

    private func metric(_ title: LocalizedStringKey, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(count)").monospacedDigit()
            Text(title).foregroundStyle(.secondary)
        }
        .font(.system(size: 10, weight: .medium))
    }

    private func row(_ run: FlowRunRow) -> some View {
        let state = FlowRunHistory.presentationState(run)
        let color = FlowStateIcon.look(state).1
        return Button { onOpen(run.runId) } label: {
            HStack(spacing: 12) {
                FlowStateIcon(state: state, size: 17)
                    .frame(width: 34, height: 34).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.flow).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(run.runId).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
                FlowStatusBadge(state: state)
                VStack(alignment: .trailing, spacing: 5) {
                    if let time = run.startedAt, let date = ISO8601DateFormatter.flow.date(from: time) {
                        Text(Fmt.short(date)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let duration = run.durationMs { Text(FlowFormat.duration(duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                }.frame(maxWidth: 145, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain).help("Show run details")
    }
}
