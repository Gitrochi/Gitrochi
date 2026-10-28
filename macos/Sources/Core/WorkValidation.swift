import Foundation

/// Revision-bound execution evidence, mirrored by Windows work-validation.ts.
struct ValidationBinding: Codable, Equatable {
    var schemaVersion = 1
    let runID: String
    let head: String?
    let before: String
    var after: String?
    let candidates: [String]
    let observedAt: String
}

struct WorkFlowEvidence: Codable, Identifiable {
    let runID: String
    let state: String
    let freshness: String
    let executed: Int?
    let passed: Int?
    let failed: Int?
    var id: String { runID }

    static func read(_ record: FlowJSON, binding: ValidationBinding?, currentStamp: String) -> Self {
        let runID = record["runId"].string ?? ""
        let state = record["state"].string ?? "UNKNOWN"
        let running = ["PENDING", "PREFLIGHT", "RUNNING", "ROLLING_BACK"].contains(state)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let finished = record["finishedAt"].string.flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        let terminal = ["SUCCEEDED", "FAILED", "REJECTED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED"].contains(state) && finished != nil
        let bound = binding?.schemaVersion == 1 && binding?.runID == runID
        let current = bound && terminal && binding?.head == record["git"]["sha"].string && binding?.before.hasPrefix("untracked:") == false && binding?.before.hasPrefix("uncertified:") == false && binding?.before == binding?.after && binding?.after == currentStamp
        func count(_ value: FlowJSON) -> Int? {
            guard case .number(let number) = value, number.isFinite, number >= 0, number < Double(Int.max), number.rounded() == number else { return nil }
            return Int(number)
        }
        let tests = record["nodes"].array.map { $0["tests"] }.filter { count($0["executed"]) != nil }
        func total(_ key: String) -> Int? {
            guard !tests.isEmpty, tests.allSatisfy({ count($0[key]) != nil }) else { return nil }
            var sum = 0
            for node in tests { let next = sum.addingReportingOverflow(count(node[key])!); guard !next.overflow else { return nil }; sum = next.partialValue }
            return sum
        }
        return Self(runID: runID, state: state, freshness: running ? "running" : !bound || binding?.after == nil || !terminal ? "unbound" : current ? "current" : "stale", executed: total("executed"), passed: total("passed"), failed: total("failed"))
    }
}

struct WorkAgentAssignment: Codable, Equatable, Identifiable {
    let sessionID: String
    var taskID = ""
    var goal = ""
    var paths: [String] = []
    var remaining = ""
    var id: String { sessionID }
}

struct WorkAgentObservation: Codable {
    let taskID: String
    let kind: String
    let state: String
    let branch: String?
    let observedAt: String
}

enum WorkValidation {
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.unicodeScalars.contains { $0.value < 32 } && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func overlaps(_ assignments: [WorkAgentAssignment]) -> [String] {
        assignments.enumerated().flatMap { index, a in
            assignments.dropFirst(index + 1).compactMap { b in
                let paths = Set(a.paths.flatMap { left in b.paths.filter { right in left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/") }.map { right in left.count >= right.count ? left : right } }).sorted()
                return paths.isEmpty ? nil : a.sessionID + " ↔ " + b.sessionID + ": " + paths.joined(separator: ", ")
            }
        }
    }

    static func handoff(head: String?, stamp: String, appVersion: String = "unknown", changedPaths: [String] = [], candidates: [String], evidence: [WorkFlowEvidence], assignments: [WorkAgentAssignment], sessions: [WorkAgentObservation] = []) -> String {
        struct Report: Encodable {
            let schemaVersion = 1
            let kind = "gitrochi-work-handoff"
            let tool: [String: String]
            let revision: String?
            let scope = "tracked-worktree"
            let contentStamp: String
            let observedAt: String
            let candidates: [String]
            let changedPaths: [String]
            let verification: [WorkFlowEvidence]
            let assignments: [WorkAgentAssignment]
            let sessions: [WorkAgentObservation]
            let limitations = ["Candidates are not proof of test execution or coverage.", "An unchanged before/after stamp does not freeze the repository during a run.", "Untracked file contents are excluded; untracked changes prevent a verified current result."]
        }
        let report = Report(tool: ["name": "Gitrochi", "version": appVersion], revision: head, contentStamp: stamp, observedAt: ISO8601DateFormatter().string(from: Date()), candidates: candidates.filter(safePath), changedPaths: changedPaths.filter(safePath), verification: evidence, assignments: assignments, sessions: sessions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report), let object = try? JSONSerialization.jsonObject(with: data) else { return "" }
        func scrub(_ value: Any) -> Any {
            if var text = value as? String {
                for pattern in [#"(?:[A-Za-z]:[\\/]|/(?:Users|home)/)[^\s\"<>]+"#, #"\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|glpat-[A-Za-z0-9_-]{12,}|grh_[A-Za-z0-9_-]{12,}|sk-[A-Za-z0-9_-]{16,})\b"#] { text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
                return text
            }
            if let array = value as? [Any] { return array.map(scrub) }
            if let dictionary = value as? [String: Any] { return dictionary.filter { $0.key != "sessionID" }.mapValues(scrub) }
            return value
        }
        guard let clean = try? JSONSerialization.data(withJSONObject: scrub(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: clean, as: UTF8.self)
    }
}
