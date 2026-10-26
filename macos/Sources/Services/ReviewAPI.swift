import Foundation

enum ReviewLineSide: String, Codable, Hashable { case left = "LEFT", right = "RIGHT" }
enum ReviewVerdict: String { case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES" }
struct ReviewRefs: Hashable {
    let headSHA: String
    let baseSHA: String
    let startSHA: String
}
struct ReviewLineAnchor: Codable, Hashable {
    let path: String
    let oldPath: String?
    let line: Int
    let side: ReviewLineSide
    var oldLine: Int?
    var newLine: Int?
    let headSHA: String
    let baseSHA: String
    let startSHA: String
    var refs: ReviewRefs { ReviewRefs(headSHA: headSHA, baseSHA: baseSHA, startSHA: startSHA) }
}
struct ReviewDraftComment: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    let repositoryKey: String
    let number: Int
    let anchor: ReviewLineAnchor
    var body: String
}
enum ReviewDraftStorage {
    static func load() -> [ReviewDraftComment] {
        guard let data = UserDefaults.standard.data(forKey: "reviewDrafts.v1") else { return [] }
        return (try? JSONDecoder().decode([ReviewDraftComment].self, from: data)) ?? []
    }
    static func upsert(_ draft: ReviewDraftComment) {
        var drafts = load().filter { $0.id != draft.id }
        drafts.append(draft)
        save(drafts)
    }
    static func remove(_ id: String, expected: ReviewDraftComment? = nil) {
        save(load().filter { draft in
            if draft.id != id { return true }
            return expected.map { !ReviewAPI.sameDraft(draft, $0) } ?? false
        })
    }
    private static func save(_ drafts: [ReviewDraftComment]) {
        if let data = try? JSONEncoder().encode(drafts) { UserDefaults.standard.set(data, forKey: "reviewDrafts.v1") }
    }
}
struct ReviewComment: Identifiable, Hashable {
    enum Kind: Hashable { case comment, approved, changesRequested, system }
    let id: String
    let author: String
    let body: String
    let date: Date?
    var path: String?
    var line: Int?
    var side: ReviewLineSide?
    var threadID: String?
    var replyID: Int?
    var resolvable = false
    var resolved = false
    var kind: Kind = .comment
}
struct ReviewFile: Identifiable, Hashable {
    let path: String
    let oldPath: String?
    let kind: ChangeKind
    let additions: Int
    let deletions: Int
    let patch: String?
    var id: String { path }
    var change: FileChange { FileChange(path: path, oldPath: oldPath, kind: kind, staged: false) }
}
struct ReviewState: Hashable {
    var approvedBy: [String] = []
    var changesRequestedBy: [String] = []
    var approvalsLeft: Int?
    var approvedByMe = false
}
struct PullRequestReview {
    let number: Int
    let repositoryKey: String
    let refs: ReviewRefs
    var headSHA: String { refs.headSHA }
    var baseSHA: String { refs.baseSHA }
    var startSHA: String { refs.startSHA }
    var comments: [ReviewComment] = []
    var files: [ReviewFile] = []
    var state = ReviewState()
    var warnings: [String] = []
}
struct ReviewSubmissionError: LocalizedError {
    let message: String
    var completedIDs: [String] = []
    var errorDescription: String? { message }
}

