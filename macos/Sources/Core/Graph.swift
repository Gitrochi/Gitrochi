import Foundation

/// 레인 계산은 Rust에 모으고 숫자 버퍼로 전달해 JSON 객체 왕복을 피한다.
enum GraphLayout {
    static func compute(_ commits: [Commit]) -> (rows: [GraphRow], maxLanes: Int) {
        var ids: [String: UInt32] = [:]
        func id(_ key: String) -> UInt32 {
            if let n = ids[key] { return n }
            let n = UInt32(ids.count); ids[key] = n; return n
        }
        var input: [UInt32] = [UInt32(commits.count)]
        input.reserveCapacity(1 + commits.reduce(0) { $0 + 3 + $1.parents.count })
        for c in commits {
            input.append(id(c.id)); input.append(c.isWIP ? 1 : 0); input.append(UInt32(c.parents.count))
            for parent in c.parents { input.append(id(parent)) }
        }
        let data = RustCore.graph(input)
        var cursor = 2
        func next() -> Int { defer { cursor += 1 }; return Int(data[cursor]) }
        var rows: [GraphRow] = []; rows.reserveCapacity(Int(data[0]))
        for _ in 0..<Int(data[0]) {
            let column = next(), color = next(), width = next(), count = next()
            var segments: [GraphSegment] = []; segments.reserveCapacity(count)
            for _ in 0..<count { segments.append(GraphSegment(x1: Double(next()), y1: Double(next()) / 2, x2: Double(next()), y2: Double(next()) / 2, color: next(), dashed: next() != 0)) }
            rows.append(GraphRow(column: column, color: color, segments: segments, width: width))
        }
        return (rows, Int(data[1]))
    }
}
