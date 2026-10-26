#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
// 독립적인 resolver 검증에는 네트워크·계정 저장소가 필요하지 않다.
enum Gitch {
    struct Preflight { let result: String; let checks: [Check] }
    struct Check { let level: String; let code: String; let message: String }
}
@main struct PushReviewTests {
    static func main() throws {
        func resolve(_ config: PushReview.Config, current: String? = "topic", override: String? = nil) throws -> (remote: String, destination: String, setUpstream: Bool) {
            try PushReview.destination(config: config, remotes: ["origin", "fork"], branch: "topic", currentBranch: current, remoteOverride: override)
        }
        var rejected = 0
        func rejects(_ config: PushReview.Config, current: String? = "topic") {
            do { _ = try resolve(config, current: current); fatalError("Accepted invalid push configuration") } catch { rejected += 1 }
        }
        let nul = PushReview.config("remote.origin.push\ntopic:review\0remote.origin.push\nother:other\0")
        precondition(nul["remote.origin.push"] == ["topic:review", "other:other"])
        let selectedRemote = try resolve(["branch.topic.pushremote": ["fork"], "remote.pushdefault": ["origin"]])
        precondition(selectedRemote.remote == "fork")
        let upstream = try resolve(["push.default": ["upstream"], "branch.topic.remote": ["origin"], "branch.topic.merge": ["refs/heads/review"]])
        precondition(upstream.destination == "refs/heads/review" && !upstream.setUpstream)
        let exact = try resolve(["remote.origin.push": ["refs/heads/topic:refs/heads/review"]], current: "main")
        precondition(exact.destination == "refs/heads/review")
        let pr = try resolve(["branch.topic.pushremote": ["fork"], "remote.origin.push": ["topic:other"]], override: "origin")
        precondition(pr.remote == "origin" && pr.destination == "refs/heads/topic")
        rejects(["push.default": ["matching"]])
        rejects(["push.default": ["nothing"]])
        rejects(["push.default": ["upstream"]])
        rejects(["branch.topic.remote": ["origin"], "branch.topic.merge": ["refs/heads/review"]])
        rejects(["remote.origin.push": ["refs/heads/*:refs/heads/*"]])
        rejects(["remote.origin.push": ["+topic:topic"]])
        rejects(["remote.origin.push": ["topic:topic", "other:other"]])
        rejects(["remote.origin.push": ["HEAD:topic"]], current: "main")
        rejects(["remote.origin.push": ["topic:refs/tags/release"]])
        rejects(["remote.origin.mirror": ["true"]])
        precondition(PushReview.displayURL("fatal: https://name:secret@example.com/repo.git?token=abc&x=1") == "fatal: https://[redacted]@example.com/repo.git?token=[redacted]&x=1")
        precondition(PushReview.configStamp(["remote.origin.pushurl": ["one"]]) != PushReview.configStamp(["remote.origin.pushurl": ["two"]]))
        let preflight = Gitch.Preflight(result: "OK", checks: [])
        let plan = PushReviewPlan(repo: URL(fileURLWithPath: "/demo"), branch: "topic", sourceOID: String(repeating: "a", count: 40), remote: "fork", destination: "refs/heads/topic", pushURL: "ssh://example.com/repo", destinationOID: String(repeating: "b", count: 40), force: true, setUpstream: false, stamp: "", author: "", account: "", credentialAccount: "", preflight: preflight, commits: [], commitCount: 0, files: [], fileCount: 0, fileScope: "changes", comparisonBase: nil)
        precondition(plan.arguments.contains("--force-with-lease=refs/heads/topic:" + String(repeating: "b", count: 40)))
        precondition(plan.arguments.last == String(repeating: "a", count: 40) + ":refs/heads/topic")
        print("PushReview passed: destinations, credentials, immutable source, force lease and \(rejected) blocked configurations")
    }
}
SWIFT
swiftc -parse-as-library "$ROOT/Sources/Core/PushReview.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-push-review"
"$TASK_TMP/test-push-review"
