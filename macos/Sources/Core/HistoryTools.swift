import Foundation
import Observation

struct RevisionComparison {
    let left: String
    let right: String
    let base: String
    let mergeBase: Bool
    var files: [FileChange]
    var stats: [String: LineStat]
}

enum BatchCommitAction: String, CaseIterable, Identifiable {
    case cherryPick = "cherry-pick", revert, squash, drop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cherryPick: return String(localized: "Cherry-pick selected commits")
        case .revert: return String(localized: "Revert selected commits")
        case .squash: return String(localized: "Squash selected commits")
        case .drop: return String(localized: "Drop selected commits")
        }
    }
}
struct BatchCommitItem: Identifiable {
    let sha: String
    let parents: [String]
    let subject: String
    let author: String
    let message: String
    var id: String { sha }
}
struct LineHistoryEntry: Identifiable {
    let sha: String
    let author: String
    let date: String
    let subject: String
    let patch: String
    var id: String { sha }
}

/// 새 창 요청과 저장소 전환마다 토큰을 바꿔 늦은 응답이 새 화면을 덮지 못하게 한다.
@MainActor @Observable final class HistoryToolsState {
    var generation = UUID()
    var selected: [String] = []
    var anchor: String?
    var left = "HEAD~1"
    var right = "HEAD"
    var useMergeBase = false
    var comparison: RevisionComparison?
    var comparisonPath: String?
    var comparisonPatch = ""
    var comparisonLoading = false
    var comparisonError: String?
    var comparisonFileToken = UUID()
    var batch: [BatchCommitItem] = []
    var batchHead = ""
    var batchBranch = ""
    var batchAction: BatchCommitAction = .cherryPick
    var batchLoading = false
    var batchError: String?
    var linePath = ""
    var lineRevision = "HEAD"
    var lineStart = 1
    var lineEnd = 1
    var functionName = ""
    var lineEntries: [LineHistoryEntry] = []
    var lineSelected: String?
    var lineLoading = false
    var lineError: String?
    var lineTruncated = false
    func reset() {
        generation = UUID()
        selected = []; anchor = nil
        comparison = nil; comparisonPath = nil; comparisonPatch = ""; comparisonLoading = false; comparisonError = nil
        batch = []; batchLoading = false; batchError = nil
        lineEntries = []; lineLoading = false; lineError = nil
    }
}

enum HistoryTools {
    static func operationInProgress(_ gitDir: URL?) -> Bool {
        guard let gitDir else { return true }
        return ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"].contains {
            FileManager.default.fileExists(atPath: gitDir.appendingPathComponent($0).path)
        }
    }
    static func validRevision(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 1024 && !value.hasPrefix("-") && !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 }
    }
    static func objectID(_ value: String) -> Bool { (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isHexDigit } }
    static func range(path: String, start: Int, end: Int, function: String = "") throws -> String {
        guard !path.isEmpty, !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { throw HistoryToolsError.invalidFile }
        let name = function.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            guard name.count <= 200, !name.contains(":"), !name.contains("\n"), !name.contains("\r"), !name.contains("\0") else { throw HistoryToolsError.invalidFunction }
            let special = Set(".*+?^${}()|[]\\")
            let escaped = name.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
            return ":\(escaped):\(path)"
        }
        guard start > 0, end >= start, end <= 10_000_000 else { throw HistoryToolsError.invalidRange }
        return "\(start),\(end):\(path)"
    }
    static func lineHistory(_ output: String) -> [LineHistoryEntry] {
        output.components(separatedBy: "\u{1e}").compactMap { record in
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let fields = (parts.first.map(String.init) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard fields.count >= 4, objectID(fields[0]) else { return nil }
            return LineHistoryEntry(sha: fields[0], author: fields[1], date: fields[2], subject: fields.dropFirst(3).joined(separator: "\u{1f}"), patch: parts.count > 1 ? String(parts[1]) : "")
        }
    }
}
enum HistoryToolsError: LocalizedError {
    case invalidRevision, invalidFile, invalidRange, invalidFunction, changed, dirty, merge, noncontiguous
    var errorDescription: String? {
        switch self {
        case .invalidRevision: return String(localized: "Enter a branch, tag or commit without spaces or leading dashes.")
        case .invalidFile: return String(localized: "Choose a committed file.")
        case .invalidRange: return String(localized: "Enter a valid line range (1 or greater).")
        case .invalidFunction: return String(localized: "Enter a function name without colons or newlines.")
        case .changed: return String(localized: "The repository changed. Open this review again.")
        case .dirty: return String(localized: "Commit or stash changes and finish the current Git operation first.")
        case .merge: return String(localized: "Merge commits need a mainline choice. Select non-merge commits.")
        case .noncontiguous: return String(localized: "Squash requires adjacent commits on the current branch.")
        }
    }
}
