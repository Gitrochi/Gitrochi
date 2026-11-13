import SwiftUI
import AppKit

/// A failed step as the shared failed-check block draws it: "Failed after 2m 10s", the tests that failed and Jump to
/// first error. The workspace inspector puts the end of the step's output below it; the run sheet has its own Output.
/// (Windows: FailedStep in FlowWorkspace.tsx, NodeDetail in FlowRunDialog.tsx)
struct FlowFailedStep: View {
    let node: FlowRunView.Node
    /// The engine's own list of failed tests; without it the output is read for their names
    var tests: [String] = []
    /// Counts presses of Jump to first error, for the log that shows this step's output
    @Binding var jump: Int
    /// The output and its ⋯ menu are part of the block
    var withLog = false

    var body: some View {
        let reading = JobLog.Reading(output: node.tail)
        var actions = FailedCheckActions()
        if JobLog.firstError(reading.lines) != nil { actions.jump = { jump += 1 } }
        if withLog {
            actions.menu = true
            actions.moreLabel = String(localized: "More step actions")
            if !node.tail.isEmpty { actions.copy = { FlowFailedStep.copy(node.tail) } }
        }
        let outcome = node.durationMs.map { String(localized: "Failed after \(FlowFormat.duration($0))") } ?? FlowFormat.stateTitle(node.state.rawValue)
        return FailedCheckBlock(outcome: outcome, tests: tests.isEmpty ? reading.tests : tests, actions: actions) {
            FlowStateIcon(state: node.state.rawValue, size: 14)
        } content: {
            if withLog, !reading.lines.isEmpty {
                CheckLog(label: node.id + " · " + String(localized: "Output"), lines: reading.lines, jump: jump, framed: true)
            }
        }
    }

    static func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
