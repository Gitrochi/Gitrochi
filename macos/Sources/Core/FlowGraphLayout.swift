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
    }

    static let cardWidth: CGFloat = 220
    static let cardHeight: CGFloat = 112

    /// Fit includes the canvas toolbar and margins, even for diagrams wider than the default zoom range.
    static func fit(_ layout: Layout, viewport: CGSize) -> CGFloat {
        max(0.001, min(1, min((viewport.width - 12) / layout.width, (viewport.height - 48) / layout.height)))
    }

    static func make(_ input: [Input]) -> Layout {
        var seen = Set<String>()
        let nodes = input.filter { seen.insert($0.id).inserted }
        let known = Set(nodes.map(\.id))
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
            return Item(id: node.id, x: 28 + CGFloat(level) * 284, y: 28 + CGFloat(row) * 148)
        }
        return Layout(items: items,
                      width: max(276, (items.map(\.x).max() ?? 28) + cardWidth + 28),
                      height: max(168, (items.map(\.y).max() ?? 28) + cardHeight + 28))
    }
}
