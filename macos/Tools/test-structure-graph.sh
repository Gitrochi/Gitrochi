#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-structure-graph.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
enum Gitch { struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } } }
func require(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let document = "<!doctype html><html><head></head><body><script id=\"graph-data\" type=\"application/json\">{}</script></body></html>"
let actions = "{\"schemaVersion\":1,\"snapshotID\":\"fixture\",\"actions\":[{\"kind\":\"nodes\",\"nodeIDs\":[\"</script><script>bad()</script>\"]}]}"
let html = try StructureGraphDocument.prepare(document, actionsJSON: actions)
require(html.contains("connect-src 'none'") && html.contains("base-uri 'none'"), "The graph document must stay offline")
require(!html.contains("<script>bad()"), "Action values cannot close the inert JSON element")
let repository = URL(fileURLWithPath: "/fixture/repository", isDirectory: true)
func link(_ suffix: String = "") -> URL { URL(string: "gitrochi://open?repo=%2Ffixture%2Frepository&view=graph" + suffix)! }
require(StructureGraphDocument.appLink(link("&file=src%2Fmain.swift&line=2"), repository: repository), "Contained file links must work")
for suffix in ["&file=..%2Fsecret", "&file=%2Fabsolute", "&file=bad%5Cpath", "&line=0", "&command=run", "&view=terminal", "&commit=HEAD"] {
    require(!StructureGraphDocument.appLink(link(suffix), repository: repository), "Unsafe graph navigation must be rejected")
}
require(!StructureGraphDocument.appLink(link(), repository: URL(fileURLWithPath: "/different")), "A graph cannot change repositories")
print("Structure graph document and navigation checks passed")
SWIFT
swiftc "$ROOT/Sources/Core/StructureGraphDocument.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-structure-graph"
"$TASK_TMP/test-structure-graph"
