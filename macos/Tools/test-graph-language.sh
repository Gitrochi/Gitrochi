#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_APP="$TASK_TMP/GraphLanguageTests.app/Contents"
mkdir -p "$TASK_APP/MacOS" "$TASK_APP/Resources"
cat > "$TASK_APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.gitrochi.graph-language-tests</string>
<key>CFBundleExecutable</key><string>GraphLanguageTests</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
cat > "$TASK_APP/Resources/gitch" <<'CLI'
GITSW_VERSION="0.3.12"
GITCH_VERSION_SCHEME="gitrochi"
GITCH_GRAPH_API="1"
CLI
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

@main struct GraphLanguageTests {
    static func main() async throws {
        for (code, expected) in [("ko-KR", "ko"), ("KO_kr", "ko"), ("en-GB", "en"), ("ja-JP", "ja"), ("JA_jp", "ja"), ("de", "en"), ("", "en")] {
            precondition(AppLanguage.graphCode(for: code) == expected)
        }
        let defaults = UserDefaults.standard
        let savedChoice = defaults.object(forKey: AppLanguage.key)
        defer {
            if let savedChoice { defaults.set(savedChoice, forKey: AppLanguage.key) }
            else { defaults.removeObject(forKey: AppLanguage.key) }
        }
        let repo = URL(fileURLWithPath: "/repo")
        var pages: Set<URL> = []
        for code in ["ko", "en", "ja"] {
            defaults.set(code, forKey: AppLanguage.key)
            let start = Shell.calls.count
            let page = try await Gitch.graph(.files, in: repo)
            pages.insert(page.file)
            precondition(page.file.lastPathComponent.contains("-files-\(code)-"))
            let calls = Array(Shell.calls.dropFirst(start))
            precondition(calls.count == 2)
            for call in calls {
                precondition(call.environment["GITCH_GRAPH_LANG"] == code)
                precondition(call.arguments[call.arguments.firstIndex(of: "--out")! + 1] == page.file.path)
            }
        }
        precondition(pages.count == 3, "Each app language needs a separate watcher identity")
        _ = try await Gitch.commitReviewPage(in: repo)
        _ = try await Gitch.graphDiff(.files, base: nil, in: repo)
        _ = try await Gitch.graphCheckPage(in: repo)
        precondition(Shell.calls.suffix(3).allSatisfy { $0.environment["GITCH_GRAPH_LANG"] == "ja" })
        _ = try await Gitch.run(["version"], in: repo)
        precondition(Shell.calls.last!.environment["GITCH_GRAPH_LANG"] == ProcessInfo.processInfo.environment["GITCH_GRAPH_LANG"])
        defaults.set("system", forKey: AppLanguage.key)
        precondition(AppLanguage.graphCode == AppLanguage.graphCode(for: AppLanguage.current))
        print("Graph language passed: regional codes, app preference, system fallback, generation/watch environment, isolated pages, and unchanged non-graph commands")
    }
}

struct GitResult {
    let status: Int32
    let data: Data
    let stderr: String
    var output: String { String(decoding: data, as: UTF8.self) }
}
enum Shell {
    struct Call { let arguments: [String]; let environment: [String: String] }
    static var calls: [Call] = []
    static func run(_ executable: String, _ arguments: [String], cwd: URL, env: [String: String], timeout: TimeInterval) async throws -> GitResult {
        calls.append(Call(arguments: arguments, environment: env))
        let text = arguments.contains("watch") ? #"{"url":"http://127.0.0.1:8765/fixture/"}"# : "GRAPH_FILE=fixture.html NODES=2 EDGES=1"
        return GitResult(status: 0, data: Data(text.utf8), stderr: "")
    }
}
enum Git {
    static func run(_ arguments: [String], in repo: URL) async throws -> GitResult {
        GitResult(status: 0, data: Data(), stderr: "")
    }
}
final class ToolPaths {
    enum Tool { case git }
    static let shared = ToolPaths()
    func get(_ tool: Tool) -> String? { nil }
}
enum Launcher {
    static func run(_ executable: String, args: [String], in path: String) throws {}
}
SWIFT
swiftc -parse-as-library "$ROOT/Sources/Core/AppLanguage.swift" "$ROOT/Sources/Core/CommitReview.swift" "$ROOT/Sources/Services/Gitch.swift" "$TASK_TMP/main.swift" -o "$TASK_APP/MacOS/GraphLanguageTests"
"$TASK_APP/MacOS/GraphLanguageTests"
