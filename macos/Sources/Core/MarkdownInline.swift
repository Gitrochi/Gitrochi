import Foundation

/// Inline half of the Markdown parser (Markdown.swift; Windows: shared/lib/markdown-inline.ts)
extension Markdown {
    static func inlines(_ s: String, _ refs: Refs?, inLink: Bool = false) -> [Inline] {
        inlines(Array(s), refs, inLink: inLink)
    }

    /// Lines holding only tags (<p align="center">) leave nothing or stray line breaks behind
    static func trimBreaks(_ nodes: [Inline]) -> [Inline] {
        func visible(_ n: Inline) -> Bool {
            switch n {
            case .lineBreak: return false
            case .text(let t): return !t.trimmed.isEmpty
            default: return true
            }
        }
        guard let a = nodes.firstIndex(where: visible), let b = nodes.lastIndex(where: visible) else { return [] }
        return Array(nodes[a...b])
    }

    static func plain(_ nodes: [Inline]) -> String {
        nodes.map { n -> String in
            switch n {
            case .text(let t), .code(let t): return t
            case .lineBreak: return " "
            case .image(_, let alt): return alt
            case .strong(let c), .em(let c), .strike(let c), .link(_, let c): return plain(c)
            }
        }.joined()
    }

    private static func inlines(_ s: [Character], _ refs: Refs?, inLink: Bool) -> [Inline] {
        let scan = Scan(s)
        let n = s.count
        var out: [Inline] = []
        var text = ""
        func flush() {
            if !text.isEmpty { out.append(.text(decode(text))) }
            text = ""
        }
        func push(_ node: Inline) {
            flush()
            out.append(node)
        }
        var i = 0
        while i < n {
            let c = s[i]
            if c == "\\" && i + 1 < n {
                if s[i + 1] == "\n" {
                    push(.lineBreak)
                    i += 2
                    continue
                }
                if isASCIIPunct(s[i + 1]) {
                    // keep it out of decode(): \&amp; stays literal
                    text += s[i + 1] == "&" ? "&amp;" : String(s[i + 1])
                    i += 2
                    continue
                }
            }
            if c == "\n" {
                while text.hasSuffix(" ") { text.removeLast() }
                push(.lineBreak)
                i += 1
                continue
            }
            if c == "`" {
                var r = i
                while r < n && s[r] == "`" { r += 1 }
                let len = r - i
                let end = scan.ticksAfter(r, len)
                if end < 0 {
                    text += String(s[i..<r])
                    i = r
                    continue
                }
                var code = String(s[r..<end]).replacingOccurrences(of: "\n", with: " ")
                if code.count > 1 && code.hasPrefix(" ") && code.hasSuffix(" ") && !code.trimmed.isEmpty { code = String(code.dropFirst().dropLast()) }
                push(.code(code))
                i = end + len
                continue
            }
            if c == "!" && i + 1 < n && s[i + 1] == "[", let l = linkAt(scan, i + 1) {
                let alt = plain(inlines(Array(l.text), nil, inLink: true))
                if let src = safeURL(l.href) {
                    push(.image(src: src, alt: alt))
                } else if !alt.isEmpty {
                    push(.text(alt))
                }
                i = l.end
                continue
            }
            if c == "[" && !inLink, let l = linkAt(scan, i) {
                let children = inlines(Array(l.text), refs, inLink: true)
                if let href = safeURL(l.href) {
                    push(.link(href: href, children: children))
                } else {
                    flush()
                    out += children
                }
                i = l.end
                continue
            }
            if c == "<" {
                let lim = min(n, i + 2000)
                if !inLink, let a = autolinkAt(s, i, lim) {
                    push(.link(href: a.url, children: [.text(a.url)]))
                    i = a.end
                    continue
                }
                if hasPrefix(s, i, "<!--"), let end = find(s, "-->", from: i + 4) {
                    i = end + 3
                    continue
                }
                if let tag = ["script", "style"].first(where: { hasPrefix(s, i, "<" + $0) && !isASCIIWord(at: s, i + 1 + $0.count, lim) }) {
                    let end = scan.findLowercased("</" + tag, from: i)
                    let close = end >= 0 ? (find(s, ">", from: end) ?? -1) : -1
                    i = close >= 0 ? close + 1 : n
                    continue
                }
                if let end = brAt(s, i, lim) {
                    push(.lineBreak)
                    i = end
                    continue
                }
                if let img = imgAt(s, i, lim) {
                    let src = safeURL(attr(img.attrs, "src") ?? "")
                    let alt = decode(attr(img.attrs, "alt") ?? "")
                    if let src {
                        push(.image(src: src, alt: alt))
                    } else if !alt.isEmpty {
                        push(.text(alt))
                    }
                    i = img.end
                    continue
                }
                // any other tag is dropped and its text kept
                if let end = tagAt(s, i, lim) {
                    i = end
                    continue
                }
            }
            if c == "*" || c == "_" || c == "~", let e = emphasisAt(scan, i, refs, inLink: inLink) {
                push(e.node)
                i = e.end
                continue
            }
            if !inLink && (i == 0 || s[i - 1].isWhitespace || "(*_~".contains(s[i - 1])) && "hHwW".contains(c),
               let u = urlAt(s, i) {
                push(.link(href: u.lowercased().hasPrefix("www.") ? "http://" + u : u, children: [.text(u)]))
                i += u.count
                continue
            }
            if let refs, !inLink, "#!@".contains(c), i == 0 || s[i - 1].isWhitespace || "([{,;:'\"".contains(s[i - 1]) {
                let lim = min(n, i + 300)
                if c != "@", c == "#" || refs.request != nil {
                    var k = i + 1
                    while k < lim && s[k].isASCII && s[k].isNumber { k += 1 }
                    if k > i + 1 && !(k < lim && isWord(s[k])) {
                        let number = String(s[(i + 1)..<k])
                        push(.link(href: c == "#" ? refs.issue(number) : refs.request!(number), children: [.text(String(s[i..<k]))]))
                        i = k
                        continue
                    }
                }
                if c == "@", let end = userAt(s, i, lim) {
                    push(.link(href: refs.user(String(s[(i + 1)..<end])), children: [.text(String(s[i..<end]))]))
                    i = end
                    continue
                }
            }
            text.append(c)
            i += 1
        }
        flush()
        return out
    }

