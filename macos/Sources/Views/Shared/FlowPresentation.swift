import SwiftUI

/// What kind of work a step is: the card's and the step details' words for a step that gives none of its own, and the
/// module editor's icon and colour. (Windows: flowStepKindTitle in FlowState.tsx)
enum FlowBlockStyle {
    static func look(_ block: String) -> (icon: String, title: String, color: Color) {
        if block.hasPrefix("test") || block.hasPrefix("check") { return ("checkmark.seal", String(localized: "Tests"), .green) }
        if block.hasPrefix("ci.") { return ("arrow.triangle.branch", String(localized: "CI/CD"), .purple) }
        if block.hasPrefix("deploy") { return ("shippingbox", String(localized: "Deploy"), .orange) }
        if block.hasPrefix("gate") { return ("hand.raised", String(localized: "Approval"), .orange) }
        if block.hasPrefix("service") || block.hasPrefix("fixture") || block.hasPrefix("mock") { return ("server.rack", String(localized: "Services"), .teal) }
        if block.hasPrefix("docker") || block.hasPrefix("compose") { return ("shippingbox", String(localized: "Container"), .indigo) }
        if block.hasPrefix("setup") { return ("wrench.and.screwdriver", String(localized: "Setup"), .teal) }
        if block.hasPrefix("notify") { return ("bell", String(localized: "Notification"), .purple) }
        return ("terminal", String(localized: "Script"), .blue)
    }
}

extension FlowWorkspaceSummary.Tone {
    /// The shared status tone this is drawn in (docs/design.md, Badges)
    var style: StudioStyle.Tone {
        switch self {
        case .passed: return .passed
        case .failed: return .failed
        case .waiting: return .waiting
        case .neutral: return .neutral
        }
    }
}

extension StatusPill {
    /// A run's state as the shared badge: its icon first, then its name (the short one in a dense row), in its tone
    init(flowState state: String?, short: Bool = false) {
        self.init(title: short ? FlowFormat.shortStateTitle(state) : FlowFormat.stateTitle(state),
                  symbol: FlowStateIcon.look(state).0, tone: FlowWorkspaceSummary.tone(state).style)
    }
}

/// Run and node state icons
struct FlowStateIcon: View {
    let state: String?
    var size: CGFloat = 12
    /// A step that is running spins where the screen follows a run live; elsewhere it keeps the still icon
    var spins = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (name, color) = FlowStateIcon.look(state)
        Group {
            if spins, !reduceMotion, state == "RUNNING" || state == "PREFLIGHT" {
                ProgressView().controlSize(.mini).frame(width: size, height: size)
            } else {
                SymbolIcon(name).font(.system(size: size)).foregroundStyle(color)
            }
        }
        .help(FlowFormat.stateTitle(state))
        .accessibilityLabel(FlowFormat.stateTitle(state))
    }

    static func look(_ s: String?) -> (String, Color) {
        switch s {
        case "SUCCEEDED", "PASSED": return ("checkmark.circle.fill", .green)
        case "CACHED": return ("checkmark.circle", .green)
        case "FAILED", "ROLLBACK_FAILED": return ("xmark.circle.fill", .red)
        case "INDETERMINATE": return ("questionmark.circle.fill", .red)
        case "INTERRUPTED": return ("stop.circle", .orange)
        case "REJECTED": return ("nosign", .orange)
        case "ROLLED_BACK", "ROLLING_BACK": return ("arrow.uturn.backward.circle.fill", .orange)
        case "CANCELLED": return ("stop.circle.fill", .secondary)
        case "RUNNING", "PREFLIGHT": return ("circle.dotted", .blue)
        case "SKIPPED": return ("minus.circle", .secondary)
        case nil: return ("circle", .secondary)
        default: return ("circle", .secondary)
        }
    }
}

enum FlowFormat {
    static func shortStateTitle(_ state: String?) -> String {
        switch state {
        case nil: return String(localized: "Ready")
        case "CACHED": return String(localized: "Cached")
        case "INDETERMINATE", "ROLLBACK_FAILED": return String(localized: "Failed")
        case "REJECTED": return String(localized: "Rejected")
        case "ROLLED_BACK": return String(localized: "Rolled back")
        default: return stateTitle(state)
        }
    }

    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1fs", s) }
        return "\(Int(s) / 60)m \(Int(s) % 60)s"
    }

    static func stateTitle(_ s: String?) -> String {
        switch s {
        case "SUCCEEDED": return String(localized: "Succeeded")
        case "PASSED": return String(localized: "Passed")
        case "CACHED": return String(localized: "Passed before with the same inputs")
        case "FAILED": return String(localized: "Failed")
        case "INDETERMINATE": return String(localized: "Couldn't judge (counts as a failure)")
        case "INTERRUPTED": return String(localized: "Interrupted")
        case "REJECTED": return String(localized: "Rejected before running")
        case "ROLLING_BACK": return String(localized: "Rolling back")
        case "ROLLED_BACK": return String(localized: "Failed and rolled back")
        case "ROLLBACK_FAILED": return String(localized: "Rollback failed — environment on hold")
        case "CANCELLED": return String(localized: "Canceled")
        case "RUNNING", "PREFLIGHT": return String(localized: "Running")
        case "SKIPPED": return String(localized: "Skipped")
        case "PENDING": return String(localized: "Waiting")
        default: return String(localized: "Not run yet")
        }
    }
}

extension ISO8601DateFormatter {
    /// The engine's timestamps (2026-10-26T05:23:20.616Z)
    static let flow: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
