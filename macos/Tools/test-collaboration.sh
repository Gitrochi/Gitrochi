#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum Provider { case github, gitlab }
struct RepoTarget { let provider: Provider; let host: String; let path: String }
struct PullRequest { let number: Int; let title: String; let author: String; let source: String; let target: String; let url: String; let isDraft: Bool; let updated: Date?; let body: String; let headSHA: String?; let fromFork: Bool; var comments: Int? = nil; var reviewRequested = false }
enum Hosting {
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected request") }
    static func request(_ p: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = method
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }; return r
    }
    static func data(_ r: URLRequest) async throws -> Data { try handler(r) }
    static func projectID(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "%2F") }
    static func date(_ s: String?) -> Date? { nil }
}
@main struct CollaborationTests {
    @MainActor static func main() async throws {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let gh = ReviewAccess(target: RepoTarget(provider: .github, host: "github.example", path: "team/repo"), token: "fixture", apiBase: "https://github.example/api", me: "reviewer")
        let gl = ReviewAccess(target: RepoTarget(provider: .gitlab, host: "gitlab.example", path: "team/repo"), token: "fixture", apiBase: "https://gitlab.example/api", me: "reviewer")
        func pull(_ head: String) -> [String: Any] { ["number": 1, "title": "Request", "body": "Body", "user": ["login": "reviewer"], "head": ["ref": "work", "sha": head, "repo": ["full_name": "team/repo"]], "base": ["ref": "main"], "html_url": "https://github.example/x", "state": "open", "mergeable": true, "mergeable_state": "clean"] }
        let repo: [String: Any] = ["state": "success", "total_count": 0, "check_runs": [], "allow_merge_commit": true, "allow_squash_merge": true, "permissions": ["push": true]]
        var head = "head-a", writes = 0
        var requests = 0
        Hosting.handler = { r in
            precondition(!r.url!.path.contains("/search/issues"), "The request list must not use the search API")
            if r.url!.path.hasSuffix("/pulls") {
                requests += 1
                let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(q.first { $0.name == "state" }!.value == "open"); precondition(q.first { $0.name == "page" }!.value == "2")
                var mine = pull("head-a"); mine["requested_reviewers"] = [["login": "Reviewer"]]; mine["title"] = "Fix things"
                var other = pull("head-a"); other["number"] = 2; other["title"] = "Other"
                return try json([mine, other])
            }
            if r.httpMethod == "PUT" { writes += 1; let b = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]; precondition(b["sha"] as? String == "head-a"); return try json(["merged": true]) }
            return try json(r.url!.path.hasSuffix("/pulls/1") ? pull(head) : repo)
        }
        let page = try await CollaborationAPI.requests(gh, RequestQuery(scope: "reviewRequested", search: "fix", page: 2))
        precondition(page.0.map(\.number) == [1] && !page.1 && page.2 != nil && requests == 1, "The list page was not narrowed on the client in one request")
        // The list row's review-requested pill and comment count come from the list response itself.
        precondition(page.0.first?.reviewRequested == true && page.0.first?.comments == nil, "GitHub's list has the requested reviewers and no comment count")
        let noted = try CollaborationAPI.pull(gl, ["iid": 7, "title": "T", "author": ["username": "a"], "source_branch": "s", "target_branch": "main", "web_url": "u", "sha": "h", "user_notes_count": 4, "reviewers": [["username": "Reviewer"]]])
        precondition(noted.comments == 4 && noted.reviewRequested, "GitLab's list carries the comment count and the reviewers")
        Hosting.handler = { r in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(q.first { $0.name == "state" }!.value == "closed" && q.first { $0.name == "per_page" }!.value == "100")
            var merged = pull("head-a"); merged["state"] = "closed"; merged["merged_at"] = "2026-01-01T00:00:00Z"
            var closed = pull("head-a"); closed["number"] = 2; closed["state"] = "closed"; closed["merged_at"] = NSNull()
            return try json([merged, closed])
        }
        let merged = try await CollaborationAPI.requests(gh, RequestQuery(scope: "merged")), closed = try await CollaborationAPI.requests(gh, RequestQuery(scope: "closed"))
        precondition(merged.0.map(\.number) == [1], "Merged requests must be told apart by merged_at")
        precondition(closed.0.map(\.number) == [2], "Closed requests must exclude merged ones")
        Hosting.handler = { r in
            if r.httpMethod == "PUT" { writes += 1; let b = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]; precondition(b["sha"] as? String == "head-a"); return try json(["merged": true]) }
            return try json(r.url!.path.hasSuffix("/pulls/1") ? pull(head) : repo)
        }
        let expected = try await CollaborationAPI.lifecycle(gh, 1); precondition(expected.blockers.isEmpty)
        head = "head-b"
        do { try await CollaborationAPI.merge(gh, expected: expected, method: "merge"); fatalError("Stale merge accepted") } catch {}
        precondition(writes == 0); head = "head-a"
        try await CollaborationAPI.merge(gh, expected: expected, method: "squash"); precondition(writes == 1)
        var stale = gh; stale.isCurrent = { false }
        do { try await CollaborationAPI.merge(stale, expected: expected, method: "merge"); fatalError("Stale context accepted") } catch {}
        precondition(writes == 1)
        Hosting.handler = { r in
            if r.url!.path.hasSuffix("/todos") { return try json([["id": 9, "action_name": "mentioned", "target_type": "MergeRequest", "target_url": "https://gitlab.example/x", "body": "Mention", "project": ["path_with_namespace": "team/repo"], "target": ["iid": 7, "title": "Review"], "author": ["username": "other"]]]) }
            if r.httpMethod == "POST" { precondition(r.url!.path.hasSuffix("/merge_requests/7/notes")); return try json([:]) }
            if r.url!.path.hasSuffix("/notes") { return try json([["id": 3, "body": "note", "author": ["username": "other"], "created_at": "2026-10-02T13:00:00Z"]]) }
            return try json(["title": "Review", "state": "opened", "description": "Body"])
        }
        let inbox = try await CollaborationAPI.inbox(gl, kind: "mention", page: 1); precondition(inbox.0.count == 1 && inbox.0[0].isRequest)
        let detail = try await CollaborationAPI.detail(gl, item: inbox.0[0], page: 1); precondition(detail.item.isRequest && detail.comments.count == 1 && detail.comments[0].createdAt == "2026-10-02T13:00:00Z")
        try await CollaborationAPI.inboxAction(gl, item: detail.item, action: "comment", body: "Reply")
        let state = CollaborationState(); state.inbox = inbox.0; let context = state.contextID; state.reset(); precondition(state.inbox.isEmpty && context != state.contextID)
        let issue = CollaborationInboxItem(id: "issue-7", kind: "issue", number: 7, title: "Search", url: "https://github.example/team/repo/issues/7", body: "", state: "open", author: "reviewer")
        let own = CollaborationInboxComment(id: "12", author: "reviewer", body: "Original", editable: true)
        var editedBody = "Original", commentWrites = 0
        Hosting.handler = { request in
            if request.httpMethod == "PATCH" { commentWrites += 1; return try json([:]) }
            return try json(["body": editedBody, "user": ["login": "reviewer"], "issue_url": "https://github.example/api/repos/team/repo/issues/7"])
        }
        try await CollaborationAPI.changeIssueComment(gh, item: issue, comment: own, body: "Edited")
        precondition(commentWrites == 1)
        editedBody = "Collaborator edit"
        do { try await CollaborationAPI.changeIssueComment(gh, item: issue, comment: own, body: "New"); fatalError("Stale comment accepted") } catch {}
        precondition(commentWrites == 1)
        Hosting.handler = { request in
            precondition(request.url!.path.hasSuffix("/issues/7/timeline"))
            return try json([["event": "cross-referenced", "source": ["issue": ["number": 9, "title": "Search", "state": "open", "html_url": "https://github.example/team/repo/pull/9", "pull_request": [:]]]]])
        }
        let linked = try await CollaborationAPI.issueLinkedRequests(gh, item: issue, page: 1)
        precondition(linked.0.count == 1 && linked.0[0].number == 9 && !linked.1)
        precondition(IssuePage.progress(branches: [], requestBranches: ["a"]) == .notStarted && IssuePage.progress(branches: ["b"], requestBranches: ["a"]) == .inProgress && IssuePage.progress(branches: ["b", "a"], requestBranches: ["a"]) == .inReview, "An issue is in review once a linked branch has a request, in progress once it has a branch")
        let assigned = [IssuePage.Assigned(number: 42, progress: .inReview, branch: "feature/search"), IssuePage.Assigned(number: 41, progress: .notStarted), IssuePage.Assigned(number: 37, progress: .notStarted)]
        let summary = IssuePage.summary(assigned)
        precondition(summary.lines == ["#42 in review", "#41 and #37 not started"] && summary.counts == "1 in review, 2 not started" && summary.total == 3, "The summary names the groups that have issues, the furthest along first")
        precondition(IssuePage.numbers([7]) == "#7" && IssuePage.numbers([1, 2, 3]) == "3 issues" && IssuePage.summary([]).lines.isEmpty, "Three numbers in a row become a count")
        precondition(IssuePage.next(assigned, currentBranch: "feature/search") == .createBranch(41), "The next step is a branch for the first issue nobody started")
        precondition(IssuePage.next([IssuePage.Assigned(number: 62, progress: .inProgress, branch: "feature/export"), IssuePage.Assigned(number: 63, progress: .notStarted)], currentBranch: "feature/export") == .createRequest(62, branch: "feature/export"), "The issue this branch works on asks for its request first")
        precondition(IssuePage.next([IssuePage.Assigned(number: 61, progress: .inReview)], currentBranch: nil) == nil, "Nothing is next when everything is in review")
        precondition(IssuePage.count(0, more: false) == nil && IssuePage.count(3, more: false) == "3" && IssuePage.count(30, more: true) == "30+", "The segment counts what is assigned, and nothing when nothing is")
        var listCalendar = Calendar(identifier: .gregorian)
        listCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let listNow = listCalendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9))!
        func when(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> String {
            ListDate.when(listCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!, now: listNow, calendar: listCalendar, locale: Locale(identifier: "en_US"))
        }
        precondition(when(2026, 11, 5, 8, 59, 30) == "Just now" && when(2026, 11, 5, 8, 48) == "12m ago" && when(2026, 11, 5, 7) == "2h ago" && when(2026, 11, 4, 10) == "23h ago", "Within 24 hours a row says how long ago")
        precondition(when(2026, 11, 4, 8) == "Yesterday" && when(2026, 11, 3, 20) == "Nov 3" && when(2025, 12, 30) == "Dec 30, 2025", "Then yesterday, then the day, with the year only for another year")
        precondition(ListDate.parse("2026-10-30T09:00:00Z") == listCalendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9)) && ListDate.parse("2026-10-30T09:00:00.250Z") != nil && ListDate.parse("") == nil && ListDate.parse(nil) == nil, "The servers' dates are read with or without fractions")
        print("Collaboration: REST list paging and page filters, merge SHA and context guards, request mention replies, state reset, the Issues page's assigned summary and list dates passed")
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$ROOT/Sources/Services/Collaboration.swift" "$ROOT/Sources/Services/IssueCollaboration.swift" "$ROOT/Sources/Core/IssuePage.swift" "$ROOT/Sources/Core/ListDate.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test"
"$TASK_TMP/test"
