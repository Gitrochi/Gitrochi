import Foundation

/// Session navigation stays tied to one immutable repository tree.
struct RepositoryCodeNavigation {
    struct Location: Equatable { let path: String; let mode: String }
    private(set) var tabs: [String] = []
    private(set) var tabModes: [String: String] = [:]
    private(set) var recent: [String] = []
    private(set) var history: [Location] = []
    private(set) var index = -1
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index + 1 < history.count }

    mutating func visit(_ path: String, mode: String, record: Bool = true) {
        if !tabs.contains(path) {
            tabs.append(path)
            if tabs.count > 12 { tabModes.removeValue(forKey: tabs.removeFirst()) }
        }
        tabModes[path] = mode
        recent.removeAll { $0 == path }; recent.insert(path, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        let location = Location(path: path, mode: mode)
        guard record, !history.indices.contains(index) || history[index] != location else { return }
        history = Array(history.prefix(index + 1)); history.append(location)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        index = history.count - 1
    }

    mutating func move(_ delta: Int) -> Location? {
        let target = index + delta
        guard history.indices.contains(target) else { return nil }
        index = target
        return history[target]
    }

    mutating func close(_ path: String, selected: String?) -> String? {
        guard let tab = tabs.firstIndex(of: path) else { return selected }
        tabs.remove(at: tab)
        tabModes.removeValue(forKey: path)
        guard selected == path else { return selected }
        return tabs.isEmpty ? nil : tabs[min(tab, tabs.count - 1)]
    }

    mutating func closeAll() { tabs = []; tabModes = [:] }

    static func rankedPaths(_ paths: [String], query: String, recent: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            let available = Set(paths)
            return Array(recent.filter { available.contains($0) }.prefix(50))
        }
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        let results: [(String, Int)] = paths.compactMap { path in
            let lower = path.lowercased(), name = (lower as NSString).lastPathComponent
            let rank: Int
            if name == needle { rank = 0 }
            else if name.hasPrefix(needle) { rank = 10 }
            else if name.contains(needle) { rank = 20 }
            else if lower.contains(needle) { rank = 30 }
            else if words.allSatisfy({ lower.contains($0) }) { rank = 40 }
            else { return nil }
            return (path, rank)
        }
        return Array(results.sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            if left.0.count != right.0.count { return left.0.count < right.0.count }
            return left.0 < right.0
        }.prefix(50).map(\.0))
    }
}

extension RepositoryCodeReading {
    struct Symbol: Identifiable, Equatable {
        let name: String
        let line: Int
        let kind: String
        var id: Int { line }
    }

    static func validLine(_ input: String, count: Int) -> Int? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let line = Int(value), line >= 1, line <= count else { return nil }
        return line
    }

    static func lineRange(_ number: Int, starts: [Int], length: Int) -> NSRange? {
        guard number >= 1, number <= starts.count else { return nil }
        let start = starts[number - 1], end = number < starts.count ? starts[number] : length
        return NSRange(location: start, length: max(0, end - start))
    }

    static func outline(in text: String, path: String) -> [Symbol] {
        let markdown = language(for: path) == "Markdown"
        let modifiers = #"(?:(?:public|private|protected|internal|open|final|static|class|override|async|export|default|declare|abstract|pub|unsafe|nonisolated|mutating)\s+)*"#
        let patterns = markdown ? [#"^(#{1,6})\s+(.+?)\s*#*\s*$"#] : [
            "^" + modifiers + #"(func|function|fn|def)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#,
            "^" + modifiers + #"(class|struct|enum|protocol|interface|type|trait|actor|extension|impl)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#,
            #"^func\s+\([^)]*\)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#,
            #"^(?:export\s+)?(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*(?::[^=]+)?=\s*(?:async\s*)?(?:\([^)]*\)|[\p{L}_$][\p{L}\p{N}_$]*)\s*=>"#
        ]
        let expressions = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        let hashComments = ["Python", "Shell", "YAML", "TOML"].contains(language(for: path))
        var result: [Symbol] = [], lineNumber = 0, blockComment = false, fence: (Character, Int)?, quote: UInt16?, tripleQuote = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            if Task.isCancelled || result.count >= 200 { break }
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if markdown {
                if let marker = line.first, marker == "`" || marker == "~" {
                    let run = line.prefix { $0 == marker }.count
                    if let opened = fence {
                        if marker == opened.0, run >= opened.1, line.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else if run >= 3 { fence = (marker, run) }
                    if run >= 3 { continue }
                }
                if fence != nil { continue }
            } else {
                let units = Array(raw.utf16)
                var code = Array(repeating: UInt16(32), count: units.count), cursor = 0
                while cursor < units.count {
                    let value = units[cursor], next = cursor + 1 < units.count ? units[cursor + 1] : 0
                    if blockComment {
                        if value == 42 && next == 47 { blockComment = false; cursor += 2 } else { cursor += 1 }
                        continue
                    }
                    if let delimiter = quote {
                        if value == 92 { cursor += min(2, units.count - cursor); continue }
                        if tripleQuote {
                            if value == delimiter, next == delimiter, cursor + 2 < units.count, units[cursor + 2] == delimiter { quote = nil; tripleQuote = false; cursor += 3 }
                            else { cursor += 1 }
                        } else {
                            if value == delimiter { quote = nil }
                            cursor += 1
                        }
                        continue
                    }
                    if value == 47 && next == 42 { blockComment = true; cursor += 2; continue }
                    if value == 47 && next == 47 || hashComments && value == 35 { break }
                    if value == 34 || value == 39 || value == 96 {
                        quote = value
                        tripleQuote = value != 96 && next == value && cursor + 2 < units.count && units[cursor + 2] == value
                        cursor += tripleQuote ? 3 : 1
                        continue
                    }
                    code[cursor] = value
                    cursor += 1
                }
                if quote != 96 && !tripleQuote { quote = nil }
                line = String(decoding: code, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard line.utf16.count <= 2000 else { continue }
            for (index, expression) in expressions.enumerated() {
                guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { continue }
                let group = markdown || index < 2 ? 2 : 1
                let name = (line as NSString).substring(with: match.range(at: group))
                let kind = markdown ? "heading" : index == 1 ? "type" : "function"
                result.append(Symbol(name: name, line: lineNumber, kind: kind))
                break
            }
        }
        return result
    }
}
