#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

// 도구 검색 UI 없이 실제 시스템 Git을 사용한다.
enum TestTool { case git }
final class ToolPaths {
    static let shared = ToolPaths()
    func get(_ tool: TestTool) -> String? { nil }
}

@main struct GitCoreTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        for text in ["before\n<<<<<<< HEAD\nmine\n", "<<<<<<< HEAD\nmine\n||||||| base label\nbase", "<<<<<<<not-a-marker\ntext\n"] {
            check(ConflictDocument.parse(text).resolved([:]) == text, "Incomplete conflict changed its source")
        }
        let conflict = ConflictDocument.parse("before\r\n<<<<<<<<<< HEAD\r\nmine\r\n=======\r\n|||||||||| base label\r\nbase\r\n==========\r\ntheirs\r\n>>>>>>>>>> topic\r\nafter\r\n")
        check(conflict.blocks.count == 1, "Custom marker width was not recognized")
        check(conflict.blocks[0].oursLabel == "HEAD" && conflict.blocks[0].theirsLabel == "topic", "Incorrect marker labels")
        check(conflict.blocks[0].base == ["base"], "Missing diff3 base")
        check(conflict.resolved([0: .ours]) == "before\r\nmine\r\n=======\r\nafter\r\n", "Resolution changed source content or CRLF")

        let diff = "diff --git a/f.txt b/f.txt\nold mode 100644\nnew mode 100755\n--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-old\r\n+new\r\n"
        let doc = Parsers.diff(diff)
        check(doc.lines.last?.raw == "new\r", "Last CRLF line lost its carriage return")
        let patch = DiffPatch.build(doc, hunks: [0], lines: nil, reverse: false)!
        check(!patch.contains("old mode ") && !patch.contains("new mode "), "Line staging included a mode change")
        check(!DiffPatch.canEdit(Parsers.diff(diff + diff.replacingOccurrences(of: "f.txt", with: "other.txt"))), "Multiple files became one editable patch")
        check(DiffPatch.canEdit(Parsers.diff("diff --git \"a/a\\tb\" \"b/a\\tb\"\n--- \"a/a\\tb\"\n+++ \"b/a\\tb\"\n@@ -1 +1 @@\n-old\n+new\n")), "Quoted Git path cannot be staged")

        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repo = base.appendingPathComponent("repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let config = base.appendingPathComponent("empty-config")
        try Data().write(to: config)
        let env = ["GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1"]
        @discardableResult func git(_ args: [String], input: String? = nil, extra: [String: String] = [:]) async throws -> GitResult {
            try await Git.run(args, in: repo, input: input, env: env.merging(extra) { _, new in new })
        }
        try await git(["init", "-q"])
        try await git(["config", "user.name", "Fixture"])
        try await git(["config", "user.email", "fixture@example.com"])
        try await git(["config", "core.autocrlf", "false"])
        for path in ["[a].txt", "a.txt"] { try Data("base\n".utf8).write(to: repo.appendingPathComponent(path)) }
        try await git(["add", "--", "[a].txt"])
        let staged = try await git(["diff", "--cached", "--name-only", "-z"])
        check(staged.output == "[a].txt\0", "Git interpreted the selected filename as a wildcard")
        try await git(["add", "-A"])
        try await git(["commit", "-qm", "base"])
        for path in ["[a].txt", "a.txt"] { try Data("changed\n".utf8).write(to: repo.appendingPathComponent(path)) }
        try await git(["restore", "--worktree", "--", "[a].txt"])
        let selected = try String(contentsOf: repo.appendingPathComponent("[a].txt"), encoding: .utf8)
        let other = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        check(selected == "base\n" && other == "changed\n", "Discard changed another file")
        let search = try await git(["log", "--format=%s", "--", ":(glob)**/*.txt"], extra: ["GIT_LITERAL_PATHSPECS": "0"])
        check(search.output.trimmed == "base", "Explicit search glob stopped working")

        let original = (1...50).map { "line \($0)" }
        let file = repo.appendingPathComponent("f.txt")
        try Data((original.joined(separator: "\n") + "\n").utf8).write(to: file)
        try await git(["add", "f.txt"])
        try await git(["commit", "-qm", "file"])
        var changed = original
        changed.insert(contentsOf: ["inserted 1", "inserted 2"], at: 2)
        changed[26] = "replacement"
        try Data((changed.joined(separator: "\n") + "\n").utf8).write(to: file)
        let raw = try await git(["diff", "--", "f.txt"])
        let hunks = Parsers.diff(raw.output)
        check(hunks.hunks.count == 2, "Expected two separate hunks")
        let reverse = DiffPatch.build(hunks, hunks: [1], lines: nil, reverse: true)!
        try await git(["apply", "--recount", "--reverse", "-"], input: reverse)
        var expected = original
        expected.insert(contentsOf: ["inserted 1", "inserted 2"], at: 2)
        let resolved = try String(contentsOf: file, encoding: .utf8)
        check(resolved == expected.joined(separator: "\n") + "\n", "Reverse patch used the old hunk location")

        let special = "한글\n\u{1e}\t\".txt"
        try Data("text\n".utf8).write(to: repo.appendingPathComponent(special))
        try await git(["add", "--", special])
        try await git(["commit", "-qm", "special"])
        let history = try await git(["log", "--follow", "--name-only", "-z", "--format=" + Parsers.fileHistoryFormat, "--", special])
        check(Parsers.fileHistory(history.output).map(\.path) == [special], "History split a literal filename")
        let worktree = base.appendingPathComponent("한글\n\t\"worktree")
        try await git(["worktree", "add", "-b", "topic", worktree.path])
        let trees = try await git(["worktree", "list", "--porcelain", "-z"])
        let parsedTrees = Parsers.worktrees(trees.output)
        check(parsedTrees.count == 2 && parsedTrees.contains(where: { $0.path.hasSuffix("/" + worktree.lastPathComponent) && fm.fileExists(atPath: $0.path) }), "Worktree path was quoted or split")

        // 제목의 즉시 검색과 Git의 본문 검색이 같은 공백 무시 규칙을 사용한다.
        let searchCases = [
            ("정리 1", "정리1"), ("정리1", "정 리 1"), ("정\t리   1", "정리 1"),
            ("Re Lease 2", "release2"), ("기능 🚀 2", "기능🚀2"),
            (#"release [1].*+?(){}^$|\done"#, #"release[1].*+?(){}^$|\done"#),
        ]
        for (i, pair) in searchCases.enumerated() {
            let (message, query) = pair
            let search = CommitSearchQuery(query)
            check(search.matches(message), "Immediate search missed \(message) for \(query)")
            let subject = "Search fixture \(i)"
            try await git(["commit", "--allow-empty", "-qm", subject, "-m", message])
            let result = try await git(["log", "--format=%s", "-i", "-E", "--grep=" + search.gitPattern, "HEAD^!"])
            check(result.output.trimmed == subject, "Git body search missed \(message) for \(query)")
        }
        let literal = CommitSearchQuery("정리[1].*")
        check(!literal.matches("정리1xyz"), "Immediate search treated special characters as a pattern")
        try await git(["commit", "--allow-empty", "-qm", "정리1xyz"])
        let noMatch = try await git(["log", "--format=%H", "-i", "-E", "--grep=" + literal.gitPattern, "HEAD^!"])
        check(noMatch.output.isEmpty, "Git search treated special characters as a pattern")
        print("Git core passed: \(checks) checks, real Git staging/discard/patch/history/worktree/search integration")
    }
}
SWIFT
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh")"
swiftc -I "$ROOT/../crates/gitrochi-core/include" "$ROOT/Sources/Core/RustCore.swift" "$TASK_CORE" -parse-as-library -swift-version 5 \
  "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
  "$ROOT/Sources/Core/ProjectTaskReference.swift" "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/Parsers.swift" \
  "$ROOT/Sources/Core/DiffTools.swift" "$ROOT/Sources/Core/Conflict.swift" \
  "$ROOT/Sources/Core/CommitSearch.swift" \
  "$ROOT/Sources/Core/Git.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-git-core"
"$TASK_TMP/test-git-core" "$TASK_TMP/fixtures"
