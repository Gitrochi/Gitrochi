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
        navigation.visit("branch.swift", mode: "File history")
        precondition(navigation.tabModes["branch.swift"] == "File history")
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
        print("Repository browser passed: safe immutable previews, reader navigation, file-count language statistics and bounded CSS/raster HTML resources with restrictive policy")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/RepositoryBrowser.swift" "$ROOT/Sources/Core/RepositoryCodeReading.swift" "$ROOT/Sources/Core/RepositoryCodeNavigation.swift" "$ROOT/Sources/Core/RepositoryLanguages.swift" "$ROOT/Sources/Services/RepositoryHTMLDocument.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/browser-tests"
"$TASK_TMP/browser-tests" "$TASK_TMP"
