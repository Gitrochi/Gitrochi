import Foundation

/// GitHub-flavored Markdown for PR/MR text and commit bodies, parsed into a tree the views draw directly.
/// Raw HTML is never rendered, and only http(s)/mailto links survive. (Windows: shared/lib/markdown.ts)
enum Markdown {
    indirect enum Inline: Hashable {
        case text(String)
        case strong([Inline])
        case em([Inline])
        case strike([Inline])
        case code(String)
        case link(href: String, children: [Inline])
        case image(src: String, alt: String)
        case lineBreak
    }

    enum Align: Hashable { case left, center, right }

    struct ListItem: Hashable {
        /// nil = not a task item
        let task: Bool?
        let blocks: [Block]
    }

    indirect enum Block: Hashable {
        case paragraph([Inline])
        case heading(level: Int, [Inline])
        case code(lang: String, text: String)
        case quote([Block])
        case list(ordered: Bool, start: Int, items: [ListItem])
        case table(align: [Align?], head: [[Inline]], rows: [[[Inline]]])
        case details(summary: [Inline], blocks: [Block])
        case rule
    }

    /// Where #123, !123 (GitLab) and @name point
    struct Refs {
        let issue: (String) -> String
        var request: ((String) -> String)?
        let user: (String) -> String
    }

    static func parse(_ text: String, refs: Refs? = nil, baseURL: URL? = nil, imageBaseURL: URL? = nil) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                let tabs = line.prefix { $0 == "\t" }.count
                return String(repeating: " ", count: tabs * 4) + line.dropFirst(tabs)
            }
        return blocks(lines, Context(refs: refs, baseURL: baseURL, imageBaseURL: imageBaseURL))
    }

    static func safeURL(_ href: String) -> String? {
        resolvedURL(href, baseURL: nil, allowMail: true)?.absoluteString
    }
}

/// URL resolution is shared by all inline contexts, including nested links and table cells.
extension Markdown {
    struct Context {
        var refs: Refs? = nil
        var baseURL: URL? = nil
        var imageBaseURL: URL? = nil

        func link(_ href: String) -> String? {
            resolvedURL(href, baseURL: baseURL, allowMail: true)?.absoluteString
        }

        func markerImage(_ href: String) -> String? {
            guard let url = URL(string: href),
                  ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "tif", "tiff", "bmp", "svg"].contains(url.pathExtension.lowercased()) else { return nil }
            return image(href)
        }

        func image(_ href: String) -> String? {
            guard let url = URL(string: href.trimmed) else { return nil }
            var resolutionBase = baseURL
            let value = url.relativeString
            if url.scheme == nil, let imageBaseURL {
                if value.hasPrefix("/uploads/") || value.hasPrefix("uploads/"),
                   let range = imageBaseURL.absoluteString.range(of: "/-/raw/") {
                    let project = URL(string: String(imageBaseURL.absoluteString[..<range.lowerBound]) + "/")
                    let relative = value.hasPrefix("/") ? String(value.dropFirst()) : value
                    return resolvedURL(relative, baseURL: project, allowMail: false)?.absoluteString
                }
                if !value.hasPrefix("/"), !value.contains("blob/"), !value.contains("raw/") {
                    resolutionBase = imageBaseURL
                }
            }
            guard let safe = resolvedURL(value, baseURL: resolutionBase, allowMail: false),
                  var components = URLComponents(url: safe, resolvingAgainstBaseURL: true) else { return nil }
            if components.percentEncodedPath.contains("/-/blob/") {
                components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(of: "/-/blob/", with: "/-/raw/")
            } else if safe.host == "github.com" || safe.host == baseURL?.host && baseURL?.path.contains("/pull/") == true {
                let parts = components.percentEncodedPath.split(separator: "/")
                if parts.count >= 4, parts[2] == "blob" {
                    components.percentEncodedPath = "/" + (parts.prefix(2) + ["raw"] + parts.dropFirst(3)).joined(separator: "/")
                }
            }
            return components.url?.absoluteString
        }
    }

    static func resolvedURL(_ href: String, baseURL: URL?, allowMail: Bool) -> URL? {
        guard let url = URL(string: href.trimmed),
              let resolved = (url.scheme == nil ? URL(string: url.relativeString, relativeTo: baseURL) : url)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            return resolved.host?.isEmpty == false && resolved.user == nil && resolved.password == nil ? resolved : nil
        }
        return allowMail && scheme == "mailto" ? resolved : nil
    }

    /// Relative images point at the reviewed head, while page links retain their PR/MR location.
    static func repositoryImageBaseURL(webURL: URL?, revision: String?) -> URL? {
        guard let webURL, let revision, !revision.isEmpty,
              var components = URLComponents(url: webURL, resolvingAgainstBaseURL: true),
              resolvedURL(webURL.absoluteString, baseURL: nil, allowMail: false) != nil else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        let prefix: [String]
        let marker: [String]
        if let index = parts.firstIndex(of: "-"), parts.dropFirst(index + 1).first == "merge_requests" {
            prefix = Array(parts[..<index]); marker = ["-", "raw"]
        } else if let index = parts.firstIndex(of: "pull"), index == 2 {
            prefix = Array(parts[..<index]); marker = ["raw"]
        } else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let ref = revision.addingPercentEncoding(withAllowedCharacters: allowed) ?? revision
        components.percentEncodedPath = "/" + (prefix + marker).joined(separator: "/") + "/" + ref + "/"
        components.query = nil; components.fragment = nil
        return components.url
    }
}

