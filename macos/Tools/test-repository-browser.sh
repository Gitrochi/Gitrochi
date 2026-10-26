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
        print("Repository browser passed: real Git tree/blob reads, literal paths, immutable SHA, symlink isolation, images, binary detection and size limits")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/RepositoryBrowser.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/browser-tests"
"$TASK_TMP/browser-tests" "$TASK_TMP"