    /// [text](href "title") starting at s[i] == "["
    private static func linkAt(_ scan: Scan, _ i: Int) -> (text: [Character], href: String, end: Int)? {
        let s = scan.s
        let j = scan.bracketFor(i)
        guard j >= 0, j + 1 < s.count, s[j + 1] == "(" else { return nil }
        var k = j + 2
        while k < s.count && s[k] == " " { k += 1 }
        var href = ""
        if k < s.count && s[k] == "<" {
            guard let close = find(s, ">", from: k) else { return nil }
            href = String(s[(k + 1)..<close])
            k = close + 1
        } else {
            var parens = 0
            while k < s.count {
                let c = s[k]
                if c.isWhitespace { break }
                if c == "\\" && k + 1 < s.count {
                    href.append(s[k + 1])
                    k += 2
                    continue
                }
                if c == "(" { parens += 1 }
                if c == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                href.append(c)
                k += 1
            }
        }
        guard let end = linkTail(s, k, min(s.count, k + 2000)) else { return nil }
        return (Array(s[(i + 1)..<j]), decode(href), end)
    }

    /// Optional "title" and the closing ) of a link
    private static func linkTail(_ s: [Character], _ from: Int, _ lim: Int) -> Int? {
        var k = from
        while k < lim && s[k].isWhitespace { k += 1 }
        if k < lim, let close: Character = ["\"": "\"", "'": "'", "(": ")"][s[k]] {
            var t = k + 1
            while t < lim && s[t] != close {
                if s[t] == "\\" { t += 1 }
                t += 1
            }
            if t < lim {
                k = t + 1
                while k < lim && s[k].isWhitespace { k += 1 }
            }
        }
        return k < lim && s[k] == ")" ? k + 1 : nil
    }

    /// Same delimiter run on both sides: *em*, **strong**, ***both***, ~strike~, ~~strike~~
    private static func emphasisAt(_ scan: Scan, _ i: Int, _ refs: Refs?, inLink: Bool) -> (node: Inline, end: Int)? {
        let s = scan.s
        let c = s[i]
        var run = 0
        while i + run < s.count && s[i + run] == c { run += 1 }
        guard i + run < s.count, !s[i + run].isWhitespace else { return nil }
        if c == "_" && i > 0 && isWord(s[i - 1]) { return nil }
        if c == "~" && run > 2 { return nil }
        for n in stride(from: c == "~" ? run : min(run, 3), through: 1, by: -1) {
            let end = scan.closingRun(i + n, c, n)
            if end < 0 { continue }
            let inner = inlines(Array(s[(i + n)..<end]), refs, inLink: inLink)
            let node: Inline = c == "~" ? .strike(inner) : n == 3 ? .strong([.em(inner)]) : n == 2 ? .strong(inner) : .em(inner)
            return (node, end + n)
        }
        return nil
    }

