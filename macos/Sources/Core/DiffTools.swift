import Foundation

/// 화면의 글자 단위 위치는 Swift Character 기준으로 받는다.
enum WordDiff {
    static func tokens(_ text: String) -> [Substring] {
        RustCore.strings(RustCore.call("tokens", ["text": text])).map { Substring($0) }
    }
    static func ranges(_ a: String, _ b: String) -> ([Range<Int>], [Range<Int>]) {
        let spans = RustCore.call("wordRanges", ["a": a, "b": b]) as! [[[Int]]]
        return (spans[0].map { $0[0]..<$0[1] }, spans[1].map { $0[0]..<$0[1] })
    }
    static func mark(_ doc: inout DiffDocument) {
        let lines = RustCore.objects(RustCore.call("markWords", ["lines": DiffPatch.lines(doc.lines)]))
        for i in doc.lines.indices { doc.lines[i].changes = (lines[i]["changes"] as? [[Int]] ?? []).map { $0[0]..<$0[1] } }
    }
}

enum DiffSplit {
    static func rows(_ lines: [DiffLine]) -> [DiffSplitRow] {
        RustCore.objects(RustCore.call("splitRows", ["lines": DiffPatch.lines(lines)])).enumerated().map { i, r in
            DiffSplitRow(id: i, full: RustCore.optionalInteger(r["full"]), left: RustCore.optionalInteger(r["left"]), right: RustCore.optionalInteger(r["right"]))
        }
    }
}

/// 패치 생성만 Rust에 위임하고 실제 적용과 기존 Git 훅은 시스템 Git이 담당한다.
enum DiffPatch {
    static func lines(_ lines: [DiffLine]) -> [[String: Any]] {
        let kinds: [DiffLine.Kind: String] = [.context: "context", .added: "added", .removed: "removed", .hunk: "hunk", .meta: "meta"]
        return lines.map { ["kind": kinds[$0.kind]!, "text": $0.text, "raw": $0.raw, "oldNo": $0.oldNo.map { $0 as Any } ?? NSNull(), "newNo": $0.newNo.map { $0 as Any } ?? NSNull()] }
    }
    private static func payload(_ doc: DiffDocument, includeLines: Bool) -> [String: Any] {
        ["header": doc.header, "isBinary": doc.isBinary, "combined": doc.combined, "multipleFiles": doc.multipleFiles, "truncated": doc.truncated,
         "hunks": doc.hunks.map { ["line": $0.line, "oldStart": $0.oldStart, "oldCount": $0.oldCount, "newStart": $0.newStart, "newCount": $0.newCount] },
         "lines": includeLines ? lines(doc.lines) : []]
    }
    static func canEdit(_ doc: DiffDocument) -> Bool { RustCore.flag(RustCore.call("canEdit", ["doc": payload(doc, includeLines: false)])) }
    static func build(_ doc: DiffDocument, hunks: Set<Int>, lines selected: Set<Int>?, reverse: Bool) -> String? {
        RustCore.call("patch", ["doc": payload(doc, includeLines: true), "hunks": Array(hunks), "selected": selected.map { Array($0) as Any } ?? NSNull(), "reverse": reverse]) as? String
    }
}
