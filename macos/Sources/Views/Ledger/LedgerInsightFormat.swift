import Foundation

/// Pure helpers of the Insights sheet. (Windows: entities/ledger/lib/insights.ts, unit-tested there)
enum LedgerInsightFormat {
    /// The order the verdict bars use: what needs a person first
    static let verdicts: [LedgerVerdict] = [.needsHuman, .confirm, .expirable, .pendingMerge, .stale, .active, .shelved, .archived]

    private static let units: [(NSCalendar.Unit, LedgerMs)] = [(.day, 86_400_000), (.hour, 3_600_000), (.minute, 60_000), (.second, 1_000)]

    /// The largest unit and the next one when it is not zero ("45s", "12m", "2h 10m", "3d"); "—" for none
    static func duration(_ ms: LedgerMs?) -> String {
        guard let ms else { return "—" }
        let total = max(0, ms / 1_000 * 1_000)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        guard let at = units.firstIndex(where: { total >= $0.1 }) else {
            formatter.allowedUnits = [.second]
            formatter.zeroFormattingBehavior = .default
            return formatter.string(from: 0) ?? "0s"
        }
        let size = units[at].1
        var kept = total / size * size
        var allowed: NSCalendar.Unit = units[at].0
        if at + 1 < units.count {
            let next = units[at + 1].1
            kept += (total - kept) / next * next
            allowed.insert(units[at + 1].0)
        }
        formatter.allowedUnits = allowed
        return formatter.string(from: TimeInterval(kept / 1_000)) ?? "—"
    }

    /// A bar's length for `value` out of the group's largest; a value above zero always shows
    static func barLength(_ value: Int, of largest: Int, in length: CGFloat) -> CGFloat {
        guard value > 0 else { return 0 }
        return min(length, max(2, length * CGFloat(value) / CGFloat(max(1, largest))))
    }
}