    private static func autolinkAt(_ s: [Character], _ i: Int, _ lim: Int) -> (url: String, end: Int)? {
        guard ["https://", "http://", "mailto:"].contains(where: { hasPrefix(s, i + 1, $0) }) else { return nil }
        var k = i + 1
        while k < lim && !s[k].isWhitespace && s[k] != "<" && s[k] != ">" { k += 1 }
        return k < lim && s[k] == ">" ? (String(s[(i + 1)..<k]), k + 1) : nil
    }

    private static func brAt(_ s: [Character], _ i: Int, _ lim: Int) -> Int? {
        guard hasPrefix(s, i, "<br") else { return nil }
        var k = i + 3
        while k < lim && s[k].isWhitespace { k += 1 }
        if k < lim && s[k] == "/" { k += 1 }
        return k < lim && s[k] == ">" ? k + 1 : nil
    }

    private static func imgAt(_ s: [Character], _ i: Int, _ lim: Int) -> (attrs: String, end: Int)? {
        guard hasPrefix(s, i, "<img"), !isASCIIWord(at: s, i + 4, lim) else { return nil }
        var k = i + 4
        while k < lim && s[k] != ">" { k += 1 }
        return k < lim ? (String(s[(i + 4)..<k]), k + 1) : nil
    }

    private static func tagAt(_ s: [Character], _ i: Int, _ lim: Int) -> Int? {
        var k = i + 1
        if k < lim && s[k] == "/" { k += 1 }
        guard k < lim, s[k].isASCII, s[k].isLetter else { return nil }
        k += 1
        while k < lim && s[k].isASCII && (s[k].isLetter || s[k].isNumber || s[k] == "-") { k += 1 }
        guard k < lim else { return nil }
        if s[k].isWhitespace {
            while k < lim && s[k] != "<" && s[k] != ">" { k += 1 }
            return k < lim && s[k] == ">" ? k + 1 : nil
        }
        if s[k] == "/" { return k + 1 < lim && s[k + 1] == ">" ? k + 2 : nil }
        return s[k] == ">" ? k + 1 : nil
    }

    private static func urlAt(_ s: [Character], _ i: Int) -> String? {
        guard let p = ["https://", "http://", "www."].first(where: { hasPrefix(s, i, $0) }) else { return nil }
        let lim = min(s.count, i + 4000)
        var k = i + p.count
        while k < lim && !s[k].isWhitespace && s[k] != "<" { k += 1 }
        return k > i + p.count ? trimURL(String(s[i..<k])) : nil
    }

    /// Drop trailing punctuation and unbalanced ")" the way GitHub does
    private static func trimURL(_ url: String) -> String {
        var u = url
        while let last = u.last {
            if "?!.,:*_~'\";".contains(last) {
                u.removeLast()
            } else if last == ")" && u.filter({ $0 == "(" }).count < u.filter({ $0 == ")" }).count {
                u.removeLast()
            } else {
                break
            }
        }
        return u
    }

    /// End of @name: the longest name that isn't followed by a name character or @ (an e-mail address)
    private static func userAt(_ s: [Character], _ i: Int, _ lim: Int) -> Int? {
        let start = i + 1
        guard start < lim, isNameStart(s[start]) else { return nil }
        var maxEnd = start + 1
        while maxEnd < lim && (isNameStart(s[maxEnd]) || s[maxEnd] == "." || s[maxEnd] == "-") { maxEnd += 1 }
        for end in stride(from: maxEnd, to: start, by: -1) where isNameStart(s[end - 1]) {
            if end < lim && (isNameStart(s[end]) || s[end] == "@") { continue }
            return end
        }
        return nil
    }

    private static func attr(_ attrs: String, _ name: String) -> String? {
        let a = Array(attrs)
        var p = 0
        while p < a.count {
            defer { p += 1 }
            guard p == 0 || a[p - 1].isWhitespace, hasPrefix(a, p, name) else { continue }
            var k = p + name.count
            while k < a.count && a[k].isWhitespace { k += 1 }
            guard k < a.count, a[k] == "=" else { continue }
            k += 1
            while k < a.count && a[k].isWhitespace { k += 1 }
            guard k < a.count else { continue }
            if a[k] == "\"" || a[k] == "'" {
                if let close = a[(k + 1)...].firstIndex(of: a[k]) { return String(a[(k + 1)..<close]) }
                continue
            }
            var e = k
            while e < a.count && !a[e].isWhitespace && !"\"'>".contains(a[e]) { e += 1 }
            if e > k { return String(a[k..<e]) }
        }
        return nil
    }

