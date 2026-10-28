#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
import AppKit
struct GitResult { let data: Data; var output: String { String(decoding: data, as: UTF8.self) } }
enum Git { static func run(_ args: [String], in root: URL) async throws -> GitResult { fatalError("External editors must not run Git") } }
@main struct Tests {
    @MainActor static func main() async throws {
        let temporary = URL(fileURLWithPath: CommandLine.arguments[1]), root = temporary.appendingPathComponent("repository.app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try Data("fixture\n".utf8).write(to: temporary.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: temporary.appendingPathComponent("outside.txt"))
        let target = try ExternalEditors.target(repository: root, file: "readme.txt")
        precondition(target == root.appendingPathComponent("readme.txt").resolvingSymlinksInPath())
        for path in ["../outside.txt", "escape.txt", "missing.txt", "/outside.txt", ".", "a//file"] {
            do { _ = try ExternalEditors.target(repository: root, file: path); fatalError("Unsafe or missing target accepted") } catch {}
        }
        precondition(ExternalEditors.permitsSystemDefault(root.appendingPathComponent("readme.txt")))
        for ext in [
            "app", "command", "sh", "bash", "zsh", "fish", "csh", "ksh", "workflow", "scpt", "scptd", "applescript",
            "exe", "com", "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "js", "jse", "jar", "py", "pyw", "rb", "pl",
            "run", "pkg", "dmg", "lnk", "url", "webloc", "desktop", "html", "htm", "svg", "wsf", "wsh", "msi", "msp",
            "scr", "pif", "hta", "reg", "jnlp", "application", "appref-ms", "xhtml", "xht", "svgz", "mhtml", "mht", "cpl", "XHTML"
        ] { precondition(!ExternalEditors.permitsSystemDefault(root.appendingPathComponent("sample." + ext))) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("readme.txt").path)
        precondition(!ExternalEditors.permitsSystemDefault(root.appendingPathComponent("readme.txt")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("readme.txt").path)
        let detected = ExternalEditors.editors(resolve: { $0 == "com.microsoft.VSCode" ? URL(fileURLWithPath: "/Applications/Fixture Editor.app") : nil }, exists: { _ in false })
        precondition(detected.first(where: { $0.id == "vscode" })?.available == true && detected.first(where: { $0.id == "xcode" })?.available == false)
        var launches = 0
        let launch: ([URL], URL) async throws -> Void = { files, application in
            launches += 1; precondition(files == [root.appendingPathComponent("readme.txt").resolvingSymlinksInPath()] && application.lastPathComponent == "Fixture Editor.app")
        }
        try await ExternalEditors.open(repository: root, editorID: "vscode", file: "readme.txt", available: detected, launch: launch)
        precondition(launches == 1)
        for id in ["unknown", "xcode"] {
            do { try await ExternalEditors.open(repository: root, editorID: id, file: "readme.txt", available: detected, launch: launch); fatalError("Unknown or unavailable editor accepted") } catch {}
        }
        let malicious = ExternalEditor(id: "vscode", name: "Fixture", available: true, supportsFolders: true, applicationURL: root.appendingPathComponent("Editor.app"))
        do { try await ExternalEditors.open(repository: root, editorID: "vscode", file: "readme.txt", available: [malicious], launch: launch); fatalError("Repository application accepted") } catch {}
        var finder = false
        try await ExternalEditors.open(repository: root, editorID: "system", file: nil, launch: { files, application in finder = files == [root.resolvingSymlinksInPath()] && application.lastPathComponent == "Finder.app" })
        precondition(finder && launches == 1)
        print("External editors passed: injected discovery/launch, canonical regular-file containment, missing paths, symlink escape, executable/default blocking and explicit Finder folders")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/RepositoryBrowser.swift" "$ROOT/Sources/Services/ExternalEditors.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/external-editors"
"$TASK_TMP/external-editors" "$TASK_TMP"
