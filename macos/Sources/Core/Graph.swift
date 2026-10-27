import Foundation

/// 레인 계산은 Rust에 모으고 숫자 버퍼로 전달해 JSON 객체 왕복을 피한다.
/// The Swift algorithm below produces the same lanes and stays as the fallback when the
/// core returns nothing (a panic, or an input past its size limit), so a huge history
/// still draws instead of crashing the app.
enum GraphLayout {
    static func compute(_ commits: [Commit]) -> (rows: [GraphRow], maxLanes: Int) {
        computeInRust(commits) ?? computeInSwift(commits)
    }

    private static func computeInRust(_ commits: [Commit]) -> (rows: [GraphRow], maxLanes: Int)? {
        var ids: [String: UInt32] = [:]
        func id(_ key: String) -> UInt32 {
            if let n = ids[key] { return n }
            let n = UInt32(ids.count); ids[key] = n; return n
        }
        var input: [UInt32] = [UInt32(commits.count)]
        input.reserveCapacity(1 + commits.reduce(0) { $0 + 3 + $1.parents.count })
        for c in commits {
            input.append(id(c.id)); input.append(c.isPending ? 1 : 0); input.append(UInt32(c.parents.count))
            for parent in c.parents { input.append(id(parent)) }
        }
        guard let data = RustCore.graph(input) else { return nil }
        // Every read is bounds-checked: a short buffer means a fallback, never a crash.
        struct Malformed: Error {}
        var cursor = 2
        func next() throws -> Int {
            guard cursor < data.count else { throw Malformed() }
            defer { cursor += 1 }
            return Int(data[cursor])
        }
        do {
            guard data.count >= 2, Int(data[0]) == commits.count else { throw Malformed() }
            var rows: [GraphRow] = []; rows.reserveCapacity(commits.count)
            for _ in 0..<commits.count {
                let column = try next(), color = try next(), width = try next(), count = try next()
                var segments: [GraphSegment] = []; segments.reserveCapacity(count)
                for _ in 0..<count {
                    let x1 = try next(), y1 = try next(), x2 = try next(), y2 = try next(), color = try next(), dashed = try next()
                    segments.append(GraphSegment(x1: Double(x1), y1: Double(y1) / 2, x2: Double(x2), y2: Double(y2) / 2, color: color, dashed: dashed != 0))
                }
                rows.append(GraphRow(column: column, color: color, segments: segments, width: width))
            }
            return (rows, Int(data[1]))
        } catch {
            FileHandle.standardError.write(Data("[gitrochi] shared graph layout is malformed; using the Swift layout\n".utf8))
            return nil
        }
    }

    /// 커밋 목록(자식 → 부모 순)에 레인을 배정해 행마다 그릴 선분을 만든다.
    ///
    /// 각 레인은 "다음에 나타날 것으로 기대하는 커밋"을 들고 아래로 내려간다.
    /// 커밋이 나타나면 그 커밋을 기다리던 레인들이 노드로 모이고, 노드에서
    /// 첫 부모는 같은 레인으로, 나머지 부모(머지)는 다른 레인으로 갈라진다.
    private static func computeInSwift(_ commits: [Commit]) -> (rows: [GraphRow], maxLanes: Int) {
        var lanes: [String?] = []
        var colors: [Int] = []
        var dashed: [Bool] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        var maxLanes = 1

        func freeSlot(excluding: Int? = nil) -> Int {
            if let i = lanes.indices.first(where: { lanes[$0] == nil && $0 != excluding }) { return i }
            lanes.append(nil); colors.append(0); dashed.append(false)
            return lanes.count - 1
        }

        for c in commits {
            let before = lanes
            let beforeColors = colors
            let beforeDashed = dashed

            let col: Int
            if let i = lanes.firstIndex(where: { $0 == c.id }) {
                col = i
            } else {
                col = freeSlot()
                colors[col] = nextColor
                nextColor += 1
            }
            let nodeColor = colors[col]
            var segs: [GraphSegment] = []

            // 위쪽 절반: 이 커밋으로 모이는 선과 그냥 지나가는 선
            for (i, expected) in before.enumerated() {
                guard let expected else { continue }
                if expected == c.id {
                    segs.append(GraphSegment(x1: Double(i), y1: 0, x2: Double(col), y2: 0.5,
                                             color: beforeColors[i], dashed: beforeDashed[i]))
                } else {
                    segs.append(GraphSegment(x1: Double(i), y1: 0, x2: Double(i), y2: 1,
                                             color: beforeColors[i], dashed: beforeDashed[i]))
                }
            }
            for i in lanes.indices where lanes[i] == c.id { lanes[i] = nil }

            // 아래쪽 절반: 부모들로 이어지는 선
            if let first = c.parents.first {
                lanes[col] = first
                colors[col] = nodeColor
                dashed[col] = c.isPending
                segs.append(GraphSegment(x1: Double(col), y1: 0.5, x2: Double(col), y2: 1,
                                         color: nodeColor, dashed: c.isPending))
                for p in c.parents.dropFirst() {
                    if let j = lanes.firstIndex(where: { $0 == p }) {
                        segs.append(GraphSegment(x1: Double(col), y1: 0.5, x2: Double(j), y2: 1,
                                                 color: colors[j], dashed: false))
                    } else {
                        let j = freeSlot(excluding: col)
                        lanes[j] = p
                        colors[j] = nextColor
                        dashed[j] = false
                        nextColor += 1
                        segs.append(GraphSegment(x1: Double(col), y1: 0.5, x2: Double(j), y2: 1,
                                                 color: colors[j], dashed: false))
                    }
                }
            }

            while let last = lanes.last, last == nil {
                lanes.removeLast(); colors.removeLast(); dashed.removeLast()
            }
            let width = max(before.count, lanes.count, col + 1)
            maxLanes = max(maxLanes, width)
            rows.append(GraphRow(column: col, color: nodeColor, segments: segs, width: width))
        }
        return (rows, maxLanes)
    }
}
