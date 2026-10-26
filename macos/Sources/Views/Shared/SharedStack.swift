import SwiftUI

/// Panes stacked in one column share its height: each gets its natural height when that fits, and the long ones split what
/// is left (water-fill). None goes under the floor, even if the column then has to scroll. (Windows: shared/lib/share-heights.ts)
enum SharedHeights {
    static func share(_ naturals: [CGFloat], available: CGFloat, floor: CGFloat) -> [CGFloat] {
        var out = naturals.map { min($0, floor) }
        var left = available - out.reduce(0, +)
        var pending = Array(naturals.indices).filter { naturals[$0] > out[$0] }
        while left > 0, !pending.isEmpty {
            let fair = left / CGFloat(pending.count)
            let done = pending.filter { naturals[$0] - out[$0] <= fair }
            if done.isEmpty {
                for i in pending { out[i] += fair }
                break
            }
            for i in done {
                left -= naturals[i] - out[i]
                out[i] = naturals[i]
            }
            pending.removeAll { done.contains($0) }
        }
        return out.map { $0.rounded(.down) }
    }
}

private struct PaneNaturals: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

private struct PaneSharesKey: EnvironmentKey {
    static let defaultValue: [String: CGFloat]? = nil
}

extension EnvironmentValues {
    fileprivate var paneShares: [String: CGFloat]? {
        get { self[PaneSharesKey.self] }
        set { self[PaneSharesKey.self] = newValue }
    }
}

/// A column whose panes (SharedPane) share its height: each pane gets its natural height when that fits, the long ones split
/// what is left and scroll inside (sidebar sections, the working copy's file lists). The column itself scrolls only when
/// even the floors do not fit. (Windows: shared/ui/SharedStack.tsx)
struct SharedStack<Content: View>: View {
    var floor: CGFloat = 96
    @ViewBuilder let content: Content
    @ViewState private var naturals: [String: CGFloat] = [:]
    @ViewState private var shares: [String: CGFloat] = [:]
    @ViewState private var height: CGFloat = 0
    @ViewState private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .environment(\.paneShares, shares)
                .onPreferenceChange(PaneNaturals.self) { naturals = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: naturals) { recompute() }
        .onChange(of: height) { recompute() }
        .onChange(of: contentHeight) { recompute() }
    }

    /// The fixed parts (headers, spacing) are what the content takes beyond the panes at their current heights
    private func recompute() {
        guard height > 0 else { return }
        let ids = naturals.keys.sorted()
        let current = ids.reduce(CGFloat(0)) { $0 + (shares[$1] ?? naturals[$1] ?? 0) }
        let fixed = contentHeight - current
        let next = SharedHeights.share(ids.map { naturals[$0] ?? 0 }, available: height - fixed, floor: floor)
        var result: [String: CGFloat] = [:]
        for (i, id) in ids.enumerated() { result[id] = next[i] }
        // a point of rounding is no reason to lay out again
        let same = result.count == shares.count && result.allSatisfy { abs(($0.value) - (shares[$0.key] ?? -10)) <= 1 }
        if !same { shares = result }
    }
}

/// A pane in a SharedStack: scrolls inside when it got less than its natural height. Outside a stack it just grows.
struct SharedPane<Content: View>: View {
    let id: String
    @ViewBuilder let content: Content
    @Environment(\.paneShares) private var shares
    @ViewState private var natural: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
        }
        .frame(height: shares?[id] ?? natural)
        .preference(key: PaneNaturals.self, value: [id: natural])
    }
}
