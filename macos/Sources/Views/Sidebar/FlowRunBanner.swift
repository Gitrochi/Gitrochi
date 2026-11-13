import SwiftUI

/// The one strip above the graph (docs/design.md: white, a hairline, status in the icon). It answers what a person
/// needs before touching anything: is it running, must the commands be reviewed, how did the latest run end, or
/// what will Run flow do. Which of the four applies is FlowWorkspaceSummary.banner's decision.
/// (Windows: FlowRunBanner.tsx)
struct FlowRunBanner: View {
    let banner: FlowWorkspaceSummary.Banner
    /// The flow was just created here: the review strip says so, because reviewing is the next step
    var created = false
    /// How many steps are done, for the progress line of a running flow
    let progress: (done: Int, total: Int)
    let onOpenRun: (String) -> Void
    let onReview: () -> Void

    var body: some View {
        switch banner {
        case .running(let runId, let step, _):
            NoticeBlock(symbol: "circle.dotted", tone: .waiting,
                        title: step.map { String(localized: "Running \($0)") } ?? String(localized: "Running"),
                        caption: progress.total > 0 ? String(localized: "\(progress.done) of \(progress.total) steps done") : nil,
                        actions: [openRun(runId)])
        case .review:
            NoticeBlock(symbol: "exclamationmark.shield", tone: .waiting,
                        title: created ? String(localized: "Flow created. Review its commands, then run it.") : String(localized: "Review required"),
                        caption: String(localized: "This flow file is new or changed. Review the commands before running it."),
                        actions: [NoticeAction(title: String(localized: "Review commands…"), run: onReview)])
        case .finished(let runId, let state, let tone, let failedStep, let skipped, let durationMs):
            NoticeBlock(symbol: FlowStateIcon.look(state).0, tone: tone.style,
                        title: finishedTitle(state: state, tone: tone, failedStep: failedStep),
                        caption: finishedCaption(durationMs: durationMs, skipped: skipped),
                        actions: [openRun(runId)])
        case .ready:
            NoticeBlock(symbol: "circle", tone: .neutral, title: String(localized: "Not run yet"),
                        caption: String(localized: "Run flow starts each step on this computer once the steps it needs have passed."))
        }
    }

    private func openRun(_ runId: String) -> NoticeAction {
        NoticeAction(title: String(localized: "Open run…")) { onOpenRun(runId) }
    }

    private func finishedTitle(state: String, tone: FlowWorkspaceSummary.Tone, failedStep: String?) -> String {
        if tone == .passed { return String(localized: "Latest run passed") }
        if let failedStep { return String(localized: "Latest run failed at \(failedStep)") }
        return String(localized: "Latest run: \(FlowFormat.stateTitle(state))")
    }

    /// "Took 2m 32s · Skipped: package", or nothing when the run recorded neither
    private func finishedCaption(durationMs: Int?, skipped: [String]) -> String? {
        let parts = [
            durationMs.map { String(localized: "Took \(FlowFormat.duration($0))") },
            skipped.isEmpty ? nil : String(localized: "Skipped: \(skipped.joined(separator: ", "))"),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
