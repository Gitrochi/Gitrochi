#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
struct GitResult { let data: Data; var output: String { String(decoding: data, as: UTF8.self) } }
enum Git { static func run(_ args: [String], in: URL) async throws -> GitResult { fatalError("Unexpected real Git read") } }
@main struct Tests {
    static func main() async throws {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        func file(_ path: String, mode: String = "100644", size: Int = 40) -> RepositoryTreeEntry { RepositoryTreeEntry(path: path, mode: mode, oid: a, size: size) }
        let entries = [file(".env"), file("README.md", mode: "120000"), file("README.txt", size: 2_000_001), file("module", mode: "160000"), file("src/ui/file.swift"), file("package.json")]
        precondition(RepositoryBrowser.initialFile(entries)?.path == "package.json")
        precondition(RepositoryBrowser.initialFile(entries + [file("readme.MD")])?.path == "readme.MD")
        precondition(RepositoryBrowser.initialFile([file(".env"), file("image.png")]) == nil)
        precondition(RepositoryBrowser.folderCount([file("README.md"), file("src/ui/a.swift"), file("src/ui/b.swift"), file("test/a.swift")]) == 3)
        precondition(RebasePreview.defaultBase(names: ["main", "origin/main", "topic", "origin/topic"], current: "topic", upstream: "origin/topic") == "origin/main")
        let read: ([String], URL) async throws -> String = { args, _ in
            precondition(["rev-parse", "rev-list", "log"].contains(args[0]), "Preview attempted a mutation")
            if args[0] == "rev-parse" { return args[2].hasPrefix("main") ? b : a }
            if args[0] == "rev-list" { precondition(args.last == b + "..." + a); return "3\t2\n" }
            precondition(args.contains(b + ".." + a)); return a + "\tNewest commit\n" + b + "\tOlder commit\n"
        }
        let result = try await RebasePreview.load(in: URL(fileURLWithPath: "/fixture"), base: "main", head: "HEAD", read: read)
        precondition(result.base == b && result.head == a && result.incoming == 3 && result.replay == 2 && result.commits.map(\.subject) == ["Newest commit", "Older commit"])
        do { _ = try await RebasePreview.load(in: URL(fileURLWithPath: "/fixture"), base: "--all", head: "HEAD", read: { _, _ in fatalError("Invalid revision reached Git") }); fatalError("Invalid base accepted") } catch {}
        print("Workbench first screen: safe default file, README preference, directory count, existing base preference and immutable read-only rebase summary passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/RepositoryBrowser.swift" "$ROOT/Sources/Core/RebasePreview.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/first-screen"
"$TASK_TMP/first-screen"
