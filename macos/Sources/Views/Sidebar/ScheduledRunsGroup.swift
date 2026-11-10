import SwiftUI

/// The repository's runs scheduled for later, above the run list: which workflow (or pipeline) runs on which branch
/// and when, with Cancel, or Run now and Remove once it was missed or failed. Nothing is drawn without any.
/// (Windows: features/ci-panel/ui/ScheduledRunsGroup.tsx)
struct ScheduledRunsGroup: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.locale) private var locale
    private var schedule: ScheduledRunStore { .shared }

    var body: some View {
        let runs = store.url.map { schedule.runs(for: $0.path) } ?? []
        if !runs.isEmpty {
            // the relative times move on while the page is open
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        SymbolIcon("clock").font(.system(size: 11)).accessibilityHidden(true)
                        Text("Scheduled").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(HostedList.caption)
                    .padding(.horizontal, 10).frame(height: 28)
                    ForEach(runs) { run in
                        Divider()
                        row(run, now: context.date)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Scheduled runs")
        }
    }

    private func title(_ run: ScheduledRun) -> String {
        run.workflowName ?? String(localized: "Pipeline")
    }

    private func row(_ run: ScheduledRun, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: title(run)).font(.system(size: 13, weight: .medium)).lineLimit(1).layoutPriority(1)
                // the branch gives way first, from the front
                Text(verbatim: run.ref).font(.system(size: 12)).foregroundStyle(HostedList.caption).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 6)
                // the commands are never cut
                HStack(spacing: 8) {
                    if schedule.starting.contains(run.id) {
                        ProgressView().controlSize(.mini)
                    } else if run.state == .scheduled {
                        Button("Cancel") { schedule.remove(run.id) }.buttonStyle(HostedListTextButtonStyle())
                    } else {
                        Button("Run now") { confirmRun(run) }.buttonStyle(HostedListTextButtonStyle())
                        Button("Remove") { schedule.remove(run.id) }.buttonStyle(HostedListTextButtonStyle(destructive: true))
                    }
                }
                .fixedSize()
                .layoutPriority(2)
            }
            HStack(spacing: 6) {
                switch run.state {
                case .scheduled: EmptyView()
                case .missed: HostedListChip(title: String(localized: "Missed"), symbol: "exclamationmark.circle", tone: .waiting)
                case .failed: HostedListChip(title: String(localized: "Failed"), symbol: "xmark.circle.fill", tone: .failed)
                }
                Text(verbatim: ScheduledRuns.time(run.runAt, now: now, locale: locale) + " · " + ScheduledRuns.relative(run.runAt, now: now, locale: locale))
                    .font(.system(size: 11)).foregroundStyle(HostedList.caption).lineLimit(1)
                Spacer(minLength: 0)
            }
            if run.state == .failed, let message = run.message {
                Text(verbatim: message).font(.system(size: 11)).foregroundStyle(StudioStyle.Tone.failed.text)
                    .lineLimit(2).textSelection(.enabled).help(message)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    /// Starting a run that did not start on time asks once: it may be a deployment, and its moment has passed
    private func confirmRun(_ run: ScheduledRun) {
        store.confirm = ConfirmRequest(title: String(localized: "Start this run now?"), message: "\(title(run)) · \(run.ref)",
                                       actionTitle: String(localized: "Run"), destructive: false) {
            schedule.runNow(run.id)
        }
    }
}
