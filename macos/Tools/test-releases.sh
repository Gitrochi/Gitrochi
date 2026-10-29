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
        print("Release catalog: SemVer precedence, overflow, package isolation, date fallback and safe comparison URLs passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/ReleaseCatalog.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/releases"
"$TASK_TMP/releases"
