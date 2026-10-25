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
        var doc = ConflictDocument()
        doc.newline = text.contains("\r\n") ? "\r\n" : "\n"
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        doc.trailingNewline = body.hasSuffix("\n")
        if doc.trailingNewline { body.removeLast() }
        enum State { case normal, ours, base, theirs }
        var state = State.normal
        var plain: [String] = [], ours: [String] = [], base: [String]? = nil, theirs: [String] = []
        var oursLabel = ""
        var width = 7, pending: [String] = []
        func label(_ line: String, _ marker: Character, width: Int) -> String? {
            guard line.hasPrefix(String(repeating: String(marker), count: width)) else { return nil }
            let rest = line.dropFirst(width)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if state != .normal { pending.append(line) }
            switch state {
            case .normal:
                let openingWidth = line.prefix(while: { $0 == "<" }).count
                if openingWidth >= 7, let openingLabel = label(line, "<", width: openingWidth) {
                    if !plain.isEmpty { doc.segments.append(.text(plain)); plain = [] }
                    width = openingWidth
                    oursLabel = openingLabel
                    pending = [line]
                    ours = []; base = nil; theirs = []
                    state = .ours
                } else {
                    plain.append(line)
                }
            case .ours:
                if label(line, "|", width: width) != nil { base = []; state = .base }
                else if line == String(repeating: "=", count: width) { state = .theirs }
                else { ours.append(line) }
            case .base:
                if line == String(repeating: "=", count: width) { state = .theirs } else { base?.append(line) }
            case .theirs:
                if let theirsLabel = label(line, ">", width: width) {
                    let b = Block(id: doc.blocks.count, oursLabel: oursLabel,
                                  theirsLabel: theirsLabel,
                                  ours: ours, base: base, theirs: theirs)
                    doc.blocks.append(b)
                    doc.segments.append(.conflict(b.id))
                    state = .normal
                    pending = []
                } else {
                    theirs.append(line)
                }
            }
        }
        // 닫히지 않은 표시는 글로 돌려놓는다
        if state != .normal {
            plain += pending
        }
        if !plain.isEmpty { doc.segments.append(.text(plain)) }
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
        guard blocks.allSatisfy({ choices[$0.id] != nil }) else { return nil }
        var out: [String] = []
        for s in segments {
            switch s {
            case .text(let l): out += l
            case .conflict(let i): out += Self.lines(blocks[i], choices[i]!)
            }
        }
        return out.joined(separator: newline) + (trailingNewline ? newline : "")
    }
}
