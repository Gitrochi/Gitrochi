#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-work-validation.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
enum TestTool { case git }
final class ToolPaths { static let shared = ToolPaths(); func get(_ tool: TestTool) -> String? { nil } }
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

@main struct WorkValidationTests {
    static func main() async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
        let head = String(repeating: "a", count: 40)
        let record = try JSONDecoder().decode(FlowJSON.self, from: Data("{\"runId\":\"run-1\",\"state\":\"SUCCEEDED\",\"finishedAt\":\"2026-01-01T00:00:10.123Z\",\"git\":{\"sha\":\"\(head)\"},\"nodes\":[{\"tests\":{\"executed\":4,\"passed\":3,\"failed\":1}}]}".utf8))
        let binding = ValidationBinding(runID: "run-1", head: head, before: "content", after: "content", candidates: ["tests/a.swift"], observedAt: "2026-01-01T00:00:00Z")
        require(WorkFlowEvidence.read(record, binding: binding, currentStamp: "content").freshness == "current", "Matching evidence must bind")
        require(WorkFlowEvidence.read(record, binding: binding, currentStamp: "changed").freshness == "stale", "Changed content must not pass")
        require(WorkFlowEvidence.read(record, binding: nil, currentStamp: "content").freshness == "unbound", "Unknown historical runs remain unbound")
        var missing = binding; missing.after = nil
        require(WorkFlowEvidence.read(record, binding: missing, currentStamp: "content").freshness == "unbound", "Missing end observations remain unbound")
        let unknown = FlowJSON.object(["nodes": .array([.object(["tests": .object(["executed": .number(2)])])])])
        require(WorkFlowEvidence.read(unknown, binding: nil, currentStamp: "").passed == nil, "Absent counts must not become zero")
        let huge = FlowJSON.object(["nodes": .array([.object(["tests": .object(["executed": .number(1e100)])])])])
        require(WorkFlowEvidence.read(huge, binding: nil, currentStamp: "").executed == nil, "Malformed counts cannot crash conversion")
        require(!WorkValidation.safePath("../outside") && !WorkValidation.safePath("C:/outside") && WorkValidation.safePath("src/문서.swift"), "Only relative evidence paths are accepted")
        let a = WorkAgentAssignment(sessionID: "a", taskID: "1", paths: ["src/core"])
        let b = WorkAgentAssignment(sessionID: "b", taskID: "2", paths: ["src/core/model.swift"])
        require(WorkValidation.overlaps([a, b]).count == 1, "Explicit nested ownership overlaps")
        let report = WorkValidation.handoff(head: head, stamp: "content", candidates: ["tests/a.swift", "../outside"], evidence: [WorkFlowEvidence.read(record, binding: binding, currentStamp: "content")], assignments: [a])
        require(report.contains(head) && !report.contains("../outside") && report.contains("not proof"), "Report preserves provenance and limitations")
        let repo = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("unicode 작업")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Git.run(["init", "-q"], in: repo)
        let file = repo.appendingPathComponent("source.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Git.run(["add", "--", "source.txt"], in: repo)
        let first = try await WorkStamp.read(in: repo)
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        let second = try await WorkStamp.read(in: repo)
        require(first.stamp != second.stamp && first.head == nil, "Unborn repository unstaged edits invalidate content")
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let untracked = try await WorkStamp.read(in: repo)
        require(untracked.stamp.hasPrefix("untracked:"), "Unknown untracked bytes cannot be certified")
        _ = try await Git.run(["update-index", "--assume-unchanged", "source.txt"], in: repo)
        let hidden = try await WorkStamp.read(in: repo)
        require(hidden.stamp.hasPrefix("uncertified:"), "Hidden tracked files cannot be certified by status")
        print("Work validation evidence, ownership, export and actual Git stamp checks passed")
    }
}
SWIFT
swiftc -parse-as-library "$ROOT/Sources/Core/FlowModels.swift" "$ROOT/Sources/Core/WorkValidation.swift" "$ROOT/Sources/Core/Git.swift" "$ROOT/Sources/Services/WorkStamp.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check" "$TASK_TMP"