    private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}"]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            if c[i] == "&", let e = entity(c, i) {
                out += e.value
                i += e.length
            } else {
                out.append(c[i])
                i += 1
            }
        }
        return out
    }

    private static func entity(_ c: [Character], _ i: Int) -> (value: String, length: Int)? {
        var k = i + 1
        guard k < c.count else { return nil }
        if c[k] == "#" {
            k += 1
            let hex = k < c.count && (c[k] == "x" || c[k] == "X")
            if hex { k += 1 }
            let digits = k
            while k < c.count && c[k].isASCII && (hex ? c[k].isHexDigit : c[k].isNumber) { k += 1 }
            guard (1...(hex ? 6 : 7)).contains(k - digits), k < c.count, c[k] == ";",
                  let code = UInt32(String(c[digits..<k]), radix: hex ? 16 : 10), code > 0, let scalar = Unicode.Scalar(code)
            else { return nil }
            return (String(Character(scalar)), k + 1 - i)
        }
        let name = k
        while k < c.count && c[k].isASCII && c[k].isLetter { k += 1 }
        guard k > name, k < c.count, c[k] == ";", let value = entities[String(c[name..<k]).lowercased()] else { return nil }
        return (value, k + 1 - i)
    }
}

/// One string being parsed. Lookups for a closing `, ] or * are cached so text full of
/// unmatched delimiters (pasted logs) stays linear instead of rescanning to the end each time.
private final class Scan {
    let s: [Character]
    private var failedFrom: [String: Int] = [:]
    private var brackets: [Int]?
    private var lowered: [Character]?

    init(_ s: [Character]) { self.s = s }

    func ticksAfter(_ from: Int, _ n: Int) -> Int {
        let key = "`\(n)"
        if let f = failedFrom[key], f <= from { return -1 }
        var k = from
        while k < s.count {
            guard s[k] == "`" else {
                k += 1
                continue
            }
            var j = k
            while j < s.count && s[j] == "`" { j += 1 }
            if j - k == n { return k }
            k = j + 1
        }
        failedFrom[key] = from
        return -1
    }

    /// Matching ] for the [ at i, skipping escapes
    func bracketFor(_ i: Int) -> Int {
        if brackets == nil {
            var close = [Int](repeating: -1, count: s.count)
            var open: [Int] = []
            var k = 0
            while k < s.count {
                if s[k] == "\\" {
                    k += 1
                } else if s[k] == "[" {
                    open.append(k)
                } else if s[k] == "]", let o = open.popLast() {
                    close[o] = k
                }
                k += 1
            }
            brackets = close
        }
        return brackets![i]
    }

    /// A run of exactly n of c that can close emphasis opened before from
    func closingRun(_ from: Int, _ c: Character, _ n: Int) -> Int {
        let key = "\(c)\(n)"
        if let f = failedFrom[key], f <= from { return -1 }
        var k = from
        while k < s.count {
            let ch = s[k]
            if ch == "\\" {
                k += 2
                continue
            }
            if ch == "`" {
                var r = k
                while r < s.count && s[r] == "`" { r += 1 }
                let end = ticksAfter(r, r - k)
                k = end >= 0 ? end + (r - k) : r
                continue
            }
            guard ch == c else {
                k += 1
                continue
            }
            var j = k
            while j < s.count && s[j] == c { j += 1 }
            let after: Character? = j < s.count ? s[j] : nil
            if j - k == n && k > from && !s[k - 1].isWhitespace && !(c == "_" && after.map(isWord) == true) { return k }
            k = j
        }
        failedFrom[key] = from
        return -1
    }

    /// Index of needle in the lowercased text, or -1
    func findLowercased(_ needle: String, from: Int) -> Int {
        if lowered == nil { lowered = s.map { $0.lowercased().first ?? $0 } }
        return find(lowered!, needle, from: from) ?? -1
    }
}

private func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
private func isNameStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }

private func isASCIIPunct(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return (33...47).contains(a) || (58...64).contains(a) || (91...96).contains(a) || (123...126).contains(a)
}

/// Whether s[k] (inside the window) is an ASCII word character, i.e. no \b before it
private func isASCIIWord(at s: [Character], _ k: Int, _ lim: Int) -> Bool {
    k < lim && isNameStart(s[k])
}

/// Case-insensitive ASCII prefix check at i
private func hasPrefix(_ s: [Character], _ i: Int, _ p: String) -> Bool {
    var k = i
    for pc in p {
        guard k < s.count, s[k].lowercased() == pc.lowercased() else { return false }
        k += 1
    }
    return true
}

private func find(_ s: [Character], _ needle: String, from: Int) -> Int? {
    let n = Array(needle)
    guard !n.isEmpty, from >= 0 else { return nil }
    var k = from
    while k + n.count <= s.count {
        if s[k] == n[0] && Array(s[k..<(k + n.count)]) == n { return k }
        k += 1
    }
    return nil
}
