import Foundation

/// 충돌 난 파일: 충돌 표시(<<<<<<< ======= >>>>>>>) 사이를 블록으로 나눈 것
struct ConflictDocument {
    enum Segment {
        /// 충돌 없는 줄들
        case text([String])
        /// 충돌 블록(몇 번째인지)
        case conflict(Int)
    }

    struct Block: Identifiable {
        let id: Int
        /// <<<<<<< 뒤의 이름(HEAD 등)
        let oursLabel: String
        let theirsLabel: String
        let ours: [String]
        /// diff3 형식이면 공통 조상(||||||| 와 ======= 사이)
        let base: [String]?
        let theirs: [String]
    }

    /// 블록마다 고르는 것
    enum Choice: Equatable {
        case ours, theirs, oursThenTheirs, theirsThenOurs
        case custom(String)
    }

    var segments: [Segment] = []
    var blocks: [Block] = []
    /// 줄 끝(원래 파일이 CRLF 면 그대로 쓴다)
    var newline = "\n"
    /// 파일 끝에 줄바꿈이 있었는지
    var trailingNewline = true

    var isEmpty: Bool { blocks.isEmpty }

    /// 충돌 표시를 읽는다(표시가 없으면 블록이 없다)
    static func parse(_ text: String) -> ConflictDocument {
        let v = RustCore.object(RustCore.call("conflict", ["text": text]))
        var doc = ConflictDocument()
        doc.newline = RustCore.string(v["newline"])
        doc.trailingNewline = RustCore.flag(v["trailingNewline"])
        doc.blocks = RustCore.objects(v["blocks"]).map { b in
            Block(id: RustCore.integer(b["id"]), oursLabel: RustCore.string(b["oursLabel"]), theirsLabel: RustCore.string(b["theirsLabel"]),
                  ours: RustCore.strings(b["ours"]), base: b["base"] as? [String], theirs: RustCore.strings(b["theirs"]))
        }
        doc.segments = RustCore.objects(v["segments"]).map { s in
            RustCore.string(s["kind"]) == "text" ? .text(RustCore.strings(s["lines"])) : .conflict(RustCore.integer(s["block"]))
        }
        return doc
    }

    static func lines(_ b: Block, _ c: Choice) -> [String] {
        switch c {
        case .ours: return b.ours
        case .theirs: return b.theirs
        case .oursThenTheirs: return b.ours + b.theirs
        case .theirsThenOurs: return b.theirs + b.ours
        case .custom(let s): return s.isEmpty ? [] : s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        }
    }

    /// 고른 대로 합친 파일 내용(모든 블록을 골랐을 때만)
    func resolved(_ choices: [Int: Choice]) -> String? {
        let blocks: [[String: Any]] = self.blocks.map { ["id": $0.id, "oursLabel": $0.oursLabel, "theirsLabel": $0.theirsLabel,
            "ours": $0.ours, "base": $0.base.map { $0 as Any } ?? NSNull(), "theirs": $0.theirs] }
        let segments: [[String: Any]] = self.segments.map {
            switch $0 { case .text(let lines): return ["kind": "text", "lines": lines]; case .conflict(let block): return ["kind": "conflict", "block": block] }
        }
        let mapped = Dictionary(uniqueKeysWithValues: choices.map { id, choice -> (String, [String: String]) in
            let v: [String: String]
            switch choice {
            case .ours: v = ["kind": "ours"]
            case .theirs: v = ["kind": "theirs"]
            case .oursThenTheirs: v = ["kind": "oursThenTheirs"]
            case .theirsThenOurs: v = ["kind": "theirsThenOurs"]
            case .custom(let text): v = ["kind": "custom", "text": text]
            }
            return (String(id), v)
        })
        return RustCore.call("resolveConflict", ["doc": ["blocks": blocks, "segments": segments, "newline": newline, "trailingNewline": trailingNewline], "choices": mapped]) as? String
    }
}
