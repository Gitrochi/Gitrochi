#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { let provider: Provider; let host: String; let path: String }
enum ChangeKind { case added, deleted, renamed, modified }
struct FileChange { let path: String; let oldPath: String?; let kind: ChangeKind; let staged: Bool }
enum Hosting {
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected HTTP request") }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    static func send<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: handler(request))
    }
    @discardableResult static func data(_ request: URLRequest) async throws -> Data { try handler(request) }
    static func projectID(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "%2F") }
    static func date(_ string: String?) -> Date? { string.flatMap { ISO8601DateFormatter().date(from: $0) } }
}
struct FixtureError: LocalizedError { var errorDescription: String? { "Lost response" } }
enum CIStatus { case pending, running, success, failed, skipped, neutral }
struct RequestCheck { var id: String; var name: String; var status: CIStatus }
struct PullRequest { var number: Int; var source = "feature"; var target = "main"; var fromFork = false; var comments: Int? = nil; var reviewRequested = false }

@main struct PullRequestReviewTests {
    /// The Pull requests page's rules that need no view. Windows: tests/pull-request-page.test.ts.
    static func pageRules() {
        precondition(PullRequestPage.isCompact(listShown: true, width: 1400) && PullRequestPage.isCompact(listShown: false, width: 916) && !PullRequestPage.isCompact(listShown: false, width: 917))
        precondition(PullRequestPage.treeWidth(compact: true) == 280 && PullRequestPage.treeWidth(compact: false) == 340)
        precondition(!PullRequestPage.splitAllowed(diffWidth: 999) && PullRequestPage.splitAllowed(diffWidth: 1000))
        precondition(PullRequestPage.headerInOneRow(onPage: true, tab: "files", width: 720) && !PullRequestPage.headerInOneRow(onPage: true, tab: "files", width: 719)
            && !PullRequestPage.headerInOneRow(onPage: false, tab: "files", width: 1200) && !PullRequestPage.headerInOneRow(onPage: true, tab: "checks", width: 1200))
        let requests = [PullRequest(number: 3, comments: 1), PullRequest(number: 9, reviewRequested: true), PullRequest(number: 5, comments: 4), PullRequest(number: 7, comments: 1)]
        precondition(PullRequestPage.sorted(requests, by: .updated).map(\.number) == [3, 9, 5, 7])
        precondition(PullRequestPage.sorted(requests, by: .newest).map(\.number) == [9, 7, 5, 3])
        precondition(PullRequestPage.sorted(requests, by: .comments).map(\.number) == [5, 3, 7, 9], "Unknown counts go last and ties keep the loaded order")
        precondition(PullRequestPage.reviewRequestedCount(requests) == 1)
        let review = PullRequestReview(number: 9, repositoryKey: "k", refs: ReviewRefs(headSHA: "h", baseSHA: "b", startSHA: "b"), comments: [
            ReviewComment(id: "a", author: "x", body: "", date: nil, path: "a.swift", threadID: "t1"),
            ReviewComment(id: "b", author: "y", body: "", date: nil, path: "a.swift", threadID: "t1"),
            ReviewComment(id: "c", author: "y", body: "", date: nil, path: "a.swift", threadID: "t2"),
            ReviewComment(id: "d", author: "y", body: "", date: nil, kind: .system)])
        precondition(PullRequestPage.commentCount(requests[0], review: review) == 1 && PullRequestPage.commentCount(requests[1], review: review) == 3 && PullRequestPage.commentCount(requests[1], review: nil) == nil)
        precondition(PullRequestPage.threadCount(review.comments, path: "a.swift") == 2 && PullRequestPage.threadCount(review.comments, path: "b.swift") == 0)
        precondition(PullRequestPage.branchLabel(requests[0], currentBranch: "feature", thisBranch: "This branch") == "This branch → main")
        precondition(PullRequestPage.branchLabel(PullRequest(number: 1, fromFork: true), currentBranch: "feature", thisBranch: "This branch") == "feature → main")
        precondition(PullRequestPage.folderLabel("macos/Sources/Views/Search/SearchPanel.swift") == "…/Views/Search" && PullRequestPage.folderLabel("docs/search.md") == "docs" && PullRequestPage.folderLabel("README.md") == "")
        precondition(PullRequestPage.folderLabels("macos/Sources/Views/Search/SearchPanel.swift") == ["…/Views/Search", "…/Search"] && PullRequestPage.folderLabels("docs/search.md") == ["docs"] && PullRequestPage.folderLabels("README.md").isEmpty)
        let checks = [RequestCheck(id: "1", name: "build", status: .success), RequestCheck(id: "2", name: "test", status: .failed), RequestCheck(id: "3", name: "lint", status: .running), RequestCheck(id: "4", name: "docs", status: .skipped)]
        let groups = PullRequestPage.checkGroups(checks)
        precondition(groups.failed.map(\.id) == ["2"] && groups.running.map(\.id) == ["3"] && groups.passed.map(\.id) == ["1", "4"])
        precondition(PullRequestPage.checksBadge(checks) == .failed(1) && PullRequestPage.checksBadge([checks[0], checks[2]]) == .running(1) && PullRequestPage.checksBadge([checks[0], checks[3]]) == nil)
        precondition(PullRequestPage.mergeReason(conflicts: false, base: "main", badge: nil, approvalsLeft: 1, blockers: []) == nil && PullRequestPage.mergeReason(conflicts: false, base: "main", badge: nil, approvalsLeft: nil, blockers: ["raw"]) == "raw" && PullRequestPage.mergeReason(conflicts: true, base: "main", badge: .failed(1), approvalsLeft: 1, blockers: ["raw"])?.contains("main") == true)
        precondition(PullRequestPage.branchSummary(hasRequest: false, ahead: 3, incoming: 2, commits: 3) == .noRequest(commits: 3) && PullRequestPage.branchSummary(hasRequest: true, ahead: 2, incoming: 5, commits: 6) == .notPushed(onServer: 4, local: 2) && PullRequestPage.branchSummary(hasRequest: true, ahead: 0, incoming: 5, commits: 3) == .moved(incoming: 5, commits: 3) && PullRequestPage.branchSummary(hasRequest: true, ahead: 0, incoming: 0, commits: 3) == .upToDate(commits: 3))
        let lines = PullRequestPage.logLines("Test started\nfile.swift:58: error: XCTAssertTrue failed\r\nNo errors in terror tests\nProcess completed with exit code 1.\n")
        precondition(lines.count == 4 && lines.map(\.isError) == [false, true, false, true] && lines[1].text.hasSuffix("failed") && PullRequestPage.firstError(lines)?.number == 2)
        precondition(PullRequestPage.linkedIssues("Closes #42, fixes #7 and resolved: #42. See #9") == [42, 7])
        precondition(PullRequestPage.viewedKey(repositoryKey: "github.com/team/repo", number: 5, headSHA: "abc") == "github.com/team/repo#5@abc")
    }

