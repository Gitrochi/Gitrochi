import Foundation
import Observation

struct ReviewAccess { let target: RepoTarget; let token: String; let apiBase: String; let me: String; var isCurrent: (() -> Bool)? = nil }

struct RequestQuery {
    var scope = "open"
    var search = ""
    var page = 1
}
struct RequestLifecycle {
    var number: Int; var headSHA: String; var state: String; var title: String; var body: String; var base: String
    var reviewers: [String]; var methods: [String]; var blockers: [String]; var checks: String; var policy: String
    var canEdit: Bool; var canRebase: Bool
}
struct CollaborationInboxItem: Identifiable {
    var id: String; var kind: String; var number: Int; var title: String; var url: String; var body: String
    var state: String; var author: String; var unread = false; var readID: String?; var isRequest = false
}
struct CollaborationInboxComment: Identifiable {
    var id: String; var author: String; var body: String; var createdAt: String? = nil
}
struct CollaborationInboxDetail {
    var item: CollaborationInboxItem; var comments: [CollaborationInboxComment]; var page = 1; var more = false
}
@MainActor @Observable final class CollaborationState {
    var query = RequestQuery()
    var more = false
    var warning: String?
    var lifecycle: RequestLifecycle?
    var lifecycleLoading = false
    var lifecycleBusy = false
    var lifecycleError: String?
    var inboxKind = "issue"
    var inbox: [CollaborationInboxItem] = []
    var inboxDetail: CollaborationInboxDetail?
    var inboxPage = 1
    var inboxMore = false
    var inboxLoading = false
    var inboxBusy = false
    var inboxError: String?
    var contextID = UUID()
    var listID = UUID()
    var lifecycleID = UUID()
    var inboxID = UUID()
    var detailID = UUID()
    func reset() {
        contextID = UUID(); listID = UUID(); lifecycleID = UUID(); inboxID = UUID(); detailID = UUID()
        query = RequestQuery(); more = false; warning = nil; lifecycle = nil; lifecycleLoading = false; lifecycleBusy = false; lifecycleError = nil
        inbox = []; inboxDetail = nil; inboxPage = 1; inboxMore = false; inboxLoading = false; inboxBusy = false; inboxError = nil
    }
}