/// GitHub atomically submits a review; GitLab publishes discussions sequentially and reconciles retries.
enum ReviewAPI {
    private struct GHUser: Decodable { let login: String }
    private struct GHComment: Decodable { let id: Int; let user: GHUser?; let body: String?; let createdAt: String? }
    private struct GHLineComment: Decodable {
        let id: Int; let user: GHUser?; let body: String?; let createdAt: String?
        let path: String?; let line: Int?; let originalLine: Int?; let side: ReviewLineSide?; let inReplyToId: Int?
    }
    private struct GHReview: Decodable { let id: Int; let user: GHUser?; let body: String?; let state: String; let submittedAt: String? }
    private struct GHFile: Decodable { let filename: String; let previousFilename: String?; let status: String; let additions: Int; let deletions: Int; let patch: String? }
    private struct GHRef: Decodable { let sha: String }
    private struct GHRefs: Decodable { let head: GHRef; let base: GHRef }
    private struct GLAuthor: Decodable { let username: String }
    private struct GLPosition: Decodable { let newPath: String?; let newLine: Int?; let oldPath: String?; let oldLine: Int? }
    private struct GLNote: Decodable {
        let id: Int; let author: GLAuthor?; let body: String; let createdAt: String?; let system: Bool?
        let position: GLPosition?; let resolvable: Bool?; let resolved: Bool?
    }
    private struct GLDiscussion: Decodable { let id: String; let individualNote: Bool?; let notes: [GLNote] }
    private struct GLApprovedBy: Decodable { let user: GLAuthor }
    private struct GLApprovals: Decodable { let approvedBy: [GLApprovedBy]?; let approvalsLeft: Int? }
    private struct GLChange: Decodable {
        let oldPath: String; let newPath: String; let newFile: Bool?; let deletedFile: Bool?; let renamedFile: Bool?; let diff: String?; let collapsed: Bool?; let tooLarge: Bool?
    }
    private struct GLDiffRefs: Decodable { let headSha: String; let baseSha: String; let startSha: String }
    private struct GLRefs: Decodable { let diffRefs: GLDiffRefs? }
    static func repositoryKey(_ t: RepoTarget) -> String { "\(t.provider.rawValue):\(t.host.lowercased())/\(t.path.lowercased())" }
    private static func repo(_ t: RepoTarget, _ base: String) -> String { base + "/repos/\(t.path)" }
    private static func project(_ t: RepoTarget, _ base: String) -> String { base + "/projects/\(Hosting.projectID(t.path))" }
    private static var staleMessage: String { String(localized: "This request changed. Refresh the diff and recreate comments on the current version before submitting.") }
    private static func clean(_ body: String) -> String { body.replacingOccurrences(of: "\\n?<!-- gitrochi-review:[^>]+ -->", with: "", options: .regularExpression) }
    private static func marker(_ id: String) -> String { "<!-- gitrochi-review:\(id) -->" }

    /// Native request helper has no pagination headers. Continue until the first short page.
    private static func pages<T: Decodable>(_ type: T.Type, _ t: RepoTarget, token: String, url: String, maxPages: Int = 1000) async throws -> [T] {
        var result: [T] = []
        for page in 1...maxPages {
            let batch = try await Hosting.send([T].self, Hosting.request(t.provider, url + (url.contains("?") ? "&" : "?") + "per_page=100&page=\(page)", token: token))
            result += batch
            if batch.count < 100 { return result }
        }
        if maxPages < 1000 { return result }
        throw ReviewSubmissionError(message: String(localized: "This request is too large to load completely. Open it in the browser."))
    }

    static func refs(_ t: RepoTarget, token: String, apiBase: String, number: Int) async throws -> ReviewRefs {
        switch t.provider {
        case .github:
            let r = try await Hosting.send(GHRefs.self, Hosting.request(.github, repo(t, apiBase) + "/pulls/\(number)", token: token))
            return ReviewRefs(headSHA: r.head.sha, baseSHA: r.base.sha, startSHA: r.base.sha)
        case .gitlab:
            let r = try await Hosting.send(GLRefs.self, Hosting.request(.gitlab, project(t, apiBase) + "/merge_requests/\(number)", token: token))
            guard let d = r.diffRefs, !d.headSha.isEmpty, !d.baseSha.isEmpty, !d.startSha.isEmpty else {
                throw ReviewSubmissionError(message: String(localized: "The server has not prepared this diff yet. Refresh and try again."))
            }
            return ReviewRefs(headSHA: d.headSha, baseSHA: d.baseSha, startSHA: d.startSha)
        }
    }

