import Foundation

/// A bounded dependency layout, mirrored by Windows entities/flow/model/graph.ts.
enum FlowGraphLayout {
    struct Input {
        let id: String
        let needs: [String]
    }
    struct Item {
        let id: String
        let x: CGFloat
        let y: CGFloat
    }
    struct Layout {
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
        var missingDependencies: [String] = []
        var unresolved: [String] = []
    }

    /// One step card and the gaps between cards, shared by the layout and the canvas that draws it. (Windows: FLOW_CARD)
    static let cardWidth: CGFloat = 192
    static let cardHeight: CGFloat = 80
    static let columnGap: CGFloat = 40
    static let rowGap: CGFloat = 14
    static let margin: CGFloat = 24
    static let columnPitch = cardWidth + columnGap
    static let rowPitch = cardHeight + rowGap

    /// Overview fitting has no manual-zoom floor, so wide and tall pipelines remain complete. The viewport is the
    /// canvas alone; 24 pt keeps the cards off its edges.
    static func fit(_ layout: Layout, viewport: CGSize) -> CGFloat {
        max(0.001, min(1, min((viewport.width - 24) / max(1, layout.width), (viewport.height - 24) / max(1, layout.height))))
    }

    static func make(_ input: [Input]) -> Layout {
        var seen = Set<String>()
        let nodes = input.filter { seen.insert($0.id).inserted }
        let known = Set(nodes.map(\.id))
        let missing = nodes.flatMap { node in node.needs.filter { !known.contains($0) }.map { node.id + " → " + $0 } }.sorted()
        var remaining: [String: Int] = [:]
        var children: [String: [String]] = [:]
        var levels: [String: Int] = [:]
        for node in nodes {
            let needs = Set(node.needs.filter { known.contains($0) })
            remaining[node.id] = needs.count
            for dependency in needs { children[dependency, default: []].append(node.id) }
        }
        var queue = nodes.filter { remaining[$0.id] == 0 }.map(\.id)
        var cursor = 0
        for id in queue { levels[id] = 0 }
        while cursor < queue.count {
            let id = queue[cursor]
            cursor += 1
            for child in children[id] ?? [] {
                levels[child] = max(levels[child] ?? 0, (levels[id] ?? 0) + 1)
                remaining[child, default: 0] -= 1
                if remaining[child] == 0 { queue.append(child) }
            }
        }
        // Invalid cycles still render without unbounded recursion or repeated relaxation.
        let unresolvedLevel = (levels.values.max() ?? -1) + 1
        for node in nodes where remaining[node.id, default: 0] > 0 { levels[node.id] = unresolvedLevel }
        var rows: [Int: Int] = [:]
        let items = nodes.map { node in
            let level = levels[node.id] ?? 0
            let row = rows[level, default: 0]
            rows[level] = row + 1
            return Item(id: node.id, x: margin + CGFloat(level) * columnPitch, y: margin + CGFloat(row) * rowPitch)
        }
        return Layout(items: items,
                      width: (items.map(\.x).max() ?? margin) + cardWidth + margin,
                      height: (items.map(\.y).max() ?? margin) + cardHeight + margin,
                      missingDependencies: Array(Set(missing)).sorted(), unresolved: nodes.filter { remaining[$0.id, default: 0] > 0 }.map(\.id))
    }
}
