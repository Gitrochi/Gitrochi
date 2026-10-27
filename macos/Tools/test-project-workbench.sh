#!/usr/bin/env bash
# Exercise production project filters and local task links without Git, credentials or persistent preferences.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct HostingError: LocalizedError { let status: Int; var errorDescription: String? { "HTTP \(status)" } }
enum Hosting {
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest { fatalError("Unexpected credential or network request") }
    static func data(_ request: URLRequest) async throws -> Data { fatalError("Unexpected network request") }
}

/// Production persistence still exercises its JSON encoding; the backing store stays entirely in memory.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    func cloned() -> MemoryDefaults { let result = MemoryDefaults(); result.values = values; return result }
    func corruptData() { for key in values.keys { values[key] = Data("invalid JSON".utf8) } }
}

@main struct ProjectWorkbenchTests {
    @MainActor static func main() throws {
        func row(_ id: String, _ title: String, kind: HubProjectRowKind = .issue, number: Int? = nil, repository: String = "team/repo", assignees: [String] = [], archived: Bool = false, updated: String = "2026-10-26T10:00:00Z", body: String = "", labels: [String] = []) -> HubProjectRow {
            HubProjectRow(id: id, title: title, body: body, url: "", contentID: id, statuses: [:], labels: labels, kind: kind, number: number, repository: repository, assignees: assignees, updatedAt: updated, archived: archived)
        }
        let rows = [
            row("issue", "Fix auth regression", number: 20, repository: "Team/Repo", assignees: ["Alex"], updated: "2026-10-26T11:00:00Z", body: "Preserve saved permissions", labels: ["Security", "Release"]),
            row("pr", "Ship dashboard", kind: .pullRequest, number: 5, repository: "team/other", assignees: ["sam"], updated: "2026-10-26T12:00:00Z"),
            row("draft", "Task 2", kind: .draft, repository: "", updated: "2026-10-26T09:00:00Z"),
            row("draft-ten", "Task 10", kind: .draft, repository: "", updated: "2026-10-26T09:00:00Z"),
            row("archived", "Archived task", number: 1, assignees: ["alex"], archived: true, updated: "2026-10-26T13:00:00Z"),
            row("private", "Private task", kind: .redacted, repository: "", updated: "2026-10-26T08:00:00Z")
        ]
        func ids(_ filter: ProjectWorkbenchFilter, repository: String = "team/repo", username: String = "alex") -> [String] { filter.apply(rows, repository: repository, username: username).map(\.id) }
        var filter = ProjectWorkbenchFilter()
        precondition(ids(filter) == ["pr", "issue", "draft", "draft-ten", "private"], "Default view must hide archived items and order dates stably")
        filter.onlyCurrentRepository = true
        precondition(ids(filter) == ["issue"] && ids(filter, repository: "") == [], "Repository filtering must match the exact owner/name, case insensitively")
        precondition(ids(filter, repository: "team/repository") == [], "Repository prefixes must not match")
        filter = ProjectWorkbenchFilter(); filter.onlyMine = true
        precondition(ids(filter, username: "ALEX") == ["issue"] && ids(filter, username: "") == [], "Mine means an explicit assignee match")
        filter.includeArchived = true
        precondition(ids(filter) == ["archived", "issue"])
        filter.onlyCurrentRepository = true; filter.kind = "pullRequest"
        precondition(ids(filter) == [], "Filters must intersect rather than replace each other")
        filter = ProjectWorkbenchFilter(); filter.kind = "draft"
        precondition(ids(filter) == ["draft", "draft-ten"])
        filter.kind = "redacted"; precondition(ids(filter) == ["private"])
        filter = ProjectWorkbenchFilter(); filter.query = " SECURITY   @missing "
        precondition(ids(filter) == [], "Every search token must match")
        filter.query = " security  ALEX #20 saved TEAM/repo "
        precondition(ids(filter) == ["issue"], "Search must include title, body, repository, number, labels and assignees")
        filter.query = "auth regression"; precondition(ids(filter) == ["issue"])
        filter.query = "\n\t "; precondition(ids(filter) == ["pr", "issue", "draft", "draft-ten", "private"])
        filter = ProjectWorkbenchFilter(); filter.sort = "title"
        precondition(ids(filter) == ["issue", "private", "pr", "draft", "draft-ten"], "Title ordering must use natural numeric order")
        filter.sort = "number"
        precondition(ids(filter) == ["pr", "issue", "draft", "draft-ten", "private"], "Unnumbered drafts must follow numbered work")
        filter.includeArchived = true
        precondition(ids(filter).first == "archived")
        let restoredFilter = try JSONDecoder().decode(ProjectWorkbenchFilter.self, from: JSONEncoder().encode(filter))
        precondition(restoredFilter == filter)
        filter = ProjectWorkbenchFilter(); filter.sort = "manual"
        precondition(ids(filter) == ["issue", "pr", "draft", "draft-ten", "private"], "Manual order must preserve the server's item positions after filtering")

        let leapDay = ProjectWorkbench.date("2024-02-29")!
        precondition(ProjectWorkbench.date("2024-03-01")!.timeIntervalSince(leapDay) == 86400, "Date fields must use UTC calendar dates")
        for value in [nil, "", "2026-02-29", "2026-02-30", "2026-13-01", "2026-00-01", "2026-01-00", "2026-1-01", "2026-01-1", "2026-10-26T00:00:00Z", " 2026-10-26", "2026-10-26 ", "２０２６-１０-２６", "not-a-date"] as [String?] {
            precondition(ProjectWorkbench.date(value) == nil, "Malformed or impossible task dates must stay unscheduled")
        }
        precondition(ProjectWorkbench.date("2026-10-26") != nil)

        precondition(ProjectWorkbench.suggestedBranch(number: 42, title: "Fix café layout") == "feature/42-fix-cafe-layout")
        precondition(ProjectWorkbench.suggestedBranch(number: nil, title: "!!!") == "feature/task")
        precondition(ProjectWorkbench.suggestedBranch(number: 7, title: String(repeating: "a", count: 100)) == "feature/7-" + String(repeating: "a", count: 48))
        let hostileTitles = ["../../refs/heads/main.lock", "--upload-pack=$(touch marker);`whoami`", "auth@{broken}:*?[\\]~^", "\n\r\tspaces and control\u{0}characters", "Emoji 🚀 and 한글", ".hidden..branch.lock", "Ｗｉｄｅ Café"]
        for title in hostileTitles {
            let branch = ProjectWorkbench.suggestedBranch(number: 10, title: title)
            precondition(branch.hasPrefix("feature/10-") && branch.count <= 59)
            precondition(!branch.contains("..") && !branch.contains("@{") && !branch.hasSuffix(".lock"))
            precondition(branch.rangeOfCharacter(from: CharacterSet(charactersIn: " ~^:?*[\\\n\r\t;$()`")) == nil, "Suggested branch must never carry Git or shell metacharacters")
        }

        let defaults = MemoryDefaults(), worktree = "/fixture/worktree", otherWorktree = "/fixture/other-worktree"
        let task = ProjectTaskReference(id: "task-1", title: "Build task", url: "https://github.com/team/repo/issues/42", number: 42, repository: "Team/Repo", host: "github.com")
        ProjectTaskLinks.remember(task, repositoryPath: worktree, branch: "feature/z", defaults: defaults)
        ProjectTaskLinks.remember(task, repositoryPath: worktree, branch: "feature/a", defaults: defaults)
        let persisted = defaults.cloned()
        precondition(ProjectTaskLinks.branches(taskID: "task-1", repositoryPath: worktree, repository: "team/repo", host: "GITHUB.COM", defaults: persisted) == ["feature/a", "feature/z"], "Stored links must round-trip with deterministic ordering")
        for (id, path, repository, host) in [("task-2", worktree, "team/repo", "github.com"), ("task-1", otherWorktree, "team/repo", "github.com"), ("task-1", worktree, "team/other", "github.com"), ("task-1", worktree, "team/repo", "enterprise.test")] {
            precondition(ProjectTaskLinks.branches(taskID: id, repositoryPath: path, repository: repository, host: host, defaults: persisted).isEmpty, "Links must not cross task, worktree, repository or hosting boundaries")
        }
        ProjectTaskLinks.remember(task, repositoryPath: otherWorktree, branch: "feature/other", defaults: persisted)
        precondition(ProjectTaskLinks.branches(taskID: task.id, repositoryPath: otherWorktree, repository: task.repository, host: task.host, defaults: persisted) == ["feature/other"])
        var reassigned = task; reassigned.id = "task-2"
        ProjectTaskLinks.remember(reassigned, repositoryPath: worktree, branch: "feature/a", defaults: persisted)
        precondition(ProjectTaskLinks.branches(taskID: task.id, repositoryPath: worktree, repository: task.repository, host: task.host, defaults: persisted) == ["feature/z"], "Reassigning one branch must preserve its siblings")
        persisted.corruptData()
        precondition(ProjectTaskLinks.branches(taskID: task.id, repositoryPath: worktree, repository: task.repository, host: task.host, defaults: persisted).isEmpty)
        ProjectTaskLinks.remember(task, repositoryPath: worktree, branch: "feature/recovered", defaults: persisted)
        precondition(ProjectTaskLinks.branches(taskID: task.id, repositoryPath: worktree, repository: task.repository, host: task.host, defaults: persisted) == ["feature/recovered"])
        print("Project workbench: repository, assignee, archived, type and tokenized filters; ordering; strict dates; safe branches; isolated task-link persistence passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "$ROOT/Sources/Core/ProjectWorkbench.swift" "$ROOT/Sources/Core/ProjectTaskReference.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-workbench"
"$TASK_TMP/test-project-workbench"