    static func load(_ t: RepoTarget, token: String, apiBase: String, number: Int, me: String) async throws -> PullRequestReview {
        let reference = try await refs(t, token: token, apiBase: apiBase, number: number)
        var review = PullRequestReview(number: number, repositoryKey: repositoryKey(t), refs: reference)
        switch t.provider {
        case .github:
            let r = repo(t, apiBase)
            async let commentsR = pages(GHComment.self, t, token: token, url: r + "/issues/\(number)/comments")
            async let linesR = pages(GHLineComment.self, t, token: token, url: r + "/pulls/\(number)/comments")
            async let reviewsR = pages(GHReview.self, t, token: token, url: r + "/pulls/\(number)/reviews")
            async let filesR = pages(GHFile.self, t, token: token, url: r + "/pulls/\(number)/files", maxPages: 30)
            let (comments, lines, reviews, files) = try await (commentsR, linesR, reviewsR, filesR)
            review.comments += comments.map { ReviewComment(id: "c\($0.id)", author: $0.user?.login ?? "", body: clean($0.body ?? ""), date: Hosting.date($0.createdAt)) }
            review.comments += lines.map { c in
                ReviewComment(id: "l\(c.id)", author: c.user?.login ?? "", body: clean(c.body ?? ""), date: Hosting.date(c.createdAt), path: c.path, line: c.line ?? c.originalLine,
                              side: c.side, threadID: String(c.inReplyToId ?? c.id), replyID: c.inReplyToId ?? c.id)
            }
            do {
                let threads = try await GitHubReviewThreads.load(t, token: token, apiBase: apiBase, number: number)
                for index in review.comments.indices {
                    if let root = review.comments[index].replyID, let thread = threads[root] {
                        review.comments[index].threadID = thread.id; review.comments[index].resolvable = thread.isResolved ? thread.viewerCanUnresolve == true : thread.viewerCanResolve; review.comments[index].resolved = thread.isResolved
                    }
                }
            } catch { review.warnings.append(String(localized: "The server does not expose GitHub review threads. Use the browser for resolution.")) }
            var latest: [String: String] = [:]
            for rv in reviews {
                let who = rv.user?.login ?? ""
                if ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(rv.state) { latest[who] = rv.state }
                let kind: ReviewComment.Kind = rv.state == "APPROVED" ? .approved : rv.state == "CHANGES_REQUESTED" ? .changesRequested : .comment
                let body = clean(rv.body ?? "")
                guard kind != .comment || !body.isEmpty else { continue }
                review.comments.append(ReviewComment(id: "r\(rv.id)", author: who, body: body, date: Hosting.date(rv.submittedAt), kind: kind))
            }
            review.state.approvedBy = latest.filter { $0.value == "APPROVED" }.map(\.key).sorted()
            review.state.changesRequestedBy = latest.filter { $0.value == "CHANGES_REQUESTED" }.map(\.key).sorted()
            review.state.approvedByMe = latest[me] == "APPROVED"
            review.files = files.map { f in
                let kind: ChangeKind = f.status == "added" ? .added : f.status == "removed" ? .deleted : f.status == "renamed" ? .renamed : .modified
                return ReviewFile(path: f.filename, oldPath: f.previousFilename, kind: kind, additions: f.additions, deletions: f.deletions, patch: f.patch)
            }
            if files.count >= 3000 { review.warnings.append(String(localized: "GitHub limits this response to 3,000 files. Open the request in the browser for the complete review.")) }
        case .gitlab:
            let p = project(t, apiBase)
            async let discussionsR = pages(GLDiscussion.self, t, token: token, url: p + "/merge_requests/\(number)/discussions")
            async let approvalsR = Hosting.send(GLApprovals.self, Hosting.request(.gitlab, p + "/merge_requests/\(number)/approvals", token: token))
            async let changesR = pages(GLChange.self, t, token: token, url: p + "/merge_requests/\(number)/diffs")
            let (discussions, approvals, changes) = try await (discussionsR, try? approvalsR, changesR)
            review.comments = discussions.flatMap { d in d.notes.map { n in
                ReviewComment(id: "n\(n.id)", author: n.author?.username ?? "", body: clean(n.body), date: Hosting.date(n.createdAt),
                              path: n.position?.newPath ?? n.position?.oldPath, line: n.position?.newLine ?? n.position?.oldLine,
                              side: n.position?.newLine != nil ? .right : .left, threadID: d.individualNote == true ? nil : d.id,
                              resolvable: n.resolvable == true, resolved: n.resolved == true, kind: n.system == true ? .system : .comment)
            } }
            review.state.approvedBy = (approvals?.approvedBy ?? []).map(\.user.username)
            review.state.approvalsLeft = approvals?.approvalsLeft
            review.state.approvedByMe = review.state.approvedBy.contains(me)
            review.files = changes.map { c in
                let kind: ChangeKind = c.newFile == true ? .added : c.deletedFile == true ? .deleted : c.renamedFile == true ? .renamed : .modified
                let lines = (c.diff ?? "").components(separatedBy: "\n")
                return ReviewFile(path: c.newPath, oldPath: c.renamedFile == true ? c.oldPath : nil, kind: kind, additions: lines.filter { $0.hasPrefix("+") }.count,
                                  deletions: lines.filter { $0.hasPrefix("-") }.count, patch: c.tooLarge == true || c.collapsed == true || (c.diff ?? "").isEmpty ? nil : c.diff)
            }
            if changes.contains(where: { $0.tooLarge == true || $0.collapsed == true }) { review.warnings.append(String(localized: "Some diffs were omitted by the server. Open those files in the browser.")) }
        }
        guard reference == (try await refs(t, token: token, apiBase: apiBase, number: number)) else { throw ReviewSubmissionError(message: staleMessage) }
        review.comments.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return review
    }

