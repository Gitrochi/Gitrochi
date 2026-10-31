import Foundation

/// A piece of a lane line inside one row, in the commit graph's terms (GraphSegment): x in lanes, y as a fraction of
/// the row (0 top, 0.5 the node, 1 bottom). Where x changes, the row draws the same curve the commit graph does.
struct LedgerGraphSegment: Hashable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var color: Int
    var dashed: Bool
}

/// The core's graph as rows to draw, newest first, each with the pieces of lines that cross it. The core lays out the
/// lanes; this only turns nodes and edges into rows. (Windows: entities/ledger/lib/graph-layout.ts)
struct LedgerGraphPlot: Equatable {
    struct Row: Identifiable, Equatable {
        let node: LedgerGraphNode
        var segments: [LedgerGraphSegment]
        var id: String { node.id }
    }

    var rows: [Row] = []
    var lanes = 1
    /// Older rows left out past the limit
    var hiddenRows = 0

    /// - Edges whose older end is not drawn (outside the period or past `limit`) run on to the bottom row.
    /// - Where an edge changes lanes, its straight part runs in the session's lane — the newer end of a fork, the older
    ///   end of a merge or hand-off — and the curve sits in the other end's row, as forks and merges do in the commit graph.
    /// - Sessions in `openSessions` continue upward from their newest node as a dashed line.
    static func plot(_ graph: LedgerGraph, openSessions: Set<String> = [], limit: Int = .max) -> LedgerGraphPlot {
        let sorted = graph.nodes.sorted { a, b in a.ts != b.ts ? a.ts > b.ts : a.lane != b.lane ? a.lane < b.lane : a.id < b.id }
        let kept = Array(sorted.prefix(max(0, limit)))
        var plot = LedgerGraphPlot(rows: kept.map { Row(node: $0, segments: []) },
                                   lanes: max(1, graph.lanes, (kept.map(\.lane).max() ?? 0) + 1),
                                   hiddenRows: sorted.count - kept.count)
        guard !kept.isEmpty else { return plot }
        let count = kept.count
        var row: [String: Int] = [:]
        for (i, node) in kept.enumerated() { row[node.id] = i }

        func add(_ r: Int, _ s: LedgerGraphSegment) { if r >= 0, r < count { plot.rows[r].segments.append(s) } }
        /// A straight line in one lane from (r1, y1) down to (r2, y2); a row past the last ends at the bottom
        func vertical(_ lane: Int, _ r1: Int, _ y1: Double, _ r2: Int, _ y2: Double, color: Int, dashed: Bool) {
            var (end, endY) = (r2, y2)
            if end >= count { end = count - 1; endY = 1 }
            guard r1 <= end else { return }
            for r in r1...end {
                let top = r == r1 ? y1 : 0, bottom = r == end ? endY : 1
                if bottom > top { add(r, LedgerGraphSegment(x1: Double(lane), y1: top, x2: Double(lane), y2: bottom, color: color, dashed: dashed)) }
            }
        }

        for edge in graph.edges {
            let a = row[edge.from], b = row[edge.to]
            guard a != nil || b != nil else { continue }
            let dashed = edge.kind == .handoff
            // an end that is not drawn sits below the last row, in the lane of the end that is
            let (ra, rb) = (a ?? count, b ?? count)
            let la = a.map { kept[$0].lane } ?? kept[b!].lane
            let lb = b.map { kept[$0].lane } ?? kept[a!].lane
            if la == lb {
                vertical(la, min(ra, rb), 0.5, max(ra, rb), 0.5, color: edge.color, dashed: dashed)
                continue
            }
            let runLane = edge.kind == .branch ? lb : la
            let (runRow, curveRow, curveLane) = runLane == la ? (ra, rb, lb) : (rb, ra, la)
            if curveRow < runRow {
                add(curveRow, LedgerGraphSegment(x1: Double(curveLane), y1: 0.5, x2: Double(runLane), y2: 1, color: edge.color, dashed: dashed))
                vertical(runLane, curveRow + 1, 0, runRow, 0.5, color: edge.color, dashed: dashed)
            } else if curveRow > runRow {
                vertical(runLane, runRow, 0.5, curveRow, 0, color: edge.color, dashed: dashed)
                add(curveRow, LedgerGraphSegment(x1: Double(runLane), y1: 0, x2: Double(curveLane), y2: 0.5, color: edge.color, dashed: dashed))
            } else {
                add(runRow, LedgerGraphSegment(x1: Double(la), y1: 0.5, x2: Double(lb), y2: 0.5, color: edge.color, dashed: dashed))
            }
        }

        // open sessions keep going: a dashed line from the newest node up to the top
        var newest: [String: Int] = [:]
        for (i, node) in kept.enumerated() {
            // lane 0 is the trunk: a baseline names the session that released it but is not on its lane
            if let id = node.sessionId, node.lane > 0, openSessions.contains(id), newest[id] == nil { newest[id] = i }
        }
        for (_, r) in newest where r > 0 {
            vertical(kept[r].lane, 0, 0, r, 0.5, color: kept[r].color, dashed: true)
        }
        // an open session whose nodes are all past the limit still holds its lane through every drawn row
        var below: [String: LedgerGraphNode] = [:]
        for node in sorted.dropFirst(kept.count) where node.lane > 0 {
            if let id = node.sessionId, openSessions.contains(id), newest[id] == nil, below[id] == nil { below[id] = node }
        }
        for (_, node) in below { vertical(node.lane, 0, 0, count, 1, color: node.color, dashed: true) }
        return plot
    }

    /// The centre of a lane at a row's node height in points, with the commit graph's metrics (laneWidth, rowHeight, leftPad);
    /// lanes and rows may be fractional, as segment ends are
    static func point(lane: Double, row: Double, laneWidth: Double, rowHeight: Double, leftPad: Double) -> (x: Double, y: Double) {
        (leftPad + laneWidth * (lane + 0.5), rowHeight * (row + 0.5))
    }
}
