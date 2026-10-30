import SwiftUI

/// Run and node state icons
struct FlowStateIcon: View {
    let state: String?
    var size: CGFloat = 12

    var body: some View {
        let (name, color) = FlowStateIcon.look(state)
        Image(systemName: name)
            .font(.system(size: size))
            .foregroundStyle(color)
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
