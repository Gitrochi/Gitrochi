#!/usr/bin/env bash
# Check mirrored version semantics without credentials, servers or a real repository.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
struct HubItem { var id: String; var title: String; var subtitle = ""; var data: [String: Any] = [:] }
enum Provider { case github, gitlab }
struct RepoTarget { var provider: Provider; var host: String; var path: String }
@main struct Tests {
    static func main() {
        let tags = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.9.0", "1.10.0", "999999999999999999999999.0.0"]
        for index in 1..<tags.count { precondition(ReleaseCatalog.compare(tags[index - 1], tags[index])! < 0) }
        precondition(ReleaseCatalog.compare("v1.0.0+build.2", "1.0.0+build.1") == 0)
        for tag in ["v01.0.0", "1.0.0-01", "1.0", "2026-10-28", "build1.2.3"] { precondition(ReleaseCatalog.version(tag) == nil) }
        precondition(ReleaseCatalog.compare("client@1.0.0", "server@2.0.0") == nil)
        precondition(ReleaseCatalog.compare("client/v1.9.0", "client/v1.10.0")! < 0)
        func item(_ tag: String, _ date: String) -> HubItem { HubItem(id: tag, title: tag, data: ["tag_name": tag, "published_at": date]) }
        let items = [item("v1.9.0", "2026-10-02"), item("v1.10.0", "2026-10-01")]
        precondition(ReleaseCatalog.ordered(items, byVersion: true).first?.id == "v1.10.0")
        precondition(ReleaseCatalog.ordered(items + [item("nightly", "2026-10-03")], byVersion: true).first?.id == "nightly")
        let target = RepoTarget(provider: .github, host: "github.com", path: "team/repo")
        precondition(ReleaseCatalog.compareURL(target, base: "client/v1.0.0", head: "client/v2.0.0")!.absoluteString.hasSuffix("client%2Fv1.0.0...client%2Fv2.0.0"))
        precondition(ReleaseCatalog.compareURL(target, base: "a@1.0.0", head: "b@2.0.0") == nil)
        precondition(ReleaseCatalog.compareURL(target, base: "a@nightly", head: "b@nightly") == nil)
        precondition(ReleaseCatalog.compareURL(target, base: "v1\n", head: "v2") == nil)
        func titled(_ tag: String, _ title: String, _ date: String, _ extra: [String: Any] = [:]) -> HubItem { HubItem(id: tag, title: title, data: ["tag_name": tag, "published_at": date].merging(extra) { $1 }) }
        let packages = [titled("v0.3.13", "Desktop 0.3.13", "2026-10-28"), titled("v0.3.12", "Desktop 0.3.12", "2026-10-26"), titled("windows-v0.1.0", "Desktop for Windows 0.1.0", "2026-10-19")]
        precondition(ReleaseCatalog.defaultFamily(packages) == "")
        precondition(ReleaseCatalog.defaultFamily([titled("v2.0.0", "Next", "2026-10-30", ["draft": true])] + packages) == "")
        precondition(ReleaseCatalog.defaultFamily([titled("cli/v2.0.0", "CLI 2.0.0", "2026-10-30")] + packages) == "cli/")
        precondition(ReleaseCatalog.packageName(packages, family: "") == "Desktop")
        precondition(ReleaseCatalog.packageName(packages, family: "windows-") == "Desktop for Windows")
        precondition(ReleaseCatalog.packageName([titled("v1.0.0", "Desktop (v1.0.0-rc.1)", "2026-10-01")], family: "") == "Desktop")
        precondition(ReleaseCatalog.packageName([titled("api@1.0.0", "api@1.0.0", "2026-10-01")], family: "api@") == "api")
        precondition(ReleaseCatalog.packageName([titled("v1.0.0", "v1.0.0", "2026-10-01")], family: "") == "")
        let line = [titled("v1.3.0-rc.1", "rc", "2026-10-09", ["prerelease": true]), titled("v1.3.0", "draft", "2026-10-10", ["draft": true]), titled("v1.2.0", "", "2026-10-08"), titled("v1.2.0-rc.1", "", "2026-10-07", ["prerelease": true]), titled("v1.1.0", "", "2026-10-05"), titled("v1.0.0", "", "2026-10-03"), titled("v0.9.0", "", "2026-10-01"), titled("cli/v9.0.0", "", "2026-10-11")]
        let timeline = ReleaseCatalog.timeline(line, family: "")
        precondition(timeline.path.map(\.id) == ["v0.9.0", "v1.0.0", "v1.1.0", "v1.2.0", "v1.3.0-rc.1"] && timeline.stable?.id == "v1.2.0" && timeline.prerelease?.id == "v1.3.0-rc.1")
        precondition(ReleaseCatalog.timeline(Array(line.dropFirst(2)), family: "").prerelease == nil)
        precondition(ReleaseCatalog.timeline([line[0]], family: "").stable == nil && ReleaseCatalog.timeline([line[0]], family: "").prerelease?.id == "v1.3.0-rc.1")
        let names = ["Desktop-0.3.13-macOS.dmg", "Desktop-0.3.13-macOS.zip", "Desktop-0.3.13-macOS.zip.sig", "Desktop_0.3.13_x64-setup.exe", "helper-windows-x64.exe", "helper", "checksums.sha256", "latest.json"]
        let groups = ReleaseCatalog.assetGroups(names, tag: "v0.3.13") { $0 }
        precondition(groups.primary == ["Desktop-0.3.13-macOS.dmg", "Desktop-0.3.13-macOS.zip", "Desktop_0.3.13_x64-setup.exe"] && groups.other.count == 5)
        precondition(ReleaseCatalog.assetGroups(["Desktop.zip", "Desktop.zip.sha256"], tag: "nightly") { $0 }.primary == ["Desktop.zip"])
        precondition(ReleaseCatalog.assetGroups(["notes.txt", "tool"], tag: "v1.0.0") { $0 }.other.isEmpty)
        print("Release catalog: SemVer precedence, overflow, package isolation, date fallback, safe comparison URLs, package names, timelines and asset groups passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/ReleaseCatalog.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/releases"
"$TASK_TMP/releases"
