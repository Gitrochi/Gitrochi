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
            precondition(calls.count == 1)
            precondition(page.liveURL == nil)
            for call in calls {
                precondition(call.environment["GITCH_GRAPH_LANG"] == code)
                precondition(call.environment["GIT_CONFIG_PARAMETERS"]?.hasSuffix("'core.fsmonitor=false'") == true)
                precondition(!call.arguments.contains("watch"))
                precondition(call.arguments[call.arguments.firstIndex(of: "--out")! + 1] == page.file.path)
            }
        }
        precondition(pages.count == 3, "Each app language needs a separate snapshot")
        let repeated = try await Gitch.graph(.files, in: repo)
        precondition(!pages.contains(repeated.file), "An old watcher cannot replace a new snapshot")
        _ = try await Gitch.commitReviewPage(in: repo)
        _ = try await Gitch.graphDiff(.files, base: nil, in: repo)
        _ = try await Gitch.graphCheckPage(in: repo)
        precondition(Shell.calls.suffix(3).allSatisfy { $0.environment["GITCH_GRAPH_LANG"] == "ja" })
        _ = try await Gitch.run(["version"], in: repo)
        precondition(Shell.calls.last!.environment["GITCH_GRAPH_LANG"] == ProcessInfo.processInfo.environment["GITCH_GRAPH_LANG"])
        precondition(Shell.calls.last!.environment["GIT_CONFIG_PARAMETERS"] == ProcessInfo.processInfo.environment["GIT_CONFIG_PARAMETERS"])
        defaults.set("system", forKey: AppLanguage.key)
        precondition(AppLanguage.graphCode == AppLanguage.graphCode(for: AppLanguage.current))
        try verifyReadOnlyGraphEnvironment()
        print("Graph language passed: regional codes, app preference, system fallback, protected offline generations, isolated pages, and unchanged non-graph commands")
    }

    static func verifyReadOnlyGraphEnvironment() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("gitrochi-graph-hook-" + UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        var clean = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_CONFIG_") }
        clean["XDG_CACHE_HOME"] = fixture.appendingPathComponent("cache").path
        func run(_ executable: String, _ arguments: [String], _ environment: [String: String]) throws -> String {
            let process = Process(), output = Pipe(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.currentDirectoryURL = fixture; process.environment = environment
            process.standardOutput = output; process.standardError = error
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let problem = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, String(decoding: problem, as: UTF8.self))
            return String(decoding: data, as: UTF8.self)
        }
        _ = try run("/usr/bin/git", ["init", "-q"], clean)
        try "export const fixture=1;\n".write(to: fixture.appendingPathComponent("source.ts"), atomically: true, encoding: .utf8)
        _ = try run("/usr/bin/git", ["add", "source.ts"], clean)
        let hook = fixture.appendingPathComponent("fsmonitor-hook"), marker = fixture.appendingPathComponent("hook-ran")
        try "#!/bin/sh\nprintf ran > \"$(dirname \"$0\")/hook-ran\"\nprintf \"fixture-token\\0\"\n".write(to: hook, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try run("/usr/bin/git", ["config", "core.fsmonitor", hook.path], clean)
        let configuration = try Data(contentsOf: fixture.appendingPathComponent(".git/config"))
        _ = try run("/usr/bin/git", ["ls-files"], clean)
        precondition(manager.fileExists(atPath: marker.path), "The FSMonitor control must execute the fixture hook")
        try manager.removeItem(at: marker)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let variants: [[String: String]] = [[:],
            ["GIT_CONFIG_PARAMETERS": quote("core.fsmonitor=" + hook.path)],
            ["GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "core.quotepath", "GIT_CONFIG_VALUE_0": "false", "GIT_CONFIG_KEY_1": "core.fsmonitor", "GIT_CONFIG_VALUE_1": hook.path],
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": hook.path, "GIT_CONFIG_PARAMETERS": quote("core.fsmonitor=" + hook.path)]]
        for variant in variants {
            let source = clean.merging(variant) { _, value in value }, protected = Gitch.readOnlyGraphEnvironment(source)
            precondition(variant.allSatisfy { $0.key == "GIT_CONFIG_PARAMETERS" || protected[$0.key] == $0.value })
            precondition(protected["GITSW_SWIFT_DESCRIBE"] == "0")
            let raw = try run("/bin/bash", [CommandLine.arguments[1], "graph", "files", "--json", fixture.path], protected)
            precondition(raw.contains("source.ts"), "Protected analysis must still produce the actual file graph")
            precondition(!manager.fileExists(atPath: marker.path), "Read-only graph subprocesses cannot execute FSMonitor")
            let actual = try run("/usr/bin/git", ["config", "--get", "core.fsmonitor"], protected)
            precondition(actual.trimmingCharacters(in: .whitespacesAndNewlines) == "false")
        }
        let finalConfiguration = try Data(contentsOf: fixture.appendingPathComponent(".git/config"))
        precondition(finalConfiguration == configuration, "User configuration must not be changed")
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
"$TASK_APP/MacOS/GraphLanguageTests" "$ROOT/../tools/gitch/gitch"
