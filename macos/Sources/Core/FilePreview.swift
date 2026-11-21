import Foundation

/// How a file opens in a browser tab: WebKit shows media, PDF and HTML itself; text formats are turned into a page
/// here (SQL highlighted, CSV/TSV as a table, JSON as a folding tree, source code in the code reader's colours, anything
/// else as plain text). The pages carry no script. (Windows: entities/terminal/lib/file-preview.ts)
enum FilePreview {
    enum Kind: Equatable { case native, sql, table(Character), json, code(String), text }

    /// Larger text files are cut, so a log or a dump cannot stall the tab
    static let textLimit = 2 * 1024 * 1024
    static let nativeExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "ico", "svg", "html", "htm",
                                                "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac", "ogg", "flac"]

    static func kind(for path: String) -> Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        if nativeExtensions.contains(ext) { return .native }
        switch ext {
        case "sql", "psql", "mysql", "ddl", "dml": return .sql
        case "csv": return .table(",")
        case "tsv", "tab": return .table("\t")
        case "json", "geojson", "jsonc": return .json
        default:
            let language = RepositoryCodeReading.language(for: path)
            return ["Plain text", "Markdown", "HTML", "XML"].contains(language) ? .text : .code(language)
        }
    }

    /// The page for a text file, or nil when the data is not text
    static func page(name: String, data: Data, kind: Kind) -> String? {
        let cut = data.count > textLimit
        guard let text = String(data: cut ? data.prefix(textLimit) : data, encoding: .utf8)
            ?? (cut ? String(decoding: data.prefix(textLimit), as: UTF8.self) : nil) else { return nil }
        if !cut, text.contains("\0") { return nil }
        let body: String
        switch kind {
        case .sql: body = "<pre class=\"code\">" + highlightSQL(text) + "</pre>"
        case .table(let separator): body = table(parseDelimited(text, separator: separator))
        case .json:
            if !cut, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                body = "<div class=\"tree\">" + jsonTree(value, key: nil, depth: 0) + "</div>"
            } else {
                body = "<pre class=\"code\">" + escape(text) + "</pre>"
            }
        case .code(let language): body = "<pre class=\"code\">" + highlightCode(text, language: language) + "</pre>"
        case .native, .text: body = "<pre class=\"code\">" + escape(text) + "</pre>"
        }
        let note = cut ? "<p class=\"note\">" + escape(String(localized: "Only the first 2 MB are shown.")) + "</p>" : ""
        return document(title: name, body: note + body)
    }

    /// Escaped HTML with the code reader's token colours, in the page's own classes (Windows: highlightCode)
    static func highlightCode(_ text: String, language: String) -> String {
        let source = text as NSString
        var out = "", at = 0
        for token in RepositoryCodeReading.tokens(in: text, language: language) where token.range.location >= at {
            out += escape(source.substring(with: NSRange(location: at, length: token.range.location - at)))
            let cls: String
            switch token.kind { case .comment: cls = "comment"; case .string: cls = "string"; case .keyword: cls = "keyword"; case .number: cls = "number" }
            out += "<span class=\"\(cls)\">" + escape(source.substring(with: token.range)) + "</span>"
            at = NSMaxRange(token.range)
        }
        return out + escape(source.substring(from: at))
    }

    // MARK: - SQL

    static let sqlKeywords: Set<String> = [
        "add", "all", "alter", "and", "as", "asc", "autoincrement", "begin", "between", "by", "cascade", "case", "check", "commit",
        "constraint", "create", "cross", "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists",
        "foreign", "from", "full", "grant", "group", "having", "if", "in", "index", "inner", "insert", "into", "is", "join", "key",
        "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer", "primary", "references", "returning",
        "revoke", "right", "rollback", "select", "set", "table", "then", "transaction", "trigger", "truncate", "union", "unique",
        "update", "using", "values", "view", "when", "where", "with",
    ]
    static let sqlTypes: Set<String> = [
        "bigint", "blob", "boolean", "char", "date", "datetime", "decimal", "double", "float", "int", "integer", "json", "jsonb",
        "numeric", "real", "serial", "smallint", "text", "time", "timestamp", "timestamptz", "uuid", "varchar",
    ]

    /// Escaped HTML with spans for comments, strings, numbers, keywords and types
    static func highlightSQL(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        func span(_ cls: String, _ s: String) { out += "<span class=\"\(cls)\">" + escape(s) + "</span>" }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "-" && next == "-" {
                var j = i
                while j < chars.count && chars[j] != "\n" { j += 1 }
                span("comment", String(chars[i..<j])); i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < chars.count && !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(chars.count, j + 2)
                span("comment", String(chars[i..<j])); i = j
            } else if c == "'" || c == "\"" || c == "`" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == c { if j + 1 < chars.count && chars[j + 1] == c { j += 2; continue }; j += 1; break }
                    j += 1
                }
                span(c == "'" ? "string" : "ident", String(chars[i..<min(j, chars.count)])); i = j
            } else if c.isNumber && (i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_")) {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == ".") { j += 1 }
                span("number", String(chars[i..<j])); i = j
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                let lower = word.lowercased()
                if sqlKeywords.contains(lower) { span("keyword", word) } else if sqlTypes.contains(lower) { span("type", word) } else { out += escape(word) }
                i = j
            } else {
                out += escape(String(c)); i += 1
            }
        }
        return out
    }

    // MARK: - CSV / TSV

    /// RFC 4180 rows: quoted fields may hold the separator, doubled quotes and line breaks
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""; rows.append(row); row = []
            } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static let tableRowLimit = 5000

    static func table(_ rows: [[String]]) -> String {
        guard let head = rows.first else { return "<p class=\"note\">" + escape(String(localized: "The file is empty.")) + "</p>" }
        let width = rows.map(\.count).max() ?? 0
        var html = "<p class=\"note\">" + escape(String(localized: "\(rows.count - 1) rows · \(width) columns")) + "</p><table><thead><tr><th class=\"n\"></th>"
        for i in 0..<width { html += "<th>" + escape(i < head.count ? head[i] : "") + "</th>" }
        html += "</tr></thead><tbody>"
        for (n, row) in rows.dropFirst().prefix(tableRowLimit).enumerated() {
            html += "<tr><td class=\"n\">\(n + 1)</td>"
            for i in 0..<width { html += "<td>" + escape(i < row.count ? row[i] : "") + "</td>" }
            html += "</tr>"
        }
        return html + "</tbody></table>"
    }

    // MARK: - JSON

    static func jsonTree(_ value: Any, key: String?, depth: Int) -> String {
        let label = key.map { "<span class=\"key\">" + escape($0) + "</span>: " } ?? ""
        if let dict = value as? [String: Any] {
            let items = dict.keys.sorted().map { jsonTree(dict[$0]!, key: $0, depth: depth + 1) }.joined()
            return "<details\(depth < 2 ? " open" : "")><summary>\(label)<span class=\"punct\">{</span> <span class=\"count\">\(dict.count)</span> <span class=\"punct\">}</span></summary>\(items)</details>"
        }
        if let array = value as? [Any] {
            let items = array.enumerated().map { jsonTree($1, key: String($0), depth: depth + 1) }.joined()
            return "<details\(depth < 2 ? " open" : "")><summary>\(label)<span class=\"punct\">[</span> <span class=\"count\">\(array.count)</span> <span class=\"punct\">]</span></summary>\(items)</details>"
        }
        let leaf: String
        if value is NSNull { leaf = "<span class=\"keyword\">null</span>" }
        else if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { leaf = "<span class=\"keyword\">\(n.boolValue)</span>" }
        else if let n = value as? NSNumber { leaf = "<span class=\"number\">\(n)</span>" }
        else { leaf = "<span class=\"string\">\"" + escape("\(value)") + "\"</span>" }
        return "<div class=\"leaf\">\(label)\(leaf)</div>"
    }

    // MARK: - Page

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    static func document(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escape(title))</title><style>
        :root { color-scheme: light dark; --fg: #1d1d1f; --bg: #fff; --muted: #6e6e73; --line: #e5e5ea; --head: #f5f5f7;
          --kw: #9b2393; --type: #0b4f79; --str: #c41a16; --num: #1c00cf; --com: #5d6c79; --key: #0e6e8c; }
        @media (prefers-color-scheme: dark) { :root { --fg: #e6e6e6; --bg: #1e1e1e; --muted: #98989d; --line: #38383a; --head: #2a2a2c;
          --kw: #fc5fa3; --type: #5dd8ff; --str: #fc6a5d; --num: #d0bf69; --com: #7f8c98; --key: #67b7a4; } }
        body { margin: 0; padding: 16px 20px; background: var(--bg); color: var(--fg); font: 13px -apple-system, "Segoe UI", sans-serif; }
        pre, .tree, table { font: 12px ui-monospace, "SF Mono", Menlo, Consolas, monospace; }
        pre { margin: 0; white-space: pre-wrap; word-break: break-word; line-height: 1.5; }
        .keyword { color: var(--kw); font-weight: 600; } .type { color: var(--type); } .string { color: var(--str); }
        .number { color: var(--num); } .comment { color: var(--com); font-style: italic; } .ident, .key { color: var(--key); }
        .note, .count, .punct { color: var(--muted); } .note { margin: 0 0 10px; font-size: 12px; }
        table { border-collapse: collapse; } th, td { border: 1px solid var(--line); padding: 4px 8px; text-align: left; vertical-align: top; white-space: pre-wrap; }
        th { position: sticky; top: 0; background: var(--head); font-weight: 600; } td.n, th.n { color: var(--muted); text-align: right; }
        tbody tr:hover { background: var(--head); }
        .tree details > :not(summary), .tree .leaf { margin-left: 18px; } .tree summary { cursor: default; line-height: 1.6; } .tree .leaf { line-height: 1.6; }
        </style></head><body>\(body)</body></html>
        """
    }
}
