#!/usr/bin/env bash
# Repository index from Swift: RepoIndex → C ABI in libgitrochi_core.a → Rust → SQLite and
# the C++ tokenizer, against a real temporary repository. Checks the search bar's contract:
# answers while the index is current, nil (so the store runs git) when missing, stale or off.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT

cat > "$TASK_TMP/stubs.swift" <<'SWIFT'
import Foundation
enum SearchScope { case commits, files, code }
SWIFT

cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

@main struct RepositoryIndexTests {
    static func git(_ repo: URL, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path] + args
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "git \(args)")
    }

    static func main() async {
        let repo = URL(fileURLWithPath: CommandLine.arguments[1])
        let head = { () -> String in
            let pipe = Pipe(), process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", repo.path, "rev-parse", "HEAD"]
            process.standardOutput = pipe
            try! process.run(); process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Not indexed yet: nil, so the search bar runs git as before.
        let missing = await RepoIndex.searchMatches(repo, scope: .commits, query: "로그인", codePattern: "")
        precondition(missing == nil)

        let synced = RepoIndex.call("sync", repo: repo)
        precondition(synced?["newCommits"] as? Int == 2, "\(String(describing: synced))")
        let first = (RepoIndex.call("log", repo: repo, args: ["limit": 5])?["commits"] as? [[String: Any]])?.last?["sha"] as? String

        // The same matching as CommitSearchQuery and the icase path glob.
        let korean = await RepoIndex.searchMatches(repo, scope: .commits, query: "로그인", codePattern: "")
        precondition(korean == [first!], "\(String(describing: korean))")
        let body = await RepoIndex.searchMatches(repo, scope: .commits, query: "fix me", codePattern: "")
        precondition(body?.count == 1)
        let files = await RepoIndex.searchMatches(repo, scope: .files, query: "src/lib", codePattern: "")
        precondition(files == [first!])
        let code = await RepoIndex.searchMatches(repo, scope: .code, query: "needle", codePattern: NSRegularExpression.escapedPattern(for: "needle"))
        precondition(code == [first!])

        // A new commit makes the index stale: nil until a background pass catches up.
        try! "more\n".write(to: repo.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
        git(repo, ["add", "-A"]); git(repo, ["commit", "-qm", "New commit after indexing"])
        let stale = await RepoIndex.searchMatches(repo, scope: .commits, query: "new commit", codePattern: "")
        precondition(stale == nil)
        RepoIndex.refresh(repo)
        RepoIndex.refresh(repo)
        var current = false
        for _ in 0..<100 where !current {
            try? await Task.sleep(for: .milliseconds(50))
            current = RepoIndex.call("status", repo: repo)?["stale"] as? Bool == false
        }
        precondition(current, "the background pass did not finish")
        let fresh = await RepoIndex.searchMatches(repo, scope: .commits, query: "new commit", codePattern: "")
        precondition(fresh == [head()], "\(String(describing: fresh))")

        // Calls from many tasks at once share the cached connections safely.
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask { await RepoIndex.searchMatches(repo, scope: .commits, query: "로그인", codePattern: "") == [first!] }
            }
            for await ok in group { precondition(ok) }
        }

        setenv("GITROCHI_INDEX", "0", 1)
        let off = await RepoIndex.searchMatches(repo, scope: .commits, query: "로그인", codePattern: "")
        precondition(off == nil)
        print("RepoIndex passed: git fallback when missing, stale or off; Korean, body, path and code matches; background refresh; concurrent calls")
    }
}
SWIFT

# Build with the real HOME (rustup finds its toolchains there), then isolate git.
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh")"
swiftc -I "$ROOT/../crates/gitrochi-core/include" -parse-as-library -swift-version 5 \
    "$ROOT/Sources/Core/RepoIndex.swift" "$TASK_TMP/stubs.swift" "$TASK_TMP/main.swift" "$TASK_CORE" \
    -o "$TASK_TMP/test-repository-index"

# A private git configuration, so the developer's settings and hooks stay out of the fixture.
mkdir -p "$TASK_TMP/home"
: > "$TASK_TMP/gitconfig"
export HOME="$TASK_TMP/home" GIT_CONFIG_GLOBAL="$TASK_TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
REPO="$TASK_TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Index Fixture"
git -C "$REPO" config user.email "fixture@example.com"
mkdir -p "$REPO/Src/Lib"
echo "let needle = 1" > "$REPO/Src/Lib/Login.swift"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "로그 인 화면"
echo "notes" > "$REPO/notes.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "Unrelated" -m "body mentions FIXME here"

"$TASK_TMP/test-repository-index" "$REPO"
