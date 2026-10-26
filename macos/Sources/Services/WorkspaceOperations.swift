import Foundation
import Observation

/// Workspace APIs share the repository/account guard used by reviews.
@MainActor enum WorkspaceOperations {
    static func issues(_ c: ReviewAccess, scope: String, search: String, page: Int) async throws
        -> (
            [CollaborationInboxItem], Bool
        )
    {
        let n = max(1, page)
        if c.target.provider == .github, !search.trimmed.isEmpty {
            let text = search.trimmed.replacingOccurrences(of: "\"", with: " ")
                .replacingOccurrences(
                    of: "\\", with: " ")
            let q =
                "repo:\(c.target.path) is:issue \(scope == "all" ? "" : "is:" + scope) \"\(text)\""
            let r = try await CollaborationAPI.object(
                c,
                c.apiBase + "/search/issues?"
                    + CollaborationAPI.query([
                        "q": q, "sort": "updated", "order": "desc", "per_page": "30",
                        "page": String(n),
                    ]))
            return (
                CollaborationAPI.array(r, "items").map(issue),
                n * 30 < min(1000, CollaborationAPI.number(r, "total_count"))
            )
        }
        var query = [
            "state": c.target.provider == .gitlab && scope == "open" ? "opened" : scope,
            "per_page": "30",
            "page": String(n), "sort": "updated", "order_by": "updated_at",
        ]
        if !search.trimmed.isEmpty { query["search"] = search.trimmed }
        let items = try await CollaborationAPI.list(
            c, CollaborationAPI.repo(c) + "/issues?" + CollaborationAPI.query(query))
        return (items.filter { $0["pull_request"] == nil }.map(issue), items.count == 30)
    }
    static func issue(_ i: [String: Any]) -> CollaborationInboxItem {
        let n =
            CollaborationAPI.number(i, "number") == 0
            ? CollaborationAPI.number(i, "iid") : CollaborationAPI.number(i, "number")
        return CollaborationInboxItem(
            id: "issue-\(n)", kind: "issue", number: n, title: CollaborationAPI.text(i, "title"),
            url: CollaborationAPI.text(i, "html_url").isEmpty
                ? CollaborationAPI.text(i, "web_url") : CollaborationAPI.text(i, "html_url"),
            body: CollaborationAPI.text(i, "body").isEmpty
                ? CollaborationAPI.text(i, "description") : CollaborationAPI.text(i, "body"),
            state: CollaborationAPI.text(i, "state"),
            author: CollaborationAPI.text(CollaborationAPI.obj(i, "user"), "login").isEmpty
                ? CollaborationAPI.text(CollaborationAPI.obj(i, "author"), "username")
                : CollaborationAPI.text(CollaborationAPI.obj(i, "user"), "login"))
    }
    static func saveIssue(_ c: ReviewAccess, title: String, body: String, number: Int? = nil)
        async throws -> CollaborationInboxItem
    {
        guard !title.trimmed.isEmpty else {
            throw CollaborationAPI.fail(String(localized: "A title is required."))
        }
        if let number, number < 1 {
            throw CollaborationAPI.fail(String(localized: "Invalid issue number."))
        }
        let payload =
            c.target.provider == .github
            ? ["title": title.trimmed, "body": body]
            : ["title": title.trimmed, "description": body]
        let url = CollaborationAPI.repo(c) + "/issues" + (number.map { "/\($0)" } ?? "")
        return issue(
            try await CollaborationAPI.object(
                c, url,
                method: number == nil ? "POST" : c.target.provider == .github ? "PATCH" : "PUT",
                body: payload))
    }
    static func repositories(_ c: ReviewAccess, search: String, page: Int) async throws -> (
        [RemoteRepo], Bool
    ) {
        let n = max(1, page)
        if c.target.provider == .github {
            let items: [[String: Any]]
            let more: Bool
            if !search.trimmed.isEmpty {
                let r = try await CollaborationAPI.object(
                    c,
                    c.apiBase + "/search/repositories?"
                        + CollaborationAPI.query([
                            "q": search.trimmed, "per_page": "30", "page": String(n),
                            "sort": "updated",
                        ]))
                items = CollaborationAPI.array(r, "items")
                more = n * 30 < min(1000, CollaborationAPI.number(r, "total_count"))
            } else {
                items = try await CollaborationAPI.list(
                    c, c.apiBase + "/user/repos?per_page=30&sort=updated&page=\(n)")
                more = items.count == 30
            }
            return (
                items.map {
                    RemoteRepo(
                        fullName: CollaborationAPI.text($0, "full_name"),
                        cloneURL: CollaborationAPI.text($0, "clone_url"),
                        isPrivate: CollaborationAPI.bool($0, "private"),
                        summary: $0["description"] as? String)
                }, more
            )
        }
        var q = [
            "per_page": "30", "page": String(n), "order_by": "last_activity_at", "sort": "desc",
        ]
        if search.trimmed.isEmpty { q["membership"] = "true" } else { q["search"] = search.trimmed }
        let items = try await CollaborationAPI.list(
            c, c.apiBase + "/projects?" + CollaborationAPI.query(q))
        return (
            items.map {
                RemoteRepo(
                    fullName: CollaborationAPI.text($0, "path_with_namespace"),
                    cloneURL: CollaborationAPI.text($0, "http_url_to_repo"),
                    isPrivate: CollaborationAPI.text($0, "visibility") != "public",
                    summary: $0["description"] as? String)
            }, items.count == 30
        )
    }
}

@MainActor @Observable final class WorkspaceIssueModel {
    var items: [CollaborationInboxItem] = []
    var page = 0
    var more = false
    var busy = false
    var error: String?
    var generation = UUID()
    var mutating = false
    func reset() {
        generation = UUID()
        items = []
        page = 0
        more = false
        busy = false
        error = nil
    }
    func load(_ c: ReviewAccess, scope: String, search: String, append: Bool = false) async {
        let id = UUID()
        generation = id
        busy = true
        error = nil
        defer { if generation == id { busy = false } }
        do {
            let (next, hasMore) = try await WorkspaceOperations.issues(
                c, scope: scope, search: search, page: append ? page + 1 : 1)
            guard generation == id, c.isCurrent?() != false else { return }
            items =
                append ? items + next.filter { item in !items.contains { $0.id == item.id } } : next
            page = append ? page + 1 : 1
            more = hasMore
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
}
