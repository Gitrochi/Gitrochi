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
struct PullRequest { let number: Int; let title: String; let author: String; let source: String; let target: String; let url: String; let isDraft: Bool; let updated: Date?; let body: String; let headSHA: String?; let fromFork: Bool }
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
        Hosting.handler = { r in
            if r.url!.path.contains("/search/issues") {
                let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(q.first { $0.name == "q" }!.value!.contains("review-requested:reviewer")); precondition(q.first { $0.name == "page" }!.value == "2")
                return try json(["items": [["number": 1]], "total_count": 70])
            }
            if r.httpMethod == "PUT" { writes += 1; let b = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]; precondition(b["sha"] as? String == "head-a"); return try json(["merged": true]) }
            return try json(r.url!.path.hasSuffix("/pulls/1") ? pull(head) : repo)
        }
        let page = try await CollaborationAPI.requests(gh, RequestQuery(scope: "reviewRequested", search: "fix", page: 2)); precondition(page.0.count == 1 && page.1)
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
            if r.url!.path.hasSuffix("/notes") { return try json([["id": 3, "body": "note", "author": ["username": "other"]]]) }
            return try json(["title": "Review", "state": "opened", "description": "Body"])
        }
        let inbox = try await CollaborationAPI.inbox(gl, kind: "mention", page: 1); precondition(inbox.0.count == 1 && inbox.0[0].isRequest)
        let detail = try await CollaborationAPI.detail(gl, item: inbox.0[0], page: 1); precondition(detail.item.isRequest && detail.comments.count == 1)
        try await CollaborationAPI.inboxAction(gl, item: detail.item, action: "comment", body: "Reply")
        let state = CollaborationState(); state.inbox = inbox.0; let context = state.contextID; state.reset(); precondition(state.inbox.isEmpty && context != state.contextID)
        print("Collaboration: server search/pagination, merge SHA and context guards, request mention replies, state reset passed")
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$ROOT/Sources/Services/Collaboration.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test"
"$TASK_TMP/test"