// MARK: - Blocks

private extension Markdown {
    static func isBlank(_ l: String) -> Bool { l.allSatisfy { $0 == " " || $0 == "\t" } }
    static func indent(_ l: String) -> Int { l.prefix { $0.isWhitespace }.count }
    static func dedent(_ l: String, _ n: Int) -> String { String(l.dropFirst(min(n, indent(l)))) }

    /// The line after up to three spaces of indentation, or nil if indented further
    static func lead(_ l: String) -> Substring? {
        let n = l.prefix { $0 == " " }.count
        return n <= 3 ? l.dropFirst(n) : nil
    }

    struct Fence { let indent: Int; let char: Character; let count: Int; let info: String }

    static func fence(_ l: String) -> Fence? {
        guard let r = lead(l), let c = r.first, c == "`" || c == "~" else { return nil }
        let count = r.prefix { $0 == c }.count
        guard count >= 3 else { return nil }
        let info = r.dropFirst(count)
        if c == "`" && info.contains("`") { return nil }
        return Fence(indent: l.count - r.count, char: c, count: count, info: String(info).trimmed)
    }

    static func closes(_ l: String, _ f: Fence) -> Bool {
        guard let r = lead(l), r.first == f.char else { return false }
        let count = r.prefix { $0 == f.char }.count
        return count >= f.count && r.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func heading(_ l: String) -> (Int, String)? {
        guard let r = lead(l) else { return nil }
        let level = r.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = r.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var s = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        // closing #s count only after a space; a line of only #s is empty
        if let k = s.lastIndex(where: { $0 != "#" }) {
            if (s[k] == " " || s[k] == "\t") && s.index(after: k) < s.endIndex {
                s = String(s[...k]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            }
        } else {
            s = ""
        }
        return (level, s)
    }

    static func isRule(_ l: String) -> Bool {
        guard let r = lead(l), let c = r.first, "-*_".contains(c) else { return false }
        var n = 0
        for ch in r {
            if ch == c { n += 1 } else if ch != " " && ch != "\t" { return false }
        }
        return n >= 3
    }

    static func quoteBody(_ l: String) -> String? {
        guard let r = lead(l), r.first == ">" else { return nil }
        let rest = r.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    static func setext(_ l: String) -> Int? {
        guard let r = lead(l), let c = r.first, c == "=" || c == "-" else { return nil }
        let run = r.prefix { $0 == c }.count
        return r.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) ? (c == "=" ? 1 : 2) : nil
    }

    static func opensDetails(_ l: String) -> Bool {
        guard let r = lead(l), r.lowercased().hasPrefix("<details") else { return false }
        let after = r.dropFirst(8)
        guard let f = after.first else { return false }
        return f == ">" || (f.isWhitespace && after.contains(">"))
    }

    static func opensComment(_ l: String) -> Bool { lead(l)?.hasPrefix("<!--") ?? false }

    struct Marker { let ordered: Bool; let delim: Character; let start: Int; let contentIndent: Int; let rest: String }

    static func marker(_ l: String) -> Marker? {
        guard let r = lead(l), let c = r.first else { return nil }
        var ordered = false, delim = c, start = 1, width = 1
        if !"-+*".contains(c) {
            let digits = r.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let d = r.dropFirst(digits.count).first, d == "." || d == ")" else { return nil }
            ordered = true
            delim = d
            start = Int(digits) ?? 1
            width = digits.count + 1
        }
        let after = r.dropFirst(width)
        let spaces = after.prefix { $0 == " " || $0 == "\t" }.count
        guard spaces > 0 || after.isEmpty else { return nil }
        let content = after.dropFirst(spaces)
        // 5+ spaces after the marker means indented code inside the item
        let gap = spaces == 0 || spaces > 4 ? 1 : spaces
        let rest = spaces > 4 ? String(repeating: " ", count: spaces - 1) + content : String(content)
        return Marker(ordered: ordered, delim: delim, start: start, contentIndent: l.count - r.count + width + gap, rest: rest)
    }

    static func startsBlock(_ l: String) -> Bool {
        fence(l) != nil || heading(l) != nil || isRule(l) || quoteBody(l) != nil || marker(l) != nil || opensDetails(l) || opensComment(l)
    }

    /// Only non-empty bullets and lists starting at 1 may cut a paragraph short
    static func interruptsParagraph(_ l: String) -> Bool {
        if fence(l) != nil || heading(l) != nil || isRule(l) || quoteBody(l) != nil || opensDetails(l) || opensComment(l) { return true }
        guard let m = marker(l) else { return false }
        return !m.rest.trimmed.isEmpty && (!m.ordered || m.start == 1)
    }

    /// Table row cells; `\|` is a literal pipe
    static func cells(_ row: String) -> [String] {
        var s = Substring(row.trimmed)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s = s.dropLast() }
        let chars = Array(s)
        var out: [String] = []
        var cur = ""
        var k = 0
        while k < chars.count {
            if chars[k] == "\\" && k + 1 < chars.count && chars[k + 1] == "|" {
                cur.append("|")
                k += 1
            } else if chars[k] == "|" {
                out.append(cur.trimmed)
                cur = ""
            } else {
                cur.append(chars[k])
            }
            k += 1
        }
        out.append(cur.trimmed)
        return out
    }

    static func isDelimRow(_ l: String) -> Bool {
        guard l.contains("|"), lead(l) != nil else { return false }
        return cells(l).allSatisfy { c in
            var x = Substring(c)
            if x.first == ":" { x = x.dropFirst() }
            if x.last == ":" { x = x.dropLast() }
            return !x.isEmpty && x.allSatisfy { $0 == "-" }
        }
    }

    static func startsTable(_ lines: [String], _ i: Int) -> Bool {
        lines[i].contains("|") && i + 1 < lines.count && isDelimRow(lines[i + 1]) && cells(lines[i]).count == cells(lines[i + 1]).count
    }

    static func blocks(_ source: [String], _ context: Context) -> [Block] {
        var lines = source
        var out: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }
            if indent(line) >= 4 {
                var body: [String] = []
                while i < lines.count && (isBlank(lines[i]) || indent(lines[i]) >= 4) {
                    body.append(dedent(lines[i], 4))
                    i += 1
                }
                while let last = body.last, isBlank(last) { body.removeLast() }
                out.append(.code(lang: "", text: body.joined(separator: "\n")))
                continue
            }
            if let f = fence(line) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if closes(lines[i], f) {
                        i += 1
                        break
                    }
                    body.append(dedent(lines[i], f.indent))
                    i += 1
                }
                let lang = f.info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                out.append(.code(lang: lang, text: body.joined(separator: "\n")))
                continue
            }
            if opensComment(line) {
                var j = i
                while j < lines.count && !lines[j].contains("-->") { j += 1 }
                let after = j < lines.count ? String(lines[j][lines[j].range(of: "-->")!.upperBound...]) : ""
                if isBlank(after) {
                    i = j + 1
                } else {
                    lines[j] = after
                    i = j
                }
                continue
            }
            if opensDetails(line) {
                i = details(lines, i, &out, context)
                continue
            }
            if let h = heading(line) {
                out.append(.heading(level: h.0, inlines(h.1, context)))
                i += 1
                continue
            }
            if isRule(line) {
                out.append(.rule)
                i += 1
                continue
            }
            if quoteBody(line) != nil {
                var body: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if let q = quoteBody(l) {
                        body.append(q)
                    } else if !isBlank(l), let last = body.last, !isBlank(last), !startsBlock(l) {
                        body.append(l)
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(.quote(blocks(body, context)))
                continue
            }
            if let first = marker(line) {
                i = list(lines, i, first, &out, context)
                continue
            }
            if startsTable(lines, i) {
                let align = cells(lines[i + 1]).map { d -> Align? in
                    d.hasPrefix(":") ? (d.hasSuffix(":") ? .center : .left) : (d.hasSuffix(":") ? .right : nil)
                }
                let head = cells(lines[i]).map { inlines($0, context) }
                var rows: [[[Inline]]] = []
                i += 2
                while i < lines.count && !isBlank(lines[i]) && !startsBlock(lines[i]) {
                    let row = cells(lines[i])
                    rows.append(align.indices.map { c in c < row.count ? inlines(row[c], context) : [] })
                    i += 1
                }
                out.append(.table(align: align, head: head, rows: rows))
                continue
            }
            var para = [line.trimmed]
            i += 1
            var level = 0
            while i < lines.count {
                let l = lines[i]
                if isBlank(l) { break }
                if let s = setext(l) {
                    level = s
                    i += 1
                    break
                }
                if interruptsParagraph(l) || startsTable(lines, i) { break }
                para.append(l.trimmed)
                i += 1
            }
            let content = trimBreaks(inlines(para.joined(separator: "\n"), context))
            if level > 0 {
                out.append(.heading(level: level, content))
            } else if !content.isEmpty {
                out.append(.paragraph(content))
            }
        }
        return out
    }

    static func list(_ lines: [String], _ start: Int, _ first: Marker, _ out: inout [Block], _ context: Context) -> Int {
        var i = start
        var items: [ListItem] = []
        while i < lines.count {
            guard let m = marker(lines[i]), m.ordered == first.ordered, m.delim == first.delim, !isRule(lines[i]) else { break }
            var body = [m.rest]
            i += 1
            var blankBefore = m.rest.trimmed.isEmpty
            while i < lines.count {
                let l = lines[i]
                if isBlank(l) {
                    body.append("")
                    blankBefore = true
                } else if indent(l) >= m.contentIndent {
                    body.append(String(l.dropFirst(m.contentIndent)))
                    blankBefore = false
                } else if !blankBefore && !startsBlock(l) {
                    // lazy continuation of the item's paragraph
                    body.append(l.trimmed)
                } else {
                    break
                }
                i += 1
            }
            while let last = body.last, isBlank(last) { body.removeLast() }
            var task: Bool?
            if let f = body.first, f.count >= 3, f.hasPrefix("["), f.dropFirst(2).hasPrefix("]") {
                let mark = f[f.index(after: f.startIndex)]
                let after = f.dropFirst(3)
                if " xX".contains(mark) && (after.isEmpty || after.first == " " || after.first == "\t") {
                    task = mark != " "
                    body[0] = String(after.drop { $0 == " " || $0 == "\t" })
                }
            }
            items.append(ListItem(task: task, blocks: blocks(body, context)))
        }
        out.append(.list(ordered: first.ordered, start: first.start, items: items))
        return i
    }

    static func details(_ lines: [String], _ start: Int, _ out: inout [Block], _ context: Context) -> Int {
        var depth = 0
        var j = start
        while j < lines.count {
            depth += tags(in: lines[j], "details", closing: false).count
            depth -= tags(in: lines[j], "details", closing: true).count
            if depth <= 0 { break }
            j += 1
        }
        var body = lines[start..<min(j + 1, lines.count)].joined(separator: "\n")
        if let open = tags(in: body, "details", closing: false).first { body = String(body[open.upperBound...]) }
        if let close = tags(in: body, "details", closing: true).last { body = String(body[..<close.lowerBound]) }
        var summary: [Inline] = [.text("Details")]
        let lead = body.prefix { $0.isWhitespace }
        if let open = tags(in: body, "summary", closing: false).first, open.lowerBound == lead.endIndex,
           let close = tags(in: String(body[open.upperBound...]), "summary", closing: true).first {
            let rest = String(body[open.upperBound...])
            summary = inlines(String(rest[..<close.lowerBound]).trimmed, context)
            body = String(rest[close.upperBound...])
        }
        out.append(.details(summary: summary, blocks: blocks(body.components(separatedBy: "\n"), context)))
        return j + 1
    }

    /// <name …> or </name> tags, case-insensitive
    static func tags(in s: String, _ name: String, closing: Bool) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = s.startIndex
        let prefix = (closing ? "</" : "<") + name
        while let r = s.range(of: prefix, options: .caseInsensitive, range: from..<s.endIndex) {
            from = r.upperBound
            guard let next = s[r.upperBound...].first else { break }
            if closing {
                let rest = s[r.upperBound...].drop { $0.isWhitespace }
                if rest.first == ">" { found.append(r.lowerBound..<s.index(after: rest.startIndex)) }
            } else if next == ">" {
                found.append(r.lowerBound..<s.index(after: r.upperBound))
            } else if next.isWhitespace, let gt = s[r.upperBound...].firstIndex(of: ">") {
                found.append(r.lowerBound..<s.index(after: gt))
            }
        }
        return found
    }
}