    private static func fingerprint(_ content: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in content.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
    private static func encoded(_ value: [Any]) -> String {
        // All callers supply JSON primitives; sorted array coordinates give stable retry identities.
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private static func draftID(_ draft: ReviewDraftComment) -> String {
        let a = draft.anchor
        return draft.id + "-" + fingerprint(encoded([draft.repositoryKey, draft.number, draft.body.trimmingCharacters(in: .whitespacesAndNewlines), a.path,
                                                     a.oldPath as Any? ?? NSNull(), a.line, a.side.rawValue, a.oldLine as Any? ?? NSNull(), a.newLine as Any? ?? NSNull(), a.headSHA, a.baseSHA, a.startSHA]))
    }
    static func sameDraft(_ lhs: ReviewDraftComment, _ rhs: ReviewDraftComment) -> Bool { draftID(lhs) == draftID(rhs) }
    private static func summaryID(_ refs: ReviewRefs, body: String, verdict: ReviewVerdict, drafts: [ReviewDraftComment]) -> String {
        "summary-" + fingerprint(encoded([refs.headSHA, refs.baseSHA, refs.startSHA, verdict.rawValue, body.trimmingCharacters(in: .whitespacesAndNewlines), drafts.map(draftID)]))
    }

    static func submit(_ t: RepoTarget, token: String, apiBase: String, number: Int, expected: ReviewRefs, drafts: [ReviewDraftComment], body: String, verdict: ReviewVerdict,
                       completed: @MainActor (String) -> Void) async throws {
        guard t.provider == .github || verdict != .requestChanges else { throw ReviewSubmissionError(message: String(localized: "Request changes is only supported for GitHub reviews.")) }
        guard drafts.allSatisfy({ $0.repositoryKey == repositoryKey(t) && $0.number == number && $0.anchor.refs == expected }) else { throw ReviewSubmissionError(message: staleMessage) }
        guard drafts.allSatisfy({ !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.anchor.line > 0 }) else { throw ReviewSubmissionError(message: String(localized: "Write a comment for every selected line before submitting.")) }
        guard expected == (try await refs(t, token: token, apiBase: apiBase, number: number)) else { throw ReviewSubmissionError(message: staleMessage) }
        let summary = summaryID(expected, body: body, verdict: verdict, drafts: t.provider == .github ? drafts : [])
        switch t.provider {
        case .github:
            let r = repo(t, apiBase)
            let existing = try await pages(GHReview.self, t, token: token, url: r + "/pulls/\(number)/reviews")
            if !existing.contains(where: { $0.state == (verdict == .approve ? "APPROVED" : verdict == .requestChanges ? "CHANGES_REQUESTED" : "COMMENTED") && ($0.body ?? "").contains(marker(summary)) }) {
                var payload: [String: Any] = ["commit_id": expected.headSHA, "event": verdict.rawValue, "body": (body + "\n" + marker(summary)).trimmingCharacters(in: .whitespacesAndNewlines)]
                if !drafts.isEmpty { payload["comments"] = drafts.map { ["path": $0.anchor.path, "line": $0.anchor.line, "side": $0.anchor.side.rawValue, "body": $0.body.trimmingCharacters(in: .whitespacesAndNewlines)] as [String: Any] } }
                try await Hosting.data(Hosting.request(.github, r + "/pulls/\(number)/reviews", token: token, method: "POST", body: payload))
            }
            for draft in drafts { await completed(draft.id) }
        case .gitlab:
            let p = project(t, apiBase)
            let discussions = try await pages(GLDiscussion.self, t, token: token, url: p + "/merge_requests/\(number)/discussions")
            let existingBodies = discussions.flatMap(\.notes).map(\.body)
            var done: [String] = []
            do {
                for draft in drafts {
                    if !existingBodies.contains(where: { $0.contains(marker(draftID(draft))) }) {
                        let a = draft.anchor
                        var position: [String: Any] = ["position_type": "text", "base_sha": a.baseSHA, "start_sha": a.startSHA, "head_sha": a.headSHA, "old_path": a.oldPath ?? a.path, "new_path": a.path]
                        if a.side == .left { position["old_line"] = a.line; if let newLine = a.newLine { position["new_line"] = newLine } }
                        else { position["new_line"] = a.line; if let oldLine = a.oldLine { position["old_line"] = oldLine } }
                        try await Hosting.data(Hosting.request(.gitlab, p + "/merge_requests/\(number)/discussions", token: token, method: "POST", body: ["body": draft.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + marker(draftID(draft)), "position": position]))
                    }
                    done.append(draft.id)
                    await completed(draft.id)
                }
                if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !existingBodies.contains(where: { $0.contains(marker(summary)) }) {
                    try await Hosting.data(Hosting.request(.gitlab, p + "/merge_requests/\(number)/discussions", token: token, method: "POST", body: ["body": body + "\n" + marker(summary)]))
                }
                if verdict == .approve { try await Hosting.data(Hosting.request(.gitlab, p + "/merge_requests/\(number)/approve", token: token, method: "POST", body: ["sha": expected.headSHA])) }
            } catch {
                throw ReviewSubmissionError(message: String(localized: "GitLab submits comments one at a time. Confirmed comments were removed from drafts; remaining drafts are kept and checked before retry.") + "\n\n" + error.localizedDescription, completedIDs: done)
            }
        }
    }

    static func unapprove(_ t: RepoTarget, token: String, apiBase: String, number: Int) async throws {
        try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/merge_requests/\(number)/unapprove", token: token, method: "POST"))
    }
    static func reply(_ t: RepoTarget, token: String, apiBase: String, number: Int, comment: ReviewComment, body: String) async throws {
        switch t.provider {
        case .github:
            guard let id = comment.replyID else { return }
            try await Hosting.data(Hosting.request(.github, repo(t, apiBase) + "/pulls/\(number)/comments/\(id)/replies", token: token, method: "POST", body: ["body": body]))
        case .gitlab:
            guard let id = comment.threadID else { return }
            try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/merge_requests/\(number)/discussions/\(Hosting.projectID(id))/notes", token: token, method: "POST", body: ["body": body]))
        }
    }
    static func resolve(_ t: RepoTarget, token: String, apiBase: String, number: Int, threadID: String, resolved: Bool) async throws {
        if t.provider == .github { try await GitHubReviewThreads.resolve(token: token, apiBase: apiBase, threadID: threadID, resolved: resolved); return }
        try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/merge_requests/\(number)/discussions/\(Hosting.projectID(threadID))", token: token, method: "PUT", body: ["resolved": resolved]))
    }
}

/// REST 줄 댓글의 숫자 ID와 GraphQL 스레드를 연결한다.
enum GitHubReviewThreads {
    struct Thread: Decodable {
        let id: String; let isResolved: Bool; let viewerCanResolve: Bool; let viewerCanUnresolve: Bool?
        struct Comment: Decodable { let databaseId: Int? }
        struct Comments: Decodable { let nodes: [Comment] }
        let comments: Comments
    }
    private struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    private struct Threads: Decodable { let nodes: [Thread]; let pageInfo: PageInfo }
    private struct Pull: Decodable { let reviewThreads: Threads }
    private struct Repository: Decodable { let pullRequest: Pull? }
    private struct QueryData: Decodable { let repository: Repository? }
    private struct GraphError: Decodable { let message: String }
    private struct Result: Decodable { let data: QueryData?; let errors: [GraphError]? }
    private static func graphURL(_ base: String) -> String { base.replacingOccurrences(of: "/api/v3$", with: "/api", options: .regularExpression) + "/graphql" }
    static func load(_ target: RepoTarget, token: String, apiBase: String, number: Int) async throws -> [Int: Thread] {
        let parts = target.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw ReviewSubmissionError(message: String(localized: "The server does not expose GitHub review threads. Use the browser for resolution.")) }
        var result: [Int: Thread] = [:], after: String?
        for _ in 0..<100 {
            let response = try await Hosting.send(Result.self, Hosting.request(.github, graphURL(apiBase), token: token, method: "POST", body: [
                "query": "query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){nodes{id isResolved viewerCanResolve viewerCanUnresolve comments(first:1){nodes{databaseId}}} pageInfo{hasNextPage endCursor}}}}}",
                "variables": ["owner": parts[0], "name": parts[1], "number": number, "after": after as Any? ?? NSNull()]
            ]))
            if let errors = response.errors, !errors.isEmpty { throw ReviewSubmissionError(message: errors.map(\.message).joined(separator: "\n")) }
            guard let threads = response.data?.repository?.pullRequest?.reviewThreads else { throw ReviewSubmissionError(message: String(localized: "The server does not expose GitHub review threads. Use the browser for resolution.")) }
            for thread in threads.nodes { for comment in thread.comments.nodes { if let id = comment.databaseId { result[id] = thread } } }
            if !threads.pageInfo.hasNextPage { return result }
            guard let cursor = threads.pageInfo.endCursor, cursor != after else { break }; after = cursor
        }
        throw ReviewSubmissionError(message: String(localized: "The thread list is too large. Use the browser for resolution."))
    }
    static func resolve(token: String, apiBase: String, threadID: String, resolved: Bool) async throws {
        guard !threadID.isEmpty, threadID.range(of: "^[0-9]+$", options: .regularExpression) == nil else { throw ReviewSubmissionError(message: String(localized: "Refresh the conversation before resolving this thread.")) }
        let operation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let data = try await Hosting.data(Hosting.request(.github, graphURL(apiBase), token: token, method: "POST", body: ["query": "mutation($id:ID!){\(operation)(input:{threadId:$id}){thread{id isResolved}}}", "variables": ["id": threadID]]))
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let errors = result["errors"] as? [[String: Any]], !errors.isEmpty { throw ReviewSubmissionError(message: errors.compactMap { $0["message"] as? String }.joined(separator: "\n")) }
        let payload = (result["data"] as? [String: Any])?[operation] as? [String: Any], thread = payload?["thread"] as? [String: Any]
        guard thread?["isResolved"] as? Bool == resolved else { throw ReviewSubmissionError(message: String(localized: "The server did not change the thread state. Refresh and try again.")) }
    }
}
