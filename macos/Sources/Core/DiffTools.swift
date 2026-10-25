import Foundation

/// 단어 단위 diff: 지워진 줄과 더해진 줄을 짝지어, 실제로 바뀐 부분만 진하게 표시하도록 위치를 채운다.
enum WordDiff {
    /// 한 줄에서 바뀐 부분이 이보다 많으면(거의 다 바뀜) 표시하지 않는다
    private static let maxChangedRatio = 0.7
    private static let maxTokens = 400

    static func mark(_ doc: inout DiffDocument) {
        var i = 0
        let lines = doc.lines
        while i < lines.count {
            guard lines[i].kind == .removed else { i += 1; continue }
            var r = i
            while r < lines.count, lines[r].kind == .removed { r += 1 }
            var a = r
            while a < lines.count, lines[a].kind == .added { a += 1 }
            // [i, r) 지워진 줄, [r, a) 더해진 줄 — 순서대로 짝짓는다
            for k in 0..<min(r - i, a - r) {
                let (old, new) = ranges(lines[i + k].text, lines[r + k].text)
                doc.lines[i + k].changes = old
                doc.lines[r + k].changes = new
            }
            i = max(a, i + 1)
        }
    }

    /// 글자·숫자 묶음, 공백 묶음, 그 밖의 글자 하나씩
    static func tokens(_ s: String) -> [Substring] {
        var out: [Substring] = []
        var start = s.startIndex
        var kind = -1
        func k(_ c: Character) -> Int { c.isLetter || c.isNumber || c == "_" ? 0 : (c.isWhitespace ? 1 : 2) }
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = k(s[idx])
            if idx != start, c != kind || c == 2 {
                out.append(s[start..<idx])
                start = idx
            }
            kind = c
            idx = s.index(after: idx)
        }
        if start < s.endIndex { out.append(s[start...]) }
        return out
    }

    /// 두 줄에서 바뀐 글자 위치(공통 부분 수열 밖의 토큰)
    static func ranges(_ a: String, _ b: String) -> ([Range<Int>], [Range<Int>]) {
        let ta = tokens(a), tb = tokens(b)
        guard ta.count <= maxTokens, tb.count <= maxTokens, !ta.isEmpty, !tb.isEmpty else { return ([], []) }
        // LCS 표
        var dp = Array(repeating: Array(repeating: 0, count: tb.count + 1), count: ta.count + 1)
        for x in stride(from: ta.count - 1, through: 0, by: -1) {
            for y in stride(from: tb.count - 1, through: 0, by: -1) {
                dp[x][y] = ta[x] == tb[y] ? dp[x + 1][y + 1] + 1 : max(dp[x + 1][y], dp[x][y + 1])
            }
        }
        var keepA = Array(repeating: false, count: ta.count), keepB = Array(repeating: false, count: tb.count)
        var x = 0, y = 0
        while x < ta.count, y < tb.count {
            if ta[x] == tb[y] { keepA[x] = true; keepB[y] = true; x += 1; y += 1 }
            else if dp[x + 1][y] >= dp[x][y + 1] { x += 1 } else { y += 1 }
        }
        func spans(_ t: [Substring], _ keep: [Bool]) -> (spans: [Range<Int>], changed: Int, total: Int) {
            var out: [Range<Int>] = []
            var pos = 0, changed = 0, total = 0
            for (n, tok) in t.enumerated() {
                let len = tok.count
                let blank = tok.allSatisfy(\.isWhitespace)
                if !keep[n] {
                    if !blank { changed += len }
                    if let last = out.last, last.upperBound == pos { out[out.count - 1] = last.lowerBound..<(pos + len) }
                    else { out.append(pos..<(pos + len)) }
                }
                if !blank { total += len }
                pos += len
            }
            return (out, changed, total)
        }
        let sa = spans(ta, keepA), sb = spans(tb, keepB)
        let ratio = Double(sa.changed + sb.changed) / Double(max(1, sa.total + sb.total))
        guard ratio <= maxChangedRatio else { return ([], []) }
        return (sa.spans, sb.spans)
    }
}

