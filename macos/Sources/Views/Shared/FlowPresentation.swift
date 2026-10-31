import SwiftUI

/// Semantic block colors and symbols are shared by the canvas and inspector.
enum FlowBlockStyle {
    static func look(_ block: String) -> (icon: String, title: String, color: Color) {
        if block.hasPrefix("test") || block.hasPrefix("check") { return ("checkmark.seal", String(localized: "Tests"), .green) }
        if block.hasPrefix("ci.") { return ("arrow.triangle.branch", String(localized: "CI/CD"), .purple) }
        if block.hasPrefix("deploy") { return ("shippingbox", String(localized: "Deploy"), .orange) }
        if block.hasPrefix("gate") { return ("hand.raised", String(localized: "Approval"), .orange) }
        if block.hasPrefix("service") || block.hasPrefix("mock") { return ("server.rack", String(localized: "Services"), .teal) }
        if block.hasPrefix("docker") || block.hasPrefix("compose") { return ("shippingbox", String(localized: "Container"), .indigo) }
        if block.hasPrefix("setup") { return ("wrench.and.screwdriver", String(localized: "Setup"), .teal) }
        if block.hasPrefix("notify") { return ("bell", String(localized: "Notification"), .purple) }
        return ("terminal", String(localized: "Script"), .blue)
    }
}

/// A readable status capsule; color supplements the state label.
struct FlowStatusBadge: View {
    let state: String?
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = FlowStateIcon.look(state)
        let color = state == nil ? Color.secondary : style.1
        HStack(spacing: compact ? 3 : 5) {
            if compact {
                Circle().fill(color).frame(width: 4, height: 4).accessibilityHidden(true)
            } else {
                if state == "RUNNING", !reduceMotion { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                else { Image(systemName: style.0).font(.system(size: 9, weight: .semibold)).foregroundStyle(color) }
            }
            Text(FlowFormat.shortStateTitle(state)).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 3 : 4)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.15), lineWidth: 0.5))
        .help(FlowFormat.stateTitle(state))
        .accessibilityLabel(FlowFormat.stateTitle(state))
    }
}

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
