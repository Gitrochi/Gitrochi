import SwiftUI

/// 커밋할 스테이지에 한정한 분석. 테스트 후보를 실행 결과나 안전 보증으로 보이지 않게 분리한다.
struct CommitImpactView: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var showChanged = false
    @ViewState private var showDirect = true
    @ViewState private var showIndirect = false
    @ViewState private var showTests = true

    var body: some View {
        Card(spacing: 8) {
            HStack(spacing: 8) {
                Label("Review staged changes", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Button {
                    Task { await store.analyzeCommitImpact() }
                } label: {
                    if store.commitImpactState.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(analyzeTitle)
                    }
                }
                .controlSize(.small)
                .disabled(unavailable || store.commitImpactState.isRunning)
                .help("Analyze the files staged for this commit and suggest related tests.")
                .accessibilityLabel(Text("Analyze staged changes"))
            }
            Text("Staged changes compared with HEAD. Unstaged edits are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = Gitch.graphUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if !store.status.conflicted.isEmpty {
                Text("Resolve conflicts before analyzing staged changes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if store.status.staged.isEmpty {
                Text("Stage files to review their impact and related tests.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                content
                Button("Connect verification evidence…") { store.sheet = .workValidation }.controlSize(.small)
            }
        }
    }

    private var unavailable: Bool {
        Gitch.graphUnavailableReason != nil || store.status.staged.isEmpty || !store.status.conflicted.isEmpty
    }

    private var analyzeTitle: String {
        switch store.commitImpactState {
        case .idle: return String(localized: "Analyze")
        default: return String(localized: "Analyze again")
        }
    }

    @ViewBuilder private var content: some View {
        switch store.commitImpactState {
        case .idle:
            Text("Run an analysis to find files that depend on these changes.")
                .font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Analyzing staged changes…").font(.caption)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label("Couldn't analyze staged changes", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium)).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        case .ready(let report, let stale):
            reportContent(report, stale: stale)
        }
    }

    @ViewBuilder private func reportContent(_ report: CommitReviewReport, stale: Bool) -> some View {
        if stale {
            Label("Staged changes have changed. Analyze again to refresh this result.", systemImage: "arrow.clockwise.circle")
                .font(.caption).foregroundStyle(.orange)
        }
        if let error = store.commitImpactValidationError {
            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if report.changed.isEmpty {
            Text("No staged changes were found in this snapshot.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("\(report.coverage.analyzed) of \(report.coverage.changed) changed files analyzed")
                .font(.caption).foregroundStyle(.secondary)
            if report.coverage.unsupported > 0 {
                Text("\(report.coverage.unsupported) changed files could not be analyzed. The impact list may be incomplete.")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup(isExpanded: $showChanged) {
                ForEach(report.changed) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        path(file.path)
                        if let old = file.oldPath { Text("Renamed from \(old)").font(.caption2).foregroundStyle(.secondary) }
                        if !file.analyzed { Text("Not analyzed").font(.caption2).foregroundStyle(.orange) }
                    }
                    .padding(.vertical, 2)
                }
            } label: { Text("Changed files (\(report.changed.count))").font(.caption.weight(.medium)) }
            affectedFiles(report.direct, title: String(localized: "Direct impact (\(report.direct.count))"), expanded: $showDirect)
            affectedFiles(report.indirect, title: String(localized: "Indirect impact (\(report.indirect.count))"), expanded: $showIndirect)
            DisclosureGroup(isExpanded: $showTests) {
                if report.tests.isEmpty {
                    Text("No related test candidates found. Other tests may still be needed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(report.tests) { test in
                        VStack(alignment: .leading, spacing: 2) {
                            path(test.path)
                            HStack(spacing: 6) {
                                if test.kind == .name { Text("Name match") } else { Text("Dependency path") }
                                if test.heuristic && test.kind != .name { Text("Estimated") }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } label: { Text("Related test candidates (\(report.tests.count))").font(.caption.weight(.medium)) }
            Text("Candidates only. Tests have not been run.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if !report.limitations.isEmpty {
            DisclosureGroup {
                ForEach(Array(report.limitations.enumerated()), id: \.offset) { _, limitation in
                    Text(String(localized: String.LocalizationValue(limitation)))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } label: { Text("Analysis limits").font(.caption) }
        }
        HStack {
            Spacer()
            Button("Open staged graph") { Task { await store.openCommitImpactGraph() } }
                .controlSize(.small)
                .disabled(stale || store.graphJob != nil)
                .help("Open a dependency graph for the current staged changes in your browser.")
        }
    }

    private func affectedFiles(_ files: [CommitReviewReport.AffectedFile], title: String, expanded: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            if files.isEmpty {
                Text("No dependent files found in the analyzed dependencies.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        path(file.path)
                        if !file.via.isEmpty {
                            Text(file.via.joined(separator: " → "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(file.via.joined(separator: " → "))
                        }
                        if file.heuristic { Text("Estimated dependency").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            }
        } label: { Text(title).font(.caption.weight(.medium)) }
    }

    private func path(_ value: String) -> some View {
        Text(value).font(.system(.caption, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