/// 나란히 보기: 문맥 줄은 양쪽에, 지운 줄 묶음과 더한 줄 묶음은 순서대로 짝지어 같은 높이에
enum DiffSplit {
    static func rows(_ lines: [DiffLine]) -> [DiffSplitRow] {
        var rows: [DiffSplitRow] = []
        var i = 0
        func add(_ r: DiffSplitRow) { rows.append(DiffSplitRow(id: rows.count, full: r.full, left: r.left, right: r.right)) }
        while i < lines.count {
            switch lines[i].kind {
            case .hunk, .meta:
                add(DiffSplitRow(id: 0, full: i)); i += 1
            case .context:
                add(DiffSplitRow(id: 0, left: i, right: i)); i += 1
            case .removed, .added:
                var removed: [Int] = [], added: [Int] = []
                while i < lines.count, lines[i].kind == .removed { removed.append(i); i += 1 }
                while i < lines.count, lines[i].kind == .added { added.append(i); i += 1 }
                for k in 0..<max(removed.count, added.count) {
                    add(DiffSplitRow(id: 0, left: k < removed.count ? removed[k] : nil, right: k < added.count ? added[k] : nil))
                }
            }
        }
        return rows
    }
}

/// 줄·덩어리 단위 스테이지: diff 에서 고른 줄만 담은 패치를 만든다(git add -p 와 같은 규칙).
enum DiffPatch {
    /// 이 diff 로 줄 단위 패치를 만들 수 있는지(새 파일·지운 파일·이름 바꾼 파일·결합 diff·바이너리는 파일째로만)
    static func canEdit(_ doc: DiffDocument) -> Bool {
        guard !doc.isBinary, !doc.combined, !doc.multipleFiles, !doc.hunks.isEmpty, !doc.truncated else { return false }
        let h = doc.header
        guard h.contains(where: { $0.hasPrefix("--- a/") || $0.hasPrefix("--- \"a/") }),
              h.contains(where: { $0.hasPrefix("+++ b/") || $0.hasPrefix("+++ \"b/") }) else { return false }
        return !h.contains { $0.hasPrefix("new file mode") || $0.hasPrefix("deleted file mode") || $0.hasPrefix("rename ") || $0.hasPrefix("similarity") }
    }

    /// - lines: 고른 줄(nil 이면 덩어리의 모든 변경)
    /// - reverse: 거꾸로 적용할 패치(언스테이지·버리기). 고르지 않은 '+' 는 문맥으로 두고 '-' 는 뺀다.
    ///   앞으로 적용(스테이지)이면 고르지 않은 '-' 를 문맥으로 두고 '+' 는 뺀다.
    static func build(_ doc: DiffDocument, hunks: Set<Int>, lines selected: Set<Int>?, reverse: Bool) -> String? {
        guard canEdit(doc) else { return nil }
        var out = doc.header.filter { !$0.hasPrefix("index ") && !$0.hasPrefix("old mode ") && !$0.hasPrefix("new mode ") }
        var delta = 0, any = false
        for (n, h) in doc.hunks.enumerated() where hunks.contains(n) {
            let end = n + 1 < doc.hunks.count ? doc.hunks[n + 1].line : doc.lines.count
            var body: [String] = [], oldCount = 0, newCount = 0, changed = false, lastKept = false
            for line in doc.lines[(h.line + 1)..<end] {
                let pick = selected.map { $0.contains(line.id) } ?? true
                switch line.kind {
                case .context:
                    body.append(" " + line.raw); oldCount += 1; newCount += 1; lastKept = true
                case .removed:
                    if pick { body.append("-" + line.raw); oldCount += 1; changed = true; lastKept = true }
                    else if !reverse { body.append(" " + line.raw); oldCount += 1; newCount += 1; lastKept = true }
                    else { lastKept = false }
                case .added:
                    if pick { body.append("+" + line.raw); newCount += 1; changed = true; lastKept = true }
                    else if reverse { body.append(" " + line.raw); oldCount += 1; newCount += 1; lastKept = true }
                    else { lastKept = false }
                case .meta:
                    if lastKept { body.append(line.raw) }      // "\\ No newline at end of file" 은 앞 줄에 붙는다
                case .hunk:
                    break
                }
            }
            guard changed else { continue }
            any = true
            // 새 쪽 시작 줄: 넣기만 하는 덩어리는 다음 줄부터, 지우기만 하는 덩어리는 앞 줄(git 의 표기 규칙)
            // 역적용의 입력은 새 파일이므로 선택하지 않은 앞 덩어리의 줄 이동도 반영한다.
            let anchor = reverse ? h.newStart + (h.newCount == 0 ? 1 : 0) : h.oldStart + (h.oldCount == 0 ? 1 : 0)
            let oldStart = max(0, anchor + (reverse ? -delta : 0) - (oldCount == 0 ? 1 : 0))
            let newStart = max(0, anchor + (reverse ? 0 : delta) - (newCount == 0 ? 1 : 0))
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            out += body
            delta += newCount - oldCount
        }
        return any ? out.joined(separator: "\n") + "\n" : nil
    }
}
