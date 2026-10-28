import Foundation

/// Lightweight reading metadata; all ranges use UTF-16 for AppKit text storage.
enum RepositoryCodeReading {
    struct Token: Equatable {
        enum Kind: Equatable { case comment, string, keyword, number }
        let range: NSRange
        let kind: Kind
    }

    static func language(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["swift": "Swift", "ts": "TypeScript", "tsx": "TSX", "js": "JavaScript", "jsx": "JSX",
                "rs": "Rust", "py": "Python", "go": "Go", "json": "JSON", "md": "Markdown", "markdown": "Markdown",
                "yml": "YAML", "yaml": "YAML", "sh": "Shell", "bash": "Shell", "zsh": "Shell", "css": "CSS",
                "html": "HTML", "xml": "XML", "c": "C", "h": "C", "cpp": "C++", "hpp": "C++",
                "cs": "C#", "java": "Java", "kt": "Kotlin", "toml": "TOML", "sql": "SQL"][ext] ?? "Plain text"
    }

    static func lineStarts(in text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        let units = Array(text.utf16)
        var starts = [0]
        for index in units.indices where units[index] == 10 && index + 1 < units.count { starts.append(index + 1) }
        return starts
    }

    static func matches(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = [], location = 0
        while location < source.length {
            if Task.isCancelled { return [] }
            let range = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: location, length: source.length - location))
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range)
            if result.count > 10_000 { break }
            location = NSMaxRange(range)
        }
        return result
    }

    static func tokens(in text: String, path: String) -> [Token] {
        // Large previews stay selectable and searchable without a costly styling pass.
        guard text.utf16.count <= 200_000, language(for: path) != "Plain text" else { return [] }
        let hashComments = ["Python", "Shell", "YAML", "TOML"].contains(language(for: path))
        let comments = hashComments ? #"#[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?\*/"#
        let keywords = #"\b(?:actor|as|async|await|break|case|catch|class|const|continue|def|default|defer|do|else|enum|export|extends|false|final|fn|for|from|func|function|guard|if|impl|import|in|init|interface|internal|is|let|match|mut|namespace|new|nil|null|None|open|override|package|private|protected|protocol|pub|public|return|self|static|struct|super|switch|this|throw|throws|trait|true|try|type|typeof|use|var|void|where|while|with|yield)\b"#
        let pattern = "(" + comments + #")|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|("# + keywords + #")|(\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?)\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [Token] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            guard let match else { return }
            let kinds: [Token.Kind] = [.comment, .string, .keyword, .number]
            for (index, kind) in kinds.enumerated() where match.range(at: index + 1).location != NSNotFound {
                result.append(Token(range: match.range, kind: kind)); break
            }
            if result.count >= 12_000 || Task.isCancelled { stop.pointee = true }
        }
        return result
    }
}
