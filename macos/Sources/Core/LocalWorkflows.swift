import Foundation

struct SafetyCopy: Identifiable, Equatable {
    let id: String
    let worktree: String
    let index: String
    let head: String
    var created: Date { Date(timeIntervalSince1970: (Double(id.split(separator: "-").first ?? "0") ?? 0) / 1000) }
}
struct RecoveryReflog: Identifiable {
    let id = UUID()
    let sha: String
    let selector: String
    let message: String
    let date: String
}
struct ManagedSubmodule: Identifiable {
    var id: String { path }
    let path: String
    let sha: String
    let status: String
    let url: String
    let configName: String
}
struct ManagedLFSLock: Identifiable { let id: String; let path: String; let owner: String }
struct LocalWorkflowState {
    var generation = UUID()
    var loading = false
    var error: String?
    var notice: String?
    var recovery: [SafetyCopy] = []
    var reflog: [RecoveryReflog] = []
    var preview = ""
    var lfsAvailable = false
    var lfsFiles = ""
    var lfsPatterns = ""
    var lfsLocks: [ManagedLFSLock] = []
    var submodules: [ManagedSubmodule] = []
    var bisectActive = false
    var bisectLog = ""
    var bisectCurrent = ""
    var bisectResult = ""
    mutating func reset() { self = LocalWorkflowState() }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("-") && !path.hasPrefix("/") && !path.contains("\\") && path.rangeOfCharacter(from: .controlCharacters) == nil
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }
            && path.range(of: "^[A-Za-z]:", options: .regularExpression) == nil
    }
    static func safeURL(_ value: String) -> Bool {
        guard !value.contains("%"), value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        if value.hasPrefix("https://"), let url = URL(string: value) { return url.host != nil && url.user == nil && url.password == nil }
        if value.contains("://") { return value.range(of: "^ssh://([A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/.+", options: .regularExpression) != nil }
        return value.range(of: "^([A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9.-]*:.+", options: .regularExpression) != nil && !value.hasPrefix("file:") && !value.hasPrefix("ext:")
    }
    static func parseSafety(_ output: String) -> [SafetyCopy] {
        var groups: [String: [String: String]] = [:]
        for line in output.split(separator: "\n") {
            let values = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard values.count == 2, values[0].hasPrefix("refs/gitrochi/safety/") else { continue }
            var pieces = values[0].dropFirst("refs/gitrochi/safety/".count).split(separator: "/").map(String.init)
            if pieces.count == 3 { pieces.removeFirst() }
            guard pieces.count == 2, ["worktree", "index", "head"].contains(pieces[1]), values[1].range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil else { continue }
            groups[pieces[0], default: [:]][pieces[1]] = values[1]
        }
        return groups.compactMap { id, values in
            guard let worktree = values["worktree"], let index = values["index"], let head = values["head"] else { return nil }
            return SafetyCopy(id: id, worktree: worktree, index: index, head: head)
        }.sorted { $0.id > $1.id }
    }
}
