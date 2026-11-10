#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
struct GitResult { let data: Data; var output: String { String(decoding: data, as: UTF8.self) } }
enum Git {
    static func run(_ args: [String], in dir: URL) async throws -> GitResult {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-c", "core.quotepath=off"] + args; p.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); let errors = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RepositoryBrowserError(message: String(decoding: errors, as: UTF8.self)) }; return GitResult(data: data)
    }
}
@main struct BrowserTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Browser Fixture"], ["config", "user.email", "fixture@example.invalid"]] { _ = try await Git.run(args, in: root) }
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("source [*].txt"))
        try Data([137,80,78,71,13,10,26,10]).write(to: root.appendingPathComponent("image.png"))
        try Data([0,1,2,3]).write(to: root.appendingPathComponent("binary"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside-link").path, withDestinationPath: "/etc/passwd")
        _ = try await Git.run(["add", "--", "."], in: root); _ = try await Git.run(["commit", "-m", "Fixture"], in: root)
        let tree = try await RepositoryBrowser.tree(in: root, ref: "main")
        precondition(tree.entries.count == 4 && RepositoryBrowser.objectID(tree.revision))
        let text = tree.entries.first { $0.path == "source [*].txt" }!
        let textPreview = try await RepositoryBrowser.blob(in: root, entry: text); precondition(textPreview.text == "hello\n")
        let link = tree.entries.first { $0.path == "outside-link" }!
        let linkPreview = try await RepositoryBrowser.blob(in: root, entry: link)
        precondition(linkPreview.text == "/etc/passwd" && linkPreview.notice != nil && linkPreview.image == nil)
        let image = tree.entries.first { $0.path == "image.png" }!
        let imagePreview = try await RepositoryBrowser.blob(in: root, entry: image); precondition(imagePreview.image != nil)
        let binary = tree.entries.first { $0.path == "binary" }!
        let binaryPreview = try await RepositoryBrowser.blob(in: root, entry: binary); precondition(binaryPreview.notice != nil)
        for path in ["../secret", "a/../b", "/etc/passwd", "a//b", "a\nb", "C:\\secret"] { precondition(!RepositoryBrowser.safePath(path)) }
        for value in ["--output=secret", "bad\nref", "", " HEAD"] { precondition(!RepositoryBrowser.validRevision(value)) }
        precondition(RepositoryBrowser.imageMIME(Data("<svg onload=alert(1)>".utf8)) == nil)
        let huge = RepositoryTreeEntry(path: "large", mode: "100644", oid: text.oid, size: RepositoryBrowser.imageLimit + 1)
        let hugePreview = try await RepositoryBrowser.blob(in: root, entry: huge); precondition(hugePreview.notice != nil)
        let sha256 = String(repeating: "b", count: 64)
        precondition(RepositoryBrowser.parseTree("160000 commit \(sha256) -\tmodule\0").first?.isSubmodule == true)
        precondition(RepositoryCodeReading.lineStarts(in: "").isEmpty)
        precondition(RepositoryCodeReading.lineStarts(in: "a\r\nb\n") == [0, 3])
        precondition(RepositoryCodeReading.matches(in: "🧭 let value = LET", query: "let") == [NSRange(location: 3, length: 3), NSRange(location: 15, length: 3)])
        precondition(RepositoryCodeReading.matches(in: String(repeating: "x", count: 20_000), query: "x").count == 10_001)
        let tokens = RepositoryCodeReading.tokens(in: "const answer = \"42\"; // 7\n", path: "source.ts")
        precondition(tokens.map(\.kind) == [.keyword, .string, .comment])
        precondition(RepositoryCodeReading.tokens(in: String(repeating: "let x = 1\n", count: 30_000), path: "source.swift").isEmpty)
        var navigation = RepositoryCodeNavigation()
        for index in 0..<80 { navigation.visit("file\(index).swift", mode: "Source") }
        precondition(navigation.tabs.count == 12 && navigation.recent.count == 20 && navigation.history.count == 50)
        precondition(navigation.move(-1)?.path == "file78.swift" && navigation.canGoForward)
        navigation.visit("branch.swift", mode: "Blame")
        precondition(!navigation.canGoForward && navigation.history.last?.mode == "Blame" && navigation.tabModes["branch.swift"] == "Blame")
        let historyCount = navigation.history.count
        navigation.visit("branch.swift", mode: "Blame")
        precondition(navigation.history.count == historyCount && Set(navigation.recent).count == navigation.recent.count)
        navigation.visit("branch.swift", mode: "History")
        precondition(navigation.tabModes["branch.swift"] == "History")
        let replacement = navigation.close("branch.swift", selected: "branch.swift")
        precondition(replacement != nil && !navigation.tabs.contains("branch.swift") && navigation.tabModes["branch.swift"] == nil)
        navigation.closeAll(); precondition(navigation.tabs.isEmpty && navigation.tabModes.isEmpty && !navigation.recent.isEmpty)
        let paths = ["src/view.swift", "view.swift", "src/views/long-view.swift", "docs/guide.md"]
        precondition(RepositoryCodeNavigation.rankedPaths(paths, query: "view.swift", recent: []).first == "view.swift")
        precondition(RepositoryCodeNavigation.rankedPaths(paths, query: "src long", recent: []) == ["src/views/long-view.swift"])
        precondition(RepositoryCodeNavigation.rankedPaths(paths, query: "", recent: ["missing", "docs/guide.md"]) == ["docs/guide.md"])
        precondition(RepositoryCodeNavigation.rankedPaths((0..<100).map { "file\($0).swift" }, query: "file", recent: []).count == 50)
        precondition(RepositoryCodeReading.validLine(" 2 ", count: 4) == 2)
        for value in ["", "0", "-1", "1.5", "1e2", "5", "999999999999999999999999"] { precondition(RepositoryCodeReading.validLine(value, count: 4) == nil) }
        precondition(RepositoryCodeReading.lineRange(2, starts: [0, 4], length: 9) == NSRange(location: 4, length: 5))
        let source = "func visible() {}\nlet example = `\nfunction hidden() {}\n`;\nlet note = /*\nclass Hidden {}\n*/ 1;\nexport class Visible {}\n"
        precondition(RepositoryCodeReading.outline(in: source, path: "source.ts").map(\.name) == ["visible", "Visible"])
        let markdown = "# Guide\n````md\n# Hidden\n```\n# Still hidden\n````\n## Details\n"
        let headings = RepositoryCodeReading.outline(in: markdown, path: "README.md")
        precondition(headings.map(\.name) == ["Guide", "Details"] && headings.map(\.line) == [1, 7])
        let separators = "let sample = \"a\rb\u{2028}c\"\nfunc real() {}\n"
        precondition(RepositoryCodeReading.outline(in: separators, path: "source.swift").first?.line == 2)
        precondition(RepositoryCodeReading.outline(in: (0..<400).map { "func symbol\($0)() {}" }.joined(separator: "\n"), path: "source.swift").count == 200)
        let a = text.oid
        let languageEntries = [RepositoryTreeEntry(path: "a.ts", mode: "100644", oid: a, size: 10), RepositoryTreeEntry(path: "b.tsx", mode: "100755", oid: a, size: 20), RepositoryTreeEntry(path: "image.png", mode: "100644", oid: a, size: 30), RepositoryTreeEntry(path: "link.ts", mode: "120000", oid: a, size: 4), RepositoryTreeEntry(path: "module", mode: "160000", oid: a, size: 0)]
        let composition = RepositoryLanguages.composition(languageEntries)
        precondition(composition.map(\.language) == ["TypeScript", "Other files"] && composition.map(\.count) == [2, 1])
        precondition(abs(composition.map(\.fraction).reduce(0, +) - 1) < 0.00001 && composition.first?.bytes == 30)
        precondition(RepositoryLanguages.language(for: "src/.template.swift") == "Swift" && RepositoryLanguages.language(for: "README") == "Other files")
        precondition(RepositoryLanguages.language(for: "config/.gitignore") == "Configuration")
        precondition(RepositoryHTMLDocument.localPath("../assets/icon.png?v=1#preview", relativeTo: "pages/index.html") == "assets/icon.png")
        for reference in ["../../outside.png", "file:///private/file.png", "https://example.invalid/image.png", "//example.invalid/image.png", "%2e%2e/%2e%2e/private.png", "a%00.png"] { precondition(RepositoryHTMLDocument.localPath(reference, relativeTo: "index.html") == nil) }
        let inlinePNG = "data:image/png;base64," + Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
        precondition(RepositoryHTMLDocument.inlineRaster(inlinePNG)?.mime == "image/png")
        precondition(RepositoryHTMLDocument.inlineRaster("data:image/svg+xml;base64," + Data("<svg/>".utf8).base64EncodedString()) == nil)
        precondition(RepositoryHTMLDocument.inlineRaster("data:image/jpeg;base64," + Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()) == nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("styles"), withIntermediateDirectories: true)
        try Data("body { color: purple; background: url('../image.png'); } @import 'https://example.invalid/style.css';".utf8).write(to: root.appendingPathComponent("styles/theme.css"))
        _ = try await Git.run(["add", "--", "styles/theme.css"], in: root); _ = try await Git.run(["commit", "-m", "Add preview stylesheet fixture"], in: root)
        let previewTree = try await RepositoryBrowser.tree(in: root, ref: "HEAD")
        let html = "<base href='https://example.invalid/'><link rel='stylesheet' href='styles/theme.css'><img src='image.png'><img src='\(inlinePNG)'><img src='https://example.invalid/tracker.png'><script>document.title='unsafe'</script>"
        let document = await RepositoryHTMLDocument.load(text: html, path: "index.html", tree: previewTree, repository: root)
        precondition(document.resources.count == 3 && document.resources.values.filter { $0.mime == "text/css" }.count == 1 && document.missingResources)
        precondition(document.html.contains("Content-Security-Policy") && document.html.contains("script-src 'none'") && document.html.contains("img-src gitrochi-source:") && !document.html.contains("img-src data:"))
        precondition(document.resources.values.filter { $0.mime == "text/css" }.allSatisfy { String(decoding: $0.data, as: UTF8.self).contains("gitrochi-source://asset/") })
        let imageOID = previewTree.entries.first(where: { $0.path == "image.png" })!.oid
        let manyAssets = (0..<25).map { RepositoryTreeEntry(path: "asset\($0).png", mode: "100644", oid: imageOID, size: 8) }
        let bounded = await RepositoryHTMLDocument.load(text: manyAssets.map { "<img src='\($0.path)'>" }.joined(), path: "index.html", tree: RepositoryTreeSnapshot(revision: previewTree.revision, entries: manyAssets, truncated: false), repository: root)
        precondition(bounded.resources.count == 20 && bounded.missingResources)
        // The Code page's History, Blame and Working changes (Windows: tests/code-history.test.ts)
        typealias History = RepositoryCodeHistory
        precondition(History.logArgs(revision: "HEAD", path: "src/a b.ts", format: "%H") == ["log", "--follow", "-M", "--name-only", "-z", "-n", "201", "--format=%H", "HEAD", "--", "src/a b.ts"])
        precondition(History.changeArgs(commit: "abc", path: "a.ts", ignoreWhitespace: false) == ["show", "--format=", "--no-ext-diff", "--no-textconv", "-M", "-m", "--first-parent", "abc", "--", "a.ts"])
        precondition(History.workingArgs(path: "a.ts", ignoreWhitespace: true) == ["diff", "--no-ext-diff", "--no-textconv", "-w", "HEAD", "--", "a.ts"])
        precondition(History.comparisonArgs(base: "base", commit: "abc", path: "a.ts", oldPath: nil, ignoreWhitespace: false) == ["diff", "--no-ext-diff", "--no-textconv", "-M", "base", "abc", "--", "a.ts"])
        precondition(History.comparisonArgs(base: "base", commit: "abc", path: "new.ts", oldPath: "old.ts", ignoreWhitespace: true) == ["diff", "--no-ext-diff", "--no-textconv", "-M", "-w", "base", "abc", "--", "old.ts", "new.ts"])
        precondition(History.comparisonArgs(base: "base", commit: "abc", path: "a.ts", oldPath: "a.ts", ignoreWhitespace: false).filter { $0 == "a.ts" }.count == 1)
        precondition(History.blameArgs(revision: "abc", path: "a.ts", lines: 33) == ["blame", "--porcelain", "-L", "1,33", "abc", "--", "a.ts"])
        precondition(History.blameArgs(revision: "abc", path: "a.ts", lines: 0)[3] == "1,1" && History.blameArgs(revision: "abc", path: "a.ts", lines: 90_000)[3] == "1,5000")
        precondition(History.countLabel(8) == "8" && History.countLabel(200) == "200" && History.countLabel(201) == "200+")
        precondition(History.shortFolder("macos/Sources/Views/Search") == "…/Views/Search" && History.shortFolder("src/components") == "src/components" && History.shortFolder("") == "")
        precondition(History.shortFolder("a/b/tests", limit: 8) == "…/tests" && History.shortFolder("packages/an-extremely-long-folder-name") == "" && History.shortFolder("an-extremely-long-folder-name") == "")
        let shown = "c4d5e6f" + String(repeating: "0", count: 33)
        precondition(History.revisionName(input: "HEAD", revision: shown, branch: "feature/workspace-search") == "feature/workspace-search" && History.revisionName(input: "HEAD", revision: shown, branch: nil) == nil)
        precondition(History.revisionName(input: "v1.0", revision: shown, branch: "main") == "v1.0" && History.revisionName(input: "C4D5E6F", revision: shown, branch: "main") == nil)
        precondition(History.lines("a\r\n\tb\n\nc") == ["a", "    b", "", "c"] && History.lines("a\nb\n") == ["a", "b"] && History.lines("").isEmpty)
        // the History board: a1b2c3d changes lines 5-11 and 23-44 of a 46-line file
        precondition(History.gaps([History.Hunk(oldStart: 5, oldCount: 7, newStart: 5, newCount: 7), History.Hunk(oldStart: 23, oldCount: 15, newStart: 23, newCount: 22)], lineCount: 46)
            == [History.Gap(hunk: 0, oldStart: 1, newStart: 1, count: 4), History.Gap(hunk: 1, oldStart: 12, newStart: 12, count: 11), History.Gap(hunk: 2, oldStart: 38, newStart: 45, count: 2)])
        precondition(History.gaps([History.Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 3)], lineCount: 3).isEmpty && History.gaps([History.Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 5)], lineCount: 5).isEmpty)
        precondition(History.gaps([History.Hunk(oldStart: 5, oldCount: 3, newStart: 4, newCount: 0)], lineCount: 6) == [History.Gap(hunk: 0, oldStart: 1, newStart: 1, count: 4), History.Gap(hunk: 1, oldStart: 8, newStart: 5, count: 2)])
        precondition(History.gaps([], lineCount: 3) == [History.Gap(hunk: 0, oldStart: 1, newStart: 1, count: 3)])
        let renamed: [(id: String, parent: String?, path: String)] = [("c", "b", "src/new.ts"), ("b", "a", "src/new.ts"), ("a", nil, "src/old.ts")]
        precondition(History.before("c", in: renamed)! == ("b", "src/new.ts") && History.before("b", in: renamed)! == ("a", "src/old.ts"))
        precondition(History.before("a", in: renamed) == nil && History.before("missing", in: renamed) == nil)
        // the same arguments against a real repository: a root commit, a second commit and a merge
        func out(_ args: [String]) async throws -> String { try await Git.run(args, in: root).output }
        func sha(_ revision: String) async throws -> String { try await out(["rev-parse", revision]).trimmingCharacters(in: .whitespacesAndNewlines) }
        let tracked = "source [*].txt", first = try await out(["rev-list", "--max-parents=0", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("hello\nworld\n".utf8).write(to: root.appendingPathComponent(tracked))
        _ = try await out(["commit", "-am", "Greet the world"])
        let second = try await sha("HEAD")
        let log = try await out(History.logArgs(revision: second, path: tracked, format: "%x1e%H"))
        precondition(log.components(separatedBy: "\u{1e}").dropFirst().map { String($0.prefix(40)) } == [second, first] && log.contains("\0\n" + tracked + "\0"), "History must list the file's commits, newest first, with its path")
        let change = try await out(History.changeArgs(commit: second, path: tracked, ignoreWhitespace: false))
        precondition(change.hasPrefix("diff --git") && change.contains("@@ -1 +1,2 @@") && change.contains("+world"), "A commit's change must be a plain patch against its parent")
        let compared = try await out(History.comparisonArgs(base: first, commit: second, path: tracked, oldPath: nil, ignoreWhitespace: false))
        precondition(compared == change, "A comparison from the parent must read the same change as the commit")
        let created = try await out(History.changeArgs(commit: first, path: tracked, ignoreWhitespace: false))
        precondition(created.contains("new file mode") && created.contains("+hello"), "A root commit must show the file as added")
        let file = try await out(History.fileArgs(commit: second, path: tracked))
        precondition(file == "hello\nworld\n")
        let blame = try await out(History.blameArgs(revision: second, path: tracked, lines: 2))
        precondition(blame.contains("\thello\n") && blame.contains("\tworld\n") && blame.contains("summary Greet the world") && blame.hasPrefix(first), "Blame must be porcelain, with each line's commit")
        _ = try await out(["switch", "-c", "side", first]); try Data("side\n".utf8).write(to: root.appendingPathComponent("side.txt"))
        _ = try await out(["add", "--", "side.txt"]); _ = try await out(["commit", "-m", "Add the side file"])
        _ = try await out(["switch", "main"]); _ = try await out(["merge", "--no-ff", "-m", "Merge side", "side"])
        let merge = try await sha("HEAD")
        let merged = try await out(History.changeArgs(commit: merge, path: "side.txt", ignoreWhitespace: false))
        let kept = try await out(History.changeArgs(commit: merge, path: tracked, ignoreWhitespace: false))
        precondition(merged.contains("+side") && kept.isEmpty, "A merge must show its change against the first parent, and nothing that parent already had")
        let local = try await out(History.localArgs(revision: merge))
        precondition(local.split(separator: "\n").count == 5, "Without a remote every commit is local")
        try Data("hello\n  world\n".utf8).write(to: root.appendingPathComponent(tracked))
        let working = try await out(History.workingArgs(path: tracked, ignoreWhitespace: false)), ignoring = try await out(History.workingArgs(path: tracked, ignoreWhitespace: true))
        precondition(working.contains("+  world") && ignoring.isEmpty, "The working change must follow the whitespace setting")
        print("Repository browser passed: safe immutable previews, reader navigation, file-count language statistics, bounded CSS/raster HTML resources with restrictive policy, and the Code page's history, blame and change reads")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/RepositoryBrowser.swift" "$ROOT/Sources/Core/RepositoryCodeReading.swift" "$ROOT/Sources/Core/RepositoryCodeNavigation.swift" "$ROOT/Sources/Core/RepositoryCodeHistory.swift" "$ROOT/Sources/Core/RepositoryLanguages.swift" "$ROOT/Sources/Services/RepositoryHTMLDocument.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/browser-tests"
"$TASK_TMP/browser-tests" "$TASK_TMP"
