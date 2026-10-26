#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
@main struct RouteTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("gitrochi-route-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("한글 space & repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func link(_ pairs: [(String, String)]) -> URL {
            var c = URLComponents(string: "gitrochi://open")!
            c.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
            return c.url!
        }
        let root = [("repo", repo.path)]
        let good = try AppRoute(url: link(root + [("file", "src/한글 #?.ts"), ("line", "27")]))
        precondition(good.file == "src/한글 #?.ts" && good.line == 27)
        precondition(good.repo.path == repo.resolvingSymlinksInPath().path)
        let sha = String(repeating: "a1", count: 20)
        let commitRoute = try AppRoute(url: link(root + [("commit", sha)]))
        precondition(commitRoute.commit == sha)
        let finderRoot = try AppRoute(url: link(root + [("view", "finder")]))
        precondition(finderRoot.file == nil && finderRoot.view == "finder")
        let finderFolder = try AppRoute(url: link(root + [("view", "finder"), ("file", "src/한글 & 폴더")]))
        precondition(finderFolder.file == "src/한글 & 폴더")
        let finderFile = try AppRoute(url: link(root + [("view", "finder"), ("file", "src/한글 #?.ts")]))
        precondition(finderFile.file == "src/한글 #?.ts")
        let store = RepoStore(url: repo.resolvingSymlinksInPath())
        for route in [finderRoot, finderFolder, finderFile] { await store.applyAppRoute(route) }
        precondition(store.finderPaths == ["", "src/한글 & 폴더", "src/한글 #?.ts"])
        precondition(store.otherActions == 0, "Finder routes must not navigate or open file history")
        var rejected = 0
        func rejects(_ pairs: [(String, String)]) {
            do { _ = try AppRoute(url: link(pairs)); fatalError("Accepted invalid route: \(pairs)") }
            catch { rejected += 1 }
        }
        for file in ["../escape", "/etc/passwd", "a/../b", "a\\b", "C:secret", "a//b", "./a"] { rejects(root + [("file", file)]) }
        for line in ["0", "-1", "1x", "1000000000", "999999999999999999999999999"] { rejects(root + [("file", "a.ts"), ("line", line)]) }
        rejects(root + [("line", "1")])
        rejects(root + [("repo", repo.path)])
        rejects(root + [("view", "command")])
        rejects(root + [("view", "diff")])
        rejects(root + [("view", "finder"), ("file", "src/a.ts"), ("line", "1")])
        rejects(root + [("view", "finder"), ("commit", sha)])
        rejects(root + [("view", "finder"), ("file", "src/")])
        rejects(root + [("view", "finder"), ("file", "../escape")])
        rejects(root + [("unknown", "value")])
        rejects(root + [("commit", "abc")])
        rejects([("repo", "relative")])
        rejects([("repo", base.path)])
        try fm.createSymbolicLink(at: repo.appendingPathComponent("outside"), withDestinationURL: base)
        rejects(root + [("file", "outside/missing.ts")])
        rejects(root + [("view", "finder"), ("file", "outside/missing-folder")])
        print("AppRoute passed: Unicode encoding, file/line, Finder file/folder/root dispatch, and \(rejected) invalid routes")
    }
}

// Compile the real route dispatcher against a store that records actions without activating Finder.
enum Gitch { enum GraphRelation: String { case graph, files, modules, changes, tree } }
struct RouteChange { let paths: [String] }
enum RouteSelection: Equatable { case commit(String) }
enum RouteDiff { case working(RouteChange), commit(sha: String, change: RouteChange, parent: String?) }
enum RouteNavigation { case commits }
@MainActor final class RepoStore {
    let url: URL?
    var finderPaths: [String] = []
    var otherActions = 0
    var selection: RouteSelection?
    var detailTask: Task<Void, Never>?
    var detailFiles: [RouteChange] = []
    var status = (unstaged: [RouteChange](), staged: [RouteChange]())
    var fileInspectLine: Int?
    init(url: URL) { self.url = url }
    func revealInFinder(path: String) { finderPaths.append(path) }
    func closeFileInspect() { otherActions += 1 }
    func select(_ value: RouteSelection) { selection = value; otherActions += 1 }
    func reveal(_ commit: String) { otherActions += 1 }
    func openDiff(_ value: RouteDiff) { otherActions += 1 }
    func openBlame(_ file: String) { otherActions += 1 }
    func openFileHistory(_ file: String) { otherActions += 1 }
    func openAffectedGraph() async { otherActions += 1 }
    func openStructureGraph(_ relation: Gitch.GraphRelation, precise: Bool = false) async { otherActions += 1 }
    func navigate(_ value: RouteNavigation) { otherActions += 1 }
    func closeDiff() { otherActions += 1 }
}
SWIFT
swiftc -parse-as-library "$ROOT/Sources/Core/AppRoute.swift" "$ROOT/Sources/Store/RepoStore+AppRoute.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-route"
"$TASK_TMP/test-route"