    @MainActor static func main() async throws {
        pageRules()
        let gh = RepoTarget(provider: .github, host: "github.test", path: "team/repo")
        let gl = RepoTarget(provider: .gitlab, host: "gitlab.test", path: "team/repo")
        let ghRefs = ReviewRefs(headSHA: "head-a", baseSHA: "base-a", startSHA: "base-a")
        let glRefs = ReviewRefs(headSHA: "head-a", baseSHA: "base-a", startSHA: "start-a")
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func meta(_ target: RepoTarget, head: String = "head-a") -> [String: Any] {
            target.provider == .github ? ["head": ["sha": head], "base": ["sha": "base-a"]] : ["diff_refs": ["head_sha": head, "base_sha": "base-a", "start_sha": "start-a"]]
        }
        func draft(_ target: RepoTarget, id: String, side: ReviewLineSide = .right) -> ReviewDraftComment {
            let reference = target.provider == .github ? ghRefs : glRefs
            return ReviewDraftComment(id: id, repositoryKey: ReviewAPI.repositoryKey(target), number: 1,
                                      anchor: ReviewLineAnchor(path: "new.swift", oldPath: "old.swift", line: side == .left ? 2 : 3, side: side,
                                                               headSHA: reference.headSHA, baseSHA: reference.baseSHA, startSHA: reference.startSHA), body: "Comment " + id)
        }
        // Pagination and decoding must work past 100 entries on both providers.
        Hosting.handler = { request in
            let url = request.url!, path = url.path
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
            guard let page else {
                if path.hasSuffix("/approvals") { return try json([:]) }
                return try json(meta(path.contains("merge_requests") ? gl : gh))
            }
            let ids = page == "1" ? Array(1...100) : [101]
            if path.hasSuffix("/files") { return try json(ids.map { ["filename": "file-\($0)", "status": "modified", "additions": 1, "deletions": 0] as [String: Any] }) }
            if path.hasSuffix("/diffs") { return try json(ids.map { ["old_path": "file-\($0)", "new_path": "file-\($0)", "diff": "@@ -1 +1 @@\n-old\n+new", "too_large": $0 == 101] as [String: Any] }) }
            if path.hasSuffix("/discussions") { return try json(ids.map { ["id": "thread-\($0)", "notes": [["id": $0, "body": "note", "resolvable": true]]] as [String: Any] }) }
            if path.hasSuffix("/reviews") { return try json(ids.map { ["id": $0, "body": "review", "state": "COMMENTED"] as [String: Any] }) }
            return try json(ids.map { ["id": $0, "body": "comment", "path": "source.swift", "line": 3, "side": "RIGHT"] as [String: Any] })
        }
        let ghReview = try await ReviewAPI.load(gh, token: "fixture", apiBase: "https://fixture", number: 1, me: "reviewer")
        precondition(ghReview.comments.count == 303 && ghReview.files.count == 101)
        let glReview = try await ReviewAPI.load(gl, token: "fixture", apiBase: "https://fixture", number: 1, me: "reviewer")
        precondition(glReview.comments.count == 101 && glReview.files.count == 101)
        precondition(glReview.files.last?.patch == nil && glReview.warnings.count == 1)

        var acceptedGH: [[String: Any]] = [], posts = 0, complete: [String] = []
        Hosting.handler = { request in
            if request.httpMethod == "POST" {
                posts += 1
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let comments = payload["comments"] as! [[String: Any]]
                precondition(comments[0]["side"] as? String == "LEFT" && comments[1]["side"] as? String == "RIGHT")
                precondition(payload["event"] as? String == "REQUEST_CHANGES" && payload["commit_id"] as? String == "head-a")
                acceptedGH.append(["id": 7, "state": "CHANGES_REQUESTED", "body": payload["body"]!])
                throw FixtureError()
            }
            return try json(request.url!.path.hasSuffix("/reviews") ? acceptedGH : meta(gh))
        }
        let ghDrafts = [draft(gh, id: "left", side: .left), draft(gh, id: "right")]
        do { try await ReviewAPI.submit(gh, token: "fixture", apiBase: "https://fixture", number: 1, expected: ghRefs, drafts: ghDrafts, body: "Fix please", verdict: .requestChanges) { complete.append($0) }; fatalError("Lost response was accepted") } catch {}
        try await ReviewAPI.submit(gh, token: "fixture", apiBase: "https://fixture", number: 1, expected: ghRefs, drafts: ghDrafts, body: "Fix please", verdict: .requestChanges) { complete.append($0) }
        precondition(posts == 1 && complete == ["left", "right"], "Retry duplicated a GitHub review")

        for target in [gh, gl] {
            let reference = target.provider == .github ? ghRefs : glRefs
            var accepted: [[String: Any]] = [], bodies: [String] = []
            Hosting.handler = { request in
                if request.httpMethod == "GET" {
                    return try json(request.url!.path.hasSuffix(target.provider == .github ? "/reviews" : "/discussions") ? accepted : meta(target))
                }
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if target.provider == .github {
                    bodies.append((payload["comments"] as! [[String: Any]])[0]["body"] as! String)
                    accepted.append(["id": accepted.count + 1, "state": "COMMENTED", "body": payload["body"]!])
                } else {
                    bodies.append(payload["body"] as! String)
                    accepted.append(["id": "thread-\(accepted.count)", "notes": [["id": accepted.count, "body": payload["body"]!]]])
                }
                if accepted.count == 1 { throw FixtureError() }
                return try json([:])
            }
            var edited = draft(target, id: "edited")
            do { try await ReviewAPI.submit(target, token: "fixture", apiBase: "https://fixture", number: 1, expected: reference, drafts: [edited], body: "", verdict: .comment) { _ in }; fatalError("Lost response was accepted") } catch {}
            edited.body = "Edited unsent text"
            try await ReviewAPI.submit(target, token: "fixture", apiBase: "https://fixture", number: 1, expected: reference, drafts: [edited], body: "", verdict: .comment) { _ in }
            precondition(bodies.count == 2 && bodies[1].contains("Edited unsent text"), "Edited draft was cleared without being sent")
        }
        for state in ["DISMISSED", "PENDING"] {
            var accepted: [[String: Any]] = [], verdictPosts = 0
            Hosting.handler = { request in
                if request.httpMethod == "GET" { return try json(request.url!.path.hasSuffix("/reviews") ? accepted : meta(gh)) }
                verdictPosts += 1
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                accepted.append(["id": verdictPosts, "state": state, "body": payload["body"]!])
                return try json([:])
            }
            for _ in 0..<2 { try await ReviewAPI.submit(gh, token: "fixture", apiBase: "https://fixture", number: 1, expected: ghRefs, drafts: [], body: "Approve", verdict: .approve) { _ in } }
            precondition(verdictPosts == 2, "Dismissed or pending review suppressed an approval")
        }

        Hosting.handler = { request in
            precondition(request.httpMethod == "GET", "Stale version wrote a review")
            return try json(meta(gh, head: "head-b"))
        }
        do { try await ReviewAPI.submit(gh, token: "fixture", apiBase: "https://fixture", number: 1, expected: ghRefs, drafts: ghDrafts, body: "", verdict: .comment) { _ in }; fatalError("Stale head accepted") } catch {}

        var acceptedGL: [[String: Any]] = []
        posts = 0; complete = []
        Hosting.handler = { request in
            if request.httpMethod == "GET" { return try json(request.url!.path.hasSuffix("/discussions") ? acceptedGL : meta(gl)) }
            posts += 1
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let position = payload["position"] as! [String: Any]
            precondition(position["old_path"] as? String == "old.swift" && position["new_path"] as? String == "new.swift")
            if posts == 1 { precondition(position["old_line"] as? Int == 2 && position["new_line"] == nil) }
            else { precondition(position["new_line"] as? Int == 3 && position["old_line"] as? Int == 2) }
            acceptedGL.append(["id": "thread-\(posts)", "notes": [["id": posts, "body": payload["body"]!]]])
            if posts == 2 { throw FixtureError() }
            return try json([:])
        }
        var context = draft(gl, id: "context")
        context = ReviewDraftComment(id: context.id, repositoryKey: context.repositoryKey, number: context.number,
                                     anchor: ReviewLineAnchor(path: context.anchor.path, oldPath: context.anchor.oldPath, line: 3, side: .right, oldLine: 2, newLine: 3, headSHA: "head-a", baseSHA: "base-a", startSHA: "start-a"), body: context.body)
        do { try await ReviewAPI.submit(gl, token: "fixture", apiBase: "https://fixture", number: 1, expected: glRefs, drafts: [draft(gl, id: "deleted", side: .left), context], body: "", verdict: .comment) { complete.append($0) }; fatalError("Lost response was accepted") }
        catch let error as ReviewSubmissionError { precondition(error.completedIDs == ["deleted"]) }
        precondition(complete == ["deleted"])
        try await ReviewAPI.submit(gl, token: "fixture", apiBase: "https://fixture", number: 1, expected: glRefs, drafts: [context], body: "", verdict: .comment) { complete.append($0) }
        precondition(posts == 2 && complete == ["deleted", "context"], "Retry duplicated a GitLab thread")
        print("PR review: both providers paginate, old/new/context anchors preserve renames, atomic GitHub retry and partial GitLab retry are safe; stale versions cannot write")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/ReviewAPI.swift" "$ROOT/Sources/Core/PullRequestPage.swift" "$ROOT/Sources/Core/JobLog.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-review"
"$TASK_TMP/test-review"
