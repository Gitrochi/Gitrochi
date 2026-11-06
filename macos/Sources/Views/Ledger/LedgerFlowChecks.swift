import SwiftUI

/// Checks: the latest result of each flow recorded for the session's branch head commit, read-only, as a section like
/// the inspector's others, with Open in Flows. The inspector shows it only when there is such a result.
/// (Windows: widgets/ledger-workspace/ui/FlowChecks.tsx)
struct LedgerFlowChecks: View {
    let branch: String
    let evidence: LedgerFlowEvidenceStore.Evidence
    let openFlows: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LedgerSectionHeader(title: String(localized: "Checks"), count: evidence.results.count)
            HStack(spacing: 6) {
                DesignIconImage(icon: .branch, size: 11).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(branch).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(String(evidence.head.prefix(8))).font(.system(size: 11).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer(minLength: 4)
                Button("Open in Flows", action: openFlows).buttonStyle(.link).font(.system(size: 11))
            }
            .help("Latest Flow runs recorded for this branch's head commit")
            ForEach(evidence.results) { result in
                let look = Self.look(result.outcome)
                HStack(spacing: 8) {
                    StatusPill(title: look.title, symbol: look.symbol, tone: look.tone).help(FlowFormat.stateTitle(result.run.state))
                    Text(result.run.flow).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail).help(result.run.runId)
                    Spacer(minLength: 4)
                    if let at = result.run.finishedAt {
                        Text(LedgerTime.short(at)).font(.system(size: 11)).foregroundStyle(.tertiary).help(LedgerTime.long(at))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Passed and failed in their tones; held waits for a person; a cancelled run is neutral (docs/design.md, Badges)
    static func look(_ outcome: LedgerFlowOutcome) -> (title: String, symbol: String, tone: StudioStyle.Tone) {
        switch outcome {
        case .passed: return (String(localized: "Passed"), "checkmark.circle.fill", .passed)
        case .failed: return (String(localized: "Failed"), "xmark.circle.fill", .failed)
        case .held: return (String(localized: "Held"), "pause.circle.fill", .waiting)
        case .canceled: return (String(localized: "Canceled"), "stop.circle", .neutral)
        }
    }
}