/// 호스팅 서버 검색·병합·이슈 API. 쓰기 전에 저장소 컨텍스트는 Store에서 다시 확인한다.
@MainActor enum CollaborationAPI {
    typealias Object = [String: Any]
    static func repo(_ c: ReviewAccess) -> String { c.apiBase + (c.target.provider == .github ? "/repos/\(c.target.path)" : "/projects/\(Hosting.projectID(c.target.path))") }
    static func requestURL(_ c: ReviewAccess, _ n: Int) -> String { repo(c) + (c.target.provider == .github ? "/pulls/" : "/merge_requests/") + String(n) }
    static func value(_ c: ReviewAccess, _ url: String, method: String = "GET", body: Object? = nil) async throws -> Any {
        guard c.isCurrent?() != false else { throw fail(String(localized: "The repository or account changed. Reopen this action.")) }
        let data = try await Hosting.data(Hosting.request(c.target.provider, url, token: c.token, method: method, body: body))
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }
    static func object(_ c: ReviewAccess, _ url: String, method: String = "GET", body: Object? = nil) async throws -> Object {
        guard let value = try await value(c, url, method: method, body: body) as? Object else { throw fail("The server returned an unexpected response.") }
        return value
    }
    static func list(_ c: ReviewAccess, _ url: String) async throws -> [Object] {
        guard let value = try await value(c, url) as? [Object] else { throw fail("The server returned an unexpected response.") }
        return value
    }
    static func fail(_ message: String) -> NSError { NSError(domain: "Gitrochi.Collaboration", code: 0, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func text(_ o: Object, _ key: String) -> String { o[key] as? String ?? "" }
    static func obj(_ o: Object, _ key: String) -> Object { o[key] as? Object ?? [:] }
    static func array(_ o: Object, _ key: String) -> [Object] { o[key] as? [Object] ?? [] }
    static func bool(_ o: Object, _ key: String) -> Bool { o[key] as? Bool ?? false }
    static func number(_ o: Object, _ key: String) -> Int { o[key] as? Int ?? 0 }
    static func query(_ values: [String: String]) -> String {
        var c = URLComponents(); c.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return c.percentEncodedQuery ?? ""
    }
    static func pull(_ c: ReviewAccess, _ p: Object) throws -> PullRequest {
        if c.target.provider == .github {
            let head = obj(p, "head"), base = obj(p, "base")
            guard number(p, "number") > 0, !text(head, "sha").isEmpty else { throw fail(String(localized: "The server returned an unexpected response.")) }
            return PullRequest(number: number(p, "number"), title: text(p, "title"), author: text(obj(p, "user"), "login"), source: text(head, "ref"), target: text(base, "ref"), url: text(p, "html_url"), isDraft: bool(p, "draft"), updated: Hosting.date(p["updated_at"] as? String), body: text(p, "body"), headSHA: text(head, "sha"), fromFork: text(obj(head, "repo"), "full_name").lowercased() != c.target.path.lowercased())
        }
        guard number(p, "iid") > 0 else { throw fail(String(localized: "The server returned an unexpected response.")) }
        return PullRequest(number: number(p, "iid"), title: text(p, "title"), author: text(obj(p, "author"), "username"), source: text(p, "source_branch"), target: text(p, "target_branch"), url: text(p, "web_url"), isDraft: bool(p, "draft") || bool(p, "work_in_progress"), updated: Hosting.date(p["updated_at"] as? String), body: text(p, "description"), headSHA: text(p, "sha"), fromFork: number(p, "source_project_id") != number(p, "target_project_id"))
    }
    /// One page of the request list. GitHub's list endpoint carries everything the list shows, so no request is read on its own;
    /// it has no author, reviewer or text filter, so those narrow each loaded page here (the search API is rate limited,
    /// lags behind and is refused for some repositories). Windows: `requestPage` in collaboration.ts.
    static func requests(_ c: ReviewAccess, _ q: RequestQuery) async throws -> ([PullRequest], Bool, String?) {
        let search = q.search.trimmed
        if c.target.provider == .github {
            let closed = q.scope == "closed" || q.scope == "merged"
            let filtered = closed || q.scope == "mine" || q.scope == "reviewRequested" || !search.isEmpty
            let perPage = filtered ? 100 : 30
            let page = try await list(c, repo(c) + "/pulls?" + query(["state": closed ? "closed" : "open", "sort": "updated", "direction": "desc", "per_page": String(perPage), "page": String(q.page)]))
            let items = try page.filter { matches(c, $0, q.scope, search: search) }.map { try pull(c, $0) }
            return (items, page.count == perPage, search.isEmpty ? nil : String(localized: "Search filters loaded pages. Load more to search older items."))
        }
        var params = ["state": q.scope == "closed" ? "closed" : q.scope == "merged" ? "merged" : "opened", "per_page": "30", "page": String(q.page), "order_by": "updated_at", "sort": "desc", "scope": "all"]
        if !search.isEmpty { params["search"] = search }
        if q.scope == "mine" { params["author_username"] = c.me }
        if q.scope == "reviewRequested" { params["reviewer_username"] = c.me }
        let items = try await list(c, repo(c) + "/merge_requests?" + query(params))
        return (try items.map { try pull(c, $0) }, items.count == 30, nil)
    }
    private static func matches(_ c: ReviewAccess, _ p: Object, _ scope: String, search: String) -> Bool {
        let me = { (name: String) in name.caseInsensitiveCompare(c.me) == .orderedSame }
        switch scope {
        case "merged": guard p["merged_at"] is String else { return false }
        case "closed": guard !(p["merged_at"] is String) else { return false }
        case "mine": guard me(text(obj(p, "user"), "login")) else { return false }
        case "reviewRequested": guard array(p, "requested_reviewers").contains(where: { me(text($0, "login")) }) else { return false }
        default: break
        }
        guard !search.isEmpty else { return true }
        return [text(p, "title"), "#" + String(number(p, "number")), text(obj(p, "user"), "login"), text(obj(p, "head"), "ref")].contains { $0.localizedCaseInsensitiveContains(search) }
    }
    static func lifecycle(_ c: ReviewAccess, _ n: Int) async throws -> RequestLifecycle {
        let p = try await object(c, requestURL(c, n) + (c.target.provider == .gitlab ? "?with_merge_status_recheck=true" : ""))
        let r = try await object(c, repo(c)); var blockers: [String] = []
        if c.target.provider == .github {
            let state = bool(p, "merged") ? "merged" : text(p, "state")
            let permissions = obj(r, "permissions"), write = bool(permissions, "push") || bool(permissions, "maintain") || bool(permissions, "admin")
            let readiness = text(p, "mergeable_state")
            if state != "open" { blockers.append(String(localized: "This request is not open.")) }
            if bool(p, "draft") { blockers.append(String(localized: "Draft requests cannot be merged.")) }
            if !write { blockers.append(String(localized: "The account cannot merge this request.")) }
            if !bool(p, "mergeable") || !["clean", "has_hooks"].contains(readiness) { blockers.append(String(localized: "Merge readiness: \(readiness.isEmpty ? "unknown" : readiness). Refresh after checks, approvals and conflicts are resolved.")) }
            let status = try? await object(c, repo(c) + "/commits/" + Hosting.projectID(text(obj(p, "head"), "sha")) + "/status")
            let checks = try? await object(c, repo(c) + "/commits/" + Hosting.projectID(text(obj(p, "head"), "sha")) + "/check-runs?filter=latest&per_page=100")
            var ci = String(localized: "No checks reported")
            if let status, let checks, let jobs = checks["check_runs"] as? [Object], checks["total_count"] is Int {
                let complete = jobs.filter { text($0, "status") == "completed" && ["success", "neutral", "skipped"].contains(text($0, "conclusion")) }.count
                ci = String(localized: "Checks: \(complete)/\(number(checks, "total_count")) complete; commit status: \(number(status, "total_count") > 0 ? text(status, "state") : "none")")
                if number(checks, "total_count") > 100 || complete < jobs.count || (number(status, "total_count") > 0 && text(status, "state") != "success") { blockers.append(String(localized: "Checks are incomplete, pending or failed. Refresh before merging.")) }
            } else { blockers.append(String(localized: "The server could not verify check results.")) }
            var methods: [String] = []
            if bool(r, "allow_merge_commit") { methods.append("merge") }; if bool(r, "allow_squash_merge") { methods.append("squash") }; if bool(r, "allow_rebase_merge") { methods.append("rebase") }
            if methods.isEmpty { blockers.append(String(localized: "The server did not allow a merge method.")) }
            return RequestLifecycle(number: n, headSHA: text(obj(p, "head"), "sha"), state: state, title: text(p, "title"), body: text(p, "body"), base: text(obj(p, "base"), "ref"), reviewers: array(p, "requested_reviewers").map { text($0, "login") }, methods: methods, blockers: blockers, checks: readiness + " · " + ci, policy: String(localized: "GitHub branch rules, required checks and approvals are enforced again by the server."), canEdit: text(obj(p, "user"), "login") == c.me || write, canRebase: false)
        }
        let approvals = try? await object(c, requestURL(c, n) + "/approvals")
        let state = text(p, "state"), readiness = (p["detailed_merge_status"] as? String) ?? (p["merge_status"] as? String) ?? "unknown"
        let canMerge = bool(obj(p, "user"), "can_merge"), pipeline = text(obj(p, "head_pipeline"), "status")
        if state != "opened" { blockers.append(String(localized: "This request is not open.")) }
        if bool(p, "draft") || bool(p, "work_in_progress") { blockers.append(String(localized: "Draft requests cannot be merged.")) }
        if !canMerge { blockers.append(String(localized: "The account cannot merge this request.")) }
        if !["mergeable", "can_be_merged"].contains(readiness) { blockers.append(String(localized: "Merge readiness: \(readiness). Refresh after checks, approvals and conflicts are resolved.")) }
        if approvals?["approvals_left"] == nil && approvals?["approved"] as? Bool != true { blockers.append(String(localized: "The server could not verify approval requirements.")) }
        else if (approvals?["approvals_left"] as? Int ?? 0) > 0 { blockers.append(String(localized: "More approvals are required.")) }
        if bool(r, "only_allow_merge_if_pipeline_succeeds") && pipeline != "success" { blockers.append(String(localized: "The required pipeline has not succeeded.")) }
        let squash = text(r, "squash_option"), methods = squash == "always" ? ["squash"] : squash == "never" ? ["merge"] : ["merge", "squash"]
        return RequestLifecycle(number: n, headSHA: text(p, "sha"), state: state == "opened" ? "open" : state, title: text(p, "title"), body: text(p, "description"), base: text(p, "target_branch"), reviewers: array(p, "reviewers").map { text($0, "username") }, methods: methods, blockers: blockers, checks: "\(readiness) · pipeline: \(pipeline.isEmpty ? "none" : pipeline)", policy: String(localized: "GitLab project merge method: \(text(r, "merge_method")). The server enforces approval, discussion and pipeline rules."), canEdit: text(obj(p, "author"), "username") == c.me || canMerge, canRebase: state == "opened" && canMerge)
    }
    static func merge(_ c: ReviewAccess, expected: RequestLifecycle, method: String) async throws {
        let fresh = try await lifecycle(c, expected.number)
        guard !expected.headSHA.isEmpty, fresh.headSHA == expected.headSHA, fresh.base == expected.base else { throw fail(String(localized: "The request changed. Refresh and review the latest commit before merging.")) }
        guard fresh.blockers.isEmpty, fresh.methods.contains(method) else { throw fail(fresh.blockers.joined(separator: "\n")) }
        let body: Object = c.target.provider == .github ? ["sha": expected.headSHA, "merge_method": method] : ["sha": expected.headSHA, "squash": method == "squash", "should_remove_source_branch": false]
        let result = try await object(c, requestURL(c, expected.number) + "/merge", method: "PUT", body: body)
        guard c.target.provider == .github ? bool(result, "merged") : text(result, "state") == "merged" else { throw fail(String(localized: "The server did not merge this request.")) }
    }
    static func update(_ c: ReviewAccess, _ n: Int, title: String, body: String, base: String) async throws {
        _ = try await value(c, requestURL(c, n), method: c.target.provider == .github ? "PATCH" : "PUT", body: c.target.provider == .github ? ["title": title, "body": body, "base": base] : ["title": title, "description": body, "target_branch": base])
    }
    static func setState(_ c: ReviewAccess, _ n: Int, open: Bool) async throws {
        _ = try await value(c, requestURL(c, n), method: c.target.provider == .github ? "PATCH" : "PUT", body: c.target.provider == .github ? ["state": open ? "open" : "closed"] : ["state_event": open ? "reopen" : "close"])
    }
    static func reviewers(_ c: ReviewAccess, _ n: Int, names: [String], previous: [String]) async throws {
        let names = Array(Set(names.map(\.trimmed).filter { !$0.isEmpty })).sorted()
        if c.target.provider == .github {
            let add = names.filter { !previous.contains($0) }, remove = previous.filter { !names.contains($0) }
            if !add.isEmpty { _ = try await value(c, requestURL(c, n) + "/requested_reviewers", method: "POST", body: ["reviewers": add]) }
            if !remove.isEmpty { _ = try await value(c, requestURL(c, n) + "/requested_reviewers", method: "DELETE", body: ["reviewers": remove]) }
        } else {
            var ids: [Int] = []
            for name in names {
                let users = try await list(c, c.apiBase + "/users?" + query(["username": name]))
                guard let user = users.first(where: { text($0, "username").lowercased() == name.lowercased() }), number(user, "id") > 0 else { throw fail(String(localized: "Reviewer not found: \(name)")) }
                ids.append(number(user, "id"))
            }
            _ = try await value(c, requestURL(c, n), method: "PUT", body: ["reviewer_ids": ids.isEmpty ? [0] : ids])
        }
    }
    static func issue(_ p: Object) -> CollaborationInboxItem {
        let n = (p["number"] as? Int) ?? number(p, "iid")
        return CollaborationInboxItem(id: "issue-\(n)", kind: "issue", number: n, title: text(p, "title"), url: (p["html_url"] as? String) ?? text(p, "web_url"), body: (p["body"] as? String) ?? text(p, "description"), state: text(p, "state"), author: (obj(p, "user")["login"] as? String) ?? text(obj(p, "author"), "username"))
    }
    static func inbox(_ c: ReviewAccess, kind: String, page: Int) async throws -> ([CollaborationInboxItem], Bool) {
        if kind == "review" {
            let (items, more, _) = try await requests(c, RequestQuery(scope: "reviewRequested", search: "", page: page))
            return (items.map { CollaborationInboxItem(id: "review-\($0.number)", kind: "review", number: $0.number, title: $0.title, url: $0.url, body: $0.body, state: "open", author: $0.author, isRequest: true) }, more)
        }
        if kind == "issue" {
            let params = c.target.provider == .github ? ["state": "open", "assignee": c.me] : ["state": "opened", "assignee_username": c.me]
            let values = try await list(c, repo(c) + "/issues?" + query(params.merging(["per_page": "30", "page": String(page)]) { $1 }))
            return (values.filter { $0["pull_request"] == nil }.map(issue), values.count == 30)
        }
        if c.target.provider == .github {
            let values = try await list(c, repo(c) + "/notifications?all=true&per_page=30&page=\(page)")
            let items = values.filter { ["mention", "team_mention", "review_requested"].contains(text($0, "reason")) && ["Issue", "PullRequest"].contains(text(obj($0, "subject"), "type")) }.compactMap { v -> CollaborationInboxItem? in
                let subject = obj(v, "subject"), isRequest = text(subject, "type") == "PullRequest"
                guard let n = Int(text(subject, "url").split(separator: "/").last ?? ""), n > 0 else { return nil }
                let id = text(v, "id")
                return CollaborationInboxItem(id: "mention-\(id)", kind: "mention", number: n, title: text(subject, "title"), url: "https://\(c.target.host)/\(c.target.path)/\(isRequest ? "pull" : "issues")/\(n)", body: "", state: text(subject, "type"), author: "", unread: bool(v, "unread"), readID: id, isRequest: isRequest)
            }
            return (items, values.count == 30)
        }
        let values = try await list(c, c.apiBase + "/todos?state=pending&per_page=30&page=\(page)")
        let items = values.filter { text(obj($0, "project"), "path_with_namespace").lowercased() == c.target.path.lowercased() && ["Issue", "MergeRequest"].contains(text($0, "target_type")) && ["mentioned", "directly_addressed", "review_requested"].contains(text($0, "action_name")) }.map { v in
            let target = obj(v, "target"), id = String(number(v, "id"))
            return CollaborationInboxItem(id: "mention-\(id)", kind: "mention", number: number(target, "iid"), title: text(target, "title"), url: text(v, "target_url"), body: text(v, "body"), state: text(v, "target_type"), author: text(obj(v, "author"), "username"), unread: true, readID: id, isRequest: text(v, "target_type") == "MergeRequest")
        }
        return (items, values.count == 30)
    }
    static func detail(_ c: ReviewAccess, item: CollaborationInboxItem, page: Int) async throws -> CollaborationInboxDetail {
        let base = repo(c) + "/\(c.target.provider == .github ? "issues" : item.isRequest ? "merge_requests" : "issues")/\(item.number)"
        let detail = try await object(c, item.isRequest && c.target.provider == .github ? requestURL(c, item.number) : base)
        let values = try await list(c, base + "/\(c.target.provider == .github ? "comments" : "notes")?per_page=30&page=\(page)")
        var item = item; item.title = text(detail, "title"); item.body = (detail["body"] as? String) ?? text(detail, "description"); item.state = text(detail, "state")
        let comments = values.map { CollaborationInboxComment(id: String(number($0, "id")), author: c.target.provider == .github ? text(obj($0, "user"), "login") : text(obj($0, "author"), "username"), body: text($0, "body"), createdAt: $0["created_at"] as? String) }
        return CollaborationInboxDetail(item: item, comments: comments, page: page, more: values.count == 30)
    }
    static func inboxAction(_ c: ReviewAccess, item: CollaborationInboxItem, action: String, body: String) async throws {
        if action == "read", let id = item.readID {
            _ = try await value(c, c.target.provider == .github ? c.apiBase + "/notifications/threads/\(Hosting.projectID(id))" : c.apiBase + "/todos/\(Hosting.projectID(id))/mark_as_done", method: c.target.provider == .github ? "PATCH" : "POST")
        } else if action == "comment" {
            guard !body.trimmed.isEmpty else { return }
            let path = c.target.provider == .github ? "issues/\(item.number)/comments" : "\(item.isRequest ? "merge_requests" : "issues")/\(item.number)/notes"
            _ = try await value(c, repo(c) + "/" + path, method: "POST", body: ["body": body.trimmed])
        } else if item.kind == "issue" {
            _ = try await value(c, repo(c) + "/issues/\(item.number)", method: c.target.provider == .github ? "PATCH" : "PUT", body: c.target.provider == .github ? ["state": action == "reopen" ? "open" : "closed"] : ["state_event": action == "reopen" ? "reopen" : "close"])
        }
    }
}
