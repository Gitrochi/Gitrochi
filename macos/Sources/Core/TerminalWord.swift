import Foundation

/// What a ⌘-click in a terminal points at. (Windows: entities/terminal/lib/terminal-word.ts)
enum TerminalWord {
    /// Characters that end a word: spaces, quotes and brackets around a path in tool output
    static let boundaries = Set(" \t\"'`()[]{}<>|,;")

    /// Cells a tab skipped over hold NUL rather than a space (ls lines its columns up with tabs)
    static func ends(_ c: Character) -> Bool {
        boundaries.contains(c) || c.isWhitespace || c.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The word that runs through the clicked cell, given the line's text before and from that cell
    static func around(before: String, after: String) -> String? {
        let head = String(before.reversed().prefix { !ends($0) }.reversed())
        let tail = String(after.prefix { !ends($0) })
        guard !tail.isEmpty else { return nil }
        // a sentence's full stop or a trailing colon is not part of the path
        var word = head + tail
        while let last = word.last, ".:".contains(last) { word.removeLast() }
        return word.isEmpty ? nil : word
    }

    /// Characters a path with spaces never runs across: quotes, pipes and redirections, tabs and control cells
    static func stopsSpan(_ c: Character) -> Bool {
        "\"'`<>|\t".contains(c) || c.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// Paths with spaces through the clicked cell, longest first: from the nearest rooted start (`/`, `~/`, `./`,
    /// `../`) before the cell, across single spaces, to each word end after it. As in Ghostty, a space before another
    /// rooted start ends the path, and the caller opens the first candidate that exists, so `/a/Plan (1 1~1 7).xlsx`
    /// is found while `/a/x.txt /b/y.txt` stays two paths. (Windows: spacedPaths in terminal-word.ts)
    static func spanned(before: String, after: String, limit: Int = 16) -> [String] {
        let line = Array(before + after), click = before.count
        guard click < line.count, !stopsSpan(line[click]) else { return [] }
        func rooted(_ i: Int) -> Bool {
            guard i < line.count, i == 0 || ends(line[i - 1]) else { return false }
            let rest = String(line[i..<min(line.count, i + 3)])
            return (rest.hasPrefix("/") && !rest.hasPrefix("//")) || rest.hasPrefix("~/") || rest.hasPrefix("./") || rest.hasPrefix("../")
        }
        // a space ends the path when another space or a rooted start follows it
        func breaks(_ i: Int) -> Bool { stopsSpan(line[i]) || (line[i] == " " && (i + 1 == line.count || line[i + 1] == " " || rooted(i + 1))) }
        var start = click
        while start >= 0, !rooted(start) {
            if start < click, breaks(start) { return [] }
            start -= 1
        }
        guard start >= 0 else { return [] }
        var out: [String] = []
        var end = click + 1
        while end <= line.count, out.count < limit {
            if end == line.count || ends(line[end]) {
                var word = String(line[start..<end])
                while let last = word.last, ".:,;".contains(last) { word.removeLast() }
                if word.contains(" "), !out.contains(word) { out.append(word) }
            }
            if end == line.count || breaks(end) { break }
            end += 1
        }
        return out.reversed()
    }

    /// The file a word names, from the shell's folder: `~` expanded, a `:line[:column]` suffix dropped, git's
    /// `a/` and `b/` diff prefixes tried. nil when no such file exists.
    static func file(_ word: String, in directory: String, exists: (String) -> Bool) -> String? {
        var candidates = [word]
        if let range = word.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) { candidates.append(String(word[..<range.lowerBound])) }
        if word.hasPrefix("a/") || word.hasPrefix("b/") { candidates.append(String(word.dropFirst(2))) }
        if word.hasPrefix("file://"), let url = URL(string: word) { candidates = [url.path] }
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
            let clean = (path as NSString).standardizingPath
            if exists(clean) { return clean }
        }
        return nil
    }

    /// Folders a search below the shell's folder never enters
    static let skippedFolders: Set<String> = ["node_modules", "build", "dist", "target", "Pods", "DerivedData", "vendor", "__pycache__"]

    /// A name the shell's folder does not hold directly, such as `schema.sql` printed by `ls sub/`: the shallowest file
    /// below the folder whose path ends with it. Hidden and build folders are skipped, and the walk stops early.
    static func search(_ word: String, in directory: String, maxDepth: Int = 6, maxEntries: Int = 50_000) -> String? {
        var name = word
        if let range = name.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) { name = String(name[..<range.lowerBound]) }
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), name.contains(".") || name.contains("/") else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let suffix = "/" + name
        var best: (path: String, depth: Int)?
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen > maxEntries { break }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isFolder {
                if skippedFolders.contains(url.lastPathComponent) || walk.level >= maxDepth { walk.skipDescendants() }
                continue
            }
            let path = url.path
            guard path.hasSuffix(suffix) else { continue }
            if best == nil || walk.level < best!.depth { best = (path, walk.level) }
            if walk.level <= 1 { break }
        }
        return best?.path
    }
}
