import SwiftUI

/// The linked request's "#142" chip with its state and checks as status pills (docs/design.md, Badges) once they have
/// been read; until then, and outside the open repository, the chip alone, as before.
/// (Windows: widgets/ledger-workspace/ui/RequestStatus.tsx RequestChip)
struct LedgerRequestChip: View {
    let pr: LedgerSession.PullRequest
    let status: LedgerRequestStatus?

    var body: some View {
        HStack(spacing: 4) {
            LedgerLinkChip(symbol: "arrow.triangle.pull", text: "#\(pr.number)", url: URL(string: pr.url))
            if let status {
                let look = Self.look(status.state)
                StatusPill(title: look.title, symbol: look.symbol, tone: look.tone)
                    .help(Text(verbatim: "#\(pr.number) · \(look.title)"))
                if let checks = status.checks {
                    let look = Self.look(checks)
                    StatusPill(title: look.title, symbol: look.symbol, tone: look.tone)
                        .help("Checks on the request's latest commit")
                }
            }
        }
        .fixedSize()
    }

    /// Open is the passed tone, a draft waits, merged and closed are neutral (docs/design.md, Badges)
    static func look(_ state: LedgerRequestState) -> (title: String, symbol: String, tone: StudioStyle.Tone) {
        switch state {
        case .open: return (WorkState.title("open"), "arrow.triangle.pull", .passed)
        case .draft: return (String(localized: "Draft"), "pencil.circle", .waiting)
        case .merged: return (WorkState.title("merged"), "arrow.triangle.merge", .neutral)
        case .closed: return (WorkState.title("closed"), "xmark.circle", .neutral)
        }
    }

    static func look(_ checks: LedgerRequestChecks) -> (title: String, symbol: String, tone: StudioStyle.Tone) {
        switch checks.state {
        case .passing: return (String(localized: "\(checks.count) passing"), "checkmark.circle.fill", .passed)
        case .failing: return (String(localized: "\(checks.count) failing"), "xmark.circle.fill", .failed)
        case .pending: return (String(localized: "\(checks.count) pending"), "clock", .waiting)
        }
    }
}

/// "Request merged — mark merged?" as a strip (white, 1px border, 14px icon): `choose` opens the existing Mark
/// merged… picker. It only suggests; the Ledger changes when a person picks a version.
/// (Windows: widgets/ledger-workspace/ui/RequestStatus.tsx RequestMergedSuggestion)
struct LedgerRequestMergedSuggestion<Picker: View>: View {
    @ViewBuilder let picker: () -> Picker

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 14)).foregroundStyle(.secondary).accessibilityHidden(true)
            picker()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
        .help("The request was merged on the server. Choose the version this work went into; the Ledger changes only when you do.")
        .accessibilityElement(children: .contain)
    }
}
