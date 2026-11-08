import Foundation

/// What the Code page's History, Blame and Working changes views ask Git for, and the rules they share. Reading only:
/// nothing here changes the repository. (Windows: widgets/local-workbench/lib/code-history.ts)
enum RepositoryCodeHistory {
    /// The History list shows this many commits; one more is read to know that there are more
    static let limit = 200
    /// Blame reads this many lines at most, so a generated file cannot stall the page
    static let blameLimit = 5000

    /// The commits that changed a file, following renames, newest first
    static func logArgs(revision: String, path: String, format: String) -> [String] {
        ["log", "--follow", "-M", "--name-only", "-z", "-n", String(limit + 1), "--format=" + format, revision, "--", path]
    }

    /// The commits of a revision that are on no remote yet
    static func localArgs(revision: String) -> [String] {
        ["rev-list", "-n", "1000", revision, "--not", "--remotes", "--"]
    }

    /// One commit's change to a file against its first parent; a root commit shows the file as added
    static func changeArgs(commit: String, path: String, ignoreWhitespace: Bool) -> [String] {
        ["show", "--format=", "--no-ext-diff", "--no-textconv", "-M", "-m", "--first-parent"] + (ignoreWhitespace ? ["-w"] : []) + [commit, "--", path]
    }

    /// The working tree's change to a file against HEAD
    static func workingArgs(path: String, ignoreWhitespace: Bool) -> [String] {
        ["diff", "--no-ext-diff", "--no-textconv"] + (ignoreWhitespace ? ["-w"] : []) + ["HEAD", "--", path]
    }

    static func blameArgs(revision: String, path: String, lines: Int) -> [String] {
        ["blame", "--porcelain", "-L", "1,\(max(1, min(blameLimit, lines)))", revision, "--", path]
    }

    /// The file as a commit has it, for the unchanged lines a diff leaves out
    static func fileArgs(commit: String, path: String) -> [String] {
        ["cat-file", "blob", commit + ":" + path]
    }

    /// The History tab's count: "8", or "200+" when the list stops at the limit
    static func countLabel(_ count: Int) -> String {
        count > limit ? "\(limit)+" : String(count)
    }

    /// A folder shortened from its start by whole segments ("…/Views/Search"), and nothing when even its last
    /// segment does not fit (docs/design.md, Text)
    static func shortFolder(_ folder: String, limit: Int = 20) -> String {
        if folder.count <= limit { return folder }
        var parts = folder.split(separator: "/")
        while !parts.isEmpty {
            parts.removeFirst()
            let short = "…/" + parts.joined(separator: "/")
            if !parts.isEmpty && short.count <= limit { return short }
        }
        return ""
    }

    /// The name beside the short hash on the revision button: the branch for HEAD, what was typed otherwise, and
    /// nothing when a hash was typed
    static func revisionName(input: String, revision: String, branch: String?) -> String? {
        if input == "HEAD" { return branch }
        return revision.lowercased().hasPrefix(input.lowercased()) ? nil : input
    }

    /// A text's lines as a diff shows them: split at LF only, without the line endings, tabs as four spaces
    static func lines(_ text: String) -> [String] {
        var parts = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
        if parts.last == "" { parts.removeLast() }
        return parts.map { ($0.hasSuffix("\r") ? String($0.dropLast()) : $0).replacingOccurrences(of: "\t", with: "    ") }
    }

    struct Hunk: Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    /// Unchanged lines a diff leaves out: `count` lines from `oldStart` and `newStart`, before hunk `hunk`
    /// (the number of hunks for the lines after the last one)
    struct Gap: Equatable {
        let hunk: Int
        let oldStart: Int
        let newStart: Int
        let count: Int
    }

    static func gaps(_ hunks: [Hunk], lineCount: Int) -> [Gap] {
        var result: [Gap] = [], old = 1, new = 1
        for (index, hunk) in hunks.enumerated() {
            // a hunk with no lines on one side names the line before it
            let firstOld = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
            let firstNew = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
            if firstNew > new { result.append(Gap(hunk: index, oldStart: old, newStart: new, count: firstNew - new)) }
            old = firstOld + hunk.oldCount
            new = firstNew + hunk.newCount
        }
        if lineCount >= new { result.append(Gap(hunk: hunks.count, oldStart: old, newStart: new, count: lineCount - new + 1)) }
        return result
    }

    /// Where "Blame before this change" goes: the commit's first parent, and the file's name in the next older
    /// commit of its history. Nothing when the list has no older commit: the file starts there, or the list stops
    /// before it.
    static func before(_ commit: String, in history: [(id: String, parent: String?, path: String)]) -> (revision: String, path: String)? {
        guard let index = history.firstIndex(where: { $0.id == commit }), index + 1 < history.count,
              let parent = history[index].parent else { return nil }
        return (parent, history[index + 1].path)
    }
}
