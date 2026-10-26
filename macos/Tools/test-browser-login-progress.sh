#!/usr/bin/env bash
# 가짜 시계로 준비·대기·승인 전환과 무한 대기 방지를 검사한다. 인증 호출은 하지 않는다.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
@main struct LoginProgressTests {
    static func main() {
        let start = Date(timeIntervalSince1970: 1000)
        var progress = GitHubLoginProgress(startedAt: start)
        precondition(GitHubLoginProgress.phase(nil, code: nil) == .preparing)
        precondition(GitHubLoginProgress.phase("queued", code: nil) == .queued)
        precondition(GitHubLoginProgress.phase("queued", code: "FIXT-CODE") == .approval)
        precondition(GitHubLoginProgress.phase("approval", code: "") == .preparing)
        precondition(progress.failure(phase: .queued, now: start.addingTimeInterval(600)) == nil)
        precondition(progress.failure(phase: .preparing, now: start.addingTimeInterval(650)) == nil)
        precondition(progress.failure(phase: .preparing, now: start.addingTimeInterval(739)) == nil)
        precondition(progress.failure(phase: .preparing, now: start.addingTimeInterval(740)) == .preparation)
        precondition(progress.failure(phase: .approval, now: start.addingTimeInterval(740)) == nil)
        precondition(progress.failure(phase: .approval, now: start.addingTimeInterval(900)) == .expired)
        var retry = GitHubLoginProgress(startedAt: start)
        precondition(retry.failure(phase: .preparing, now: start) == nil)
        precondition(retry.failure(phase: .queued, now: start.addingTimeInterval(80)) == nil)
        precondition(retry.failure(phase: .preparing, now: start.addingTimeInterval(160)) == nil)
        precondition(retry.failure(phase: .preparing, now: start.addingTimeInterval(250)) == .preparation)
        print("PASS: code preparation, queued sign-ins, approval, recovery and finite deadlines without authentication")
    }
}
SWIFT
swiftc -parse-as-library "$TASK_ROOT/Sources/Core/GitHubLoginProgress.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/progress-tests"
"$TASK_TMP/progress-tests"
