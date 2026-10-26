#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
@main struct ChangeQuestionTests {
    static func main() {
        let snapshot = ChangeQuestionSnapshot(repository: "/repo with spaces", head: "abc", scope: "Staged file", path: "src/a.swift",
            diff: String(repeating: "한", count: ChangeQuestionSnapshot.diffLimit + 300), limitations: ["Selected lines only"], impact: "test candidate: aTests.swift")
        precondition(snapshot.diff.count == ChangeQuestionSnapshot.diffLimit)
        precondition(snapshot.omitted == 300)
        precondition(snapshot.context.contains("tests were NOT run"))
        precondition(snapshot.context.contains("src/a.swift"))
        precondition(snapshot.context.contains("300 characters omitted"))
        let messages = (0..<20).map { ChangeQuestionMessage(isUser: $0 % 2 == 0, text: String(repeating: "h", count: 20_000)) }
        let prompt = snapshot.prompt(question: "Which tests?", messages: messages)
        precondition(prompt.count < 170_000)
        precondition(prompt.hasSuffix("Which tests?"))
        precondition(ChangeQuestionSnapshot.boundedAnswer(String(repeating: "a", count: 30_000)).count == ChangeQuestionSnapshot.answerLimit)
        let full = ChangeQuestionSnapshot(repository: "repo", head: "h", scope: "Unstaged file", path: "a", diff: "-before\n+after")
        let followup = full.prompt(question: "Why?", messages: [ChangeQuestionMessage(isUser: true, text: "Risks?"), ChangeQuestionMessage(isUser: false, text: "Possible issue")])
        precondition(followup.contains("Risks?"))
        precondition(followup.contains("Possible issue"))
        precondition(followup.contains("+after"))
        print("AI question snapshots: scope, Unicode limits, truncation, estimate labels and bounded followup context passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/ChangeQuestion.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-change-question"
"$TASK_TMP/test-change-question"
