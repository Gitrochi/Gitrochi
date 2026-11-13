import Foundation

/// The mark in a terminal tab's 12pt status slot: told apart by shape, not by colour alone (docs/design.md › App shell)
enum TerminalTabMark: String, Equatable {
    /// A command or program runs
    case ring
    /// Unseen output, or a session waiting for the user
    case dot
    /// The process ended; the tab keeps its scrollback
    case hollow
    /// Idle at the prompt: the slot stays empty
    case none
}

/// What the status line says about a terminal
enum TerminalActivity: String, Equatable { case running, idle, exited }

/// The terminal panel's status and narrow-width rules, kept pure so both platforms decide alike.
/// (Windows: entities/terminal/lib/panel-layout.ts, same names; tested in windows/tests/terminal-panel-layout.test.ts)
enum TerminalPanelLayout {
    /// A tab shows its title down to this width; narrower and it moves into the » menu
    static let tabMinWidth = 120.0
    static let tabMaxWidth = 200.0
    /// The » button with its count
    static let overflowWidth = 44.0
    /// An icon button in the tab bar with its gap
    static let controlWidth = 28.0

    /// Whether the tab is busy or waits for the user. An agent session's own status wins over the shell's process state.
    static func tabActivity(agent: String?, shellBusy: Bool) -> (busy: Bool, waiting: Bool) {
        switch agent {
        case "working", "running": return (true, false)
        case "permission", "waiting": return (false, true)
        case "starting": return (false, false)
        default: return (shellBusy, false)
        }
    }

    static func tabMark(exited: Bool, busy: Bool, unseen: Bool, waiting: Bool) -> TerminalTabMark {
        if exited { return .hollow }
        if unseen || waiting { return .dot }
        return busy ? .ring : .none
    }

    static func activity(exited: Bool, busy: Bool) -> TerminalActivity {
        exited ? .exited : busy ? .running : .idle
    }

    /// The width left for tabs in a tab bar this wide with this many icon buttons
    static func tabStripWidth(bar: Double, controls: Int) -> Double {
        max(0, bar - 16 - Double(controls) * controlWidth - 8)
    }

    /// Which tabs stay in the bar and which go into the » menu, by index. The selected tab always stays.
    static func tabOverflow(count: Int, selected: Int?, width: Double) -> (visible: [Int], hidden: [Int]) {
        guard count > 0 else { return ([], []) }
        if Double(count) * tabMinWidth <= width { return (Array(0..<count), []) }
        let fit = min(count, max(1, Int((width - overflowWidth) / tabMinWidth)))
        var visible = Array(0..<fit)
        if let selected, selected >= fit, selected < count { visible[fit - 1] = selected }
        return (visible, (0..<count).filter { !visible.contains($0) })
    }

    /// New terminal, voice and hide move into the actions menu when even one tab would not fit beside them
    static func compactBar(width: Double) -> Bool { width < 260 }

    /// The command rail becomes one "Commands" menu below this width
    static func commandsFolded(width: Double) -> Bool { width < 520 }

    /// "Insert, then Return" beside the commands goes when it would only show its first letters
    static func commandHintShown(width: Double) -> Bool { width >= 320 }

    /// A short pane hides the command rail so the output keeps its lines
    static func railShown(height: Double) -> Bool { height >= 140 }

    /// The status line drops the branch first, then the shell; the path and the state always stay
    static func statusLine(width: Double) -> (branch: Bool, shell: Bool) {
        (width >= 560, width >= 320)
    }
}
