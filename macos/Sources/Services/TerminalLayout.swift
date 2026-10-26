import Foundation

/// Split terminal panes: a binary tree whose leaves hold terminal tabs (session ids). Each change returns a new tree.
/// (Windows: entities/terminal/lib/layout.ts)
indirect enum TerminalNode: Hashable {
    struct Pane: Hashable {
        let id: UUID
        var sessions: [UUID]
        var selected: UUID?

        /// The tab this pane shows: the focused session if it is here, otherwise the pane's own choice
        func shown(active: UUID?) -> UUID? {
            if let active, sessions.contains(active) { return active }
            return selected
        }
    }

    /// sideBySide: split right, stacked: split down
    enum Axis: Hashable { case sideBySide, stacked }

    case pane(Pane)
    /// ratio is the first child's share
    case split(id: UUID, axis: Axis, ratio: Double, a: TerminalNode, b: TerminalNode)

    static func newPane(_ sessions: [UUID]) -> TerminalNode {
        .pane(Pane(id: UUID(), sessions: sessions, selected: sessions.last))
    }

    var panes: [Pane] {
        switch self {
        case .pane(let p): return [p]
        case .split(_, _, _, let a, let b): return a.panes + b.panes
        }
    }

    func pane(of session: UUID?) -> Pane? {
        guard let session else { return nil }
        return panes.first { $0.sessions.contains(session) }
    }

    /// The top-right pane, which carries the panel's own buttons
    var corner: Pane {
        switch self {
        case .pane(let p): return p
        case .split(_, let axis, _, let a, let b): return axis == .sideBySide ? b.corner : a.corner
        }
    }

    private func mapPanes(_ f: (Pane) -> TerminalNode) -> TerminalNode {
        switch self {
        case .pane(let p): return f(p)
        case .split(let id, let axis, let ratio, let a, let b): return .split(id: id, axis: axis, ratio: ratio, a: a.mapPanes(f), b: b.mapPanes(f))
        }
    }

    /// Adds a tab to the pane (the first pane if it is gone), or starts the layout
    static func adding(_ session: UUID, to paneID: UUID?, in root: TerminalNode?) -> TerminalNode {
        guard let root, let first = root.panes.first else { return newPane([session]) }
        let target = root.panes.first { $0.id == paneID }?.id ?? first.id
        return root.mapPanes { p in
            guard p.id == target else { return .pane(p) }
            var q = p
            q.sessions.append(session)
            q.selected = session
            return .pane(q)
        }
    }

    /// Puts a new pane with the session beside or below the pane
    func splitting(_ paneID: UUID, _ axis: Axis, with session: UUID) -> TerminalNode {
        mapPanes { p in p.id == paneID ? .split(id: UUID(), axis: axis, ratio: 0.5, a: .pane(p), b: .newPane([session])) : .pane(p) }
    }

    func selecting(_ session: UUID) -> TerminalNode {
        mapPanes { p in
            guard p.sessions.contains(session) else { return .pane(p) }
            var q = p
            q.selected = session
            return .pane(q)
        }
    }

    /// Removes the tab; an emptied pane goes away and its sibling takes the split's place. nil when nothing is left.
    func removing(_ session: UUID) -> TerminalNode? {
        switch self {
        case .pane(var p):
            guard let i = p.sessions.firstIndex(of: session) else { return self }
            p.sessions.remove(at: i)
            if p.sessions.isEmpty { return nil }
            if p.selected == session { p.selected = p.sessions[min(i, p.sessions.count - 1)] }
            return .pane(p)
        case .split(let id, let axis, let ratio, let a, let b):
            let na = a.removing(session), nb = b.removing(session)
            guard let na else { return nb }
            guard let nb else { return na }
            return .split(id: id, axis: axis, ratio: ratio, a: na, b: nb)
        }
    }

    func resizing(_ splitID: UUID, to ratio: Double) -> TerminalNode {
        switch self {
        case .pane:
            return self
        case .split(let id, let axis, let r, let a, let b):
            let value = id == splitID ? min(0.85, max(0.15, ratio)) : r
            return .split(id: id, axis: axis, ratio: value, a: a.resizing(splitID, to: ratio), b: b.resizing(splitID, to: ratio))
        }
    }
}
