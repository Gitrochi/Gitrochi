#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

@main struct CommitReviewTests {
    static func main() throws {
        var fixture: [String: Any] = [
            "schemaVersion": 1, "tool": "gitch graph review", "scope": "staged",
            "stamp": "staged-content-a", "snapshot": "tree-a", "headSha": "head-a", "branch": "feature/example", "stale": false,
            "changed": [["path": "source/space ' quote.swift", "status": "M", "analyzed": true]],
            "direct": [["path": "source/consumer.swift", "depth": 1, "via": ["source/space ' quote.swift"], "heuristic": false]],
            "indirect": [["path": "source/app.swift", "depth": 2, "via": ["source/consumer.swift"], "heuristic": true]],
            "tests": [["path": "tests/example.test.ts", "kind": "name", "depth": 0, "heuristic": true]],
            "coverage": ["changed": 1, "analyzed": 1, "unsupported": 0], "limitations": ["Name matches are candidates."]
        ]
        func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func stamp(_ content: String, head: String = "head-a") throws -> CommitReviewStamp {
            try CommitReviewStamp.decode(data(["schemaVersion": 1, "scope": "staged", "stamp": content, "headSha": head]))
        }
        let report = try CommitReviewReport.decode(data(fixture))
        precondition(report.changed.first?.path == "source/space ' quote.swift")
        precondition(report.direct.first?.depth == 1 && report.indirect.first?.heuristic == true)
        precondition(report.tests.first?.kind == .name)
        let same = try stamp("staged-content-a")
        let restaged = try stamp("staged-content-b")
        let newHead = try stamp("staged-content-a", head: "head-b")
        precondition(report.isCurrent(comparedTo: same))
        precondition(!report.isCurrent(comparedTo: restaged), "restaging the same path must invalidate the result")
        precondition(!report.isCurrent(comparedTo: newHead), "a new HEAD must invalidate the result")
        fixture["headSha"] = ""
        let initialCommit = try CommitReviewReport.decode(data(fixture))
        let initialStamp = try stamp("staged-content-a", head: "")
        precondition(initialCommit.isCurrent(comparedTo: initialStamp), "an initial commit without HEAD must be supported")
        fixture["headSha"] = "head-a"
        fixture["stale"] = true
        let raced = try CommitReviewReport.decode(data(fixture))
        precondition(!raced.isCurrent(comparedTo: same), "a CLI-detected race cannot become current")
        fixture["stale"] = false
        fixture["scope"] = "working"
        do { _ = try CommitReviewReport.decode(data(fixture)); fatalError("working tree report accepted as staged") } catch {}
        fixture["scope"] = "staged"
        fixture["schemaVersion"] = 2
        do { _ = try CommitReviewReport.decode(data(fixture)); fatalError("unknown report schema accepted") } catch {}
        fixture["schemaVersion"] = 1
        fixture.removeValue(forKey: "tests")
        do { _ = try CommitReviewReport.decode(data(fixture)); fatalError("partial report accepted as complete") } catch {}
        do {
            _ = try CommitReviewStamp.decode(data(["schemaVersion": 1, "scope": "working", "stamp": "x", "headSha": "y"]))
            fatalError("working tree stamp accepted")
        } catch {}
        print("Staged review: JSON contract, candidate evidence, filename preservation and staged/HEAD/race invalidation passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/CommitReview.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-commit-review"
"$TASK_TMP/test-commit-review"
