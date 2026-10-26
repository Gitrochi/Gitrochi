import Foundation

struct AccountWorkItem: Identifiable {
    let id: String
    let title: String
    let repository: String
    let host: String
    let url: String
    let number: Int
    let state: String
    let author: String
    var unread: Bool
    let readID: String?
    let origin: String
}
@MainActor enum AccountWorkAPI {
    static func origin(_ c: ReviewAccess, accountID: String = "") -> String {
        let values = [
            c.target.provider == .github ? "github" : "gitlab",
            c.apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")), c.me.lowercased(),
            accountID,
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
    }
    static func page(_ c: ReviewAccess, kind: String, page: Int, accountID: String = "")
        async throws -> (
            [AccountWorkItem], Bool
        )
    {
        let n = max(1, page)
        var records: [[String: Any]]
        var more = false
        if c.target.provider == .github {
            if kind == "inbox" {
                records = try await CollaborationAPI.list(
                    c, c.apiBase + "/notifications?all=true&per_page=30&page=\(n)")
                more = records.count == 30
            } else {
                let qualifier =
                    kind == "mine"
                    ? "is:pr is:open author:\(c.me)"
                    : kind == "assignedRequests"
                        ? "is:pr is:open assignee:\(c.me)"
                        : kind == "review"
                            ? "is:pr is:open review-requested:\(c.me)"
                            : kind == "myIssues"
                                ? "is:issue is:open author:\(c.me)"
                                : "is:issue is:open assignee:\(c.me)"
                let response = try await CollaborationAPI.object(
                    c,
                    c.apiBase + "/search/issues?"
                        + CollaborationAPI.query([
                            "q": qualifier, "per_page": "30", "page": String(n), "sort": "updated",
                            "order": "desc",
                        ]))
                records = CollaborationAPI.array(response, "items")
                more = n * 30 < min(1000, CollaborationAPI.number(response, "total_count"))
            }
        } else {
            var q = [
                "per_page": "30", "page": String(n),
                "state": kind == "inbox" ? "pending" : "opened", "order_by": "updated_at",
                "sort": "desc",
            ]
            let path: String
            if kind == "inbox" {
                path = "todos"
            } else if ["issues", "myIssues"].contains(kind) {
                path = "issues"
                q["scope"] = kind == "issues" ? "assigned_to_me" : "created_by_me"
            } else {
                path = "merge_requests"
                q["scope"] =
                    kind == "mine"
                    ? "created_by_me" : kind == "assignedRequests" ? "assigned_to_me" : "all"
                if kind == "review" { q["reviewer_username"] = c.me }
            }
            records = try await CollaborationAPI.list(
                c, c.apiBase + "/\(path)?" + CollaborationAPI.query(q))
            more = records.count == 30
        }
        guard c.isCurrent?() != false else {
            throw CollaborationAPI.fail(
                String(localized: "The repository or account changed. Reopen this action."))
        }
        return (records.compactMap { item(c, $0, kind: kind, accountID: accountID) }, more)
    }
    static func item(
        _ c: ReviewAccess, _ record: [String: Any], kind: String, accountID: String = ""
    ) -> AccountWorkItem? {
        guard let server = URL(string: c.apiBase) else { return nil }
        let text = CollaborationAPI.text
        let obj = CollaborationAPI.obj
        let subject = obj(record, "subject")
        let target = obj(record, "target")
        var repository = text(obj(record, "repository"), "full_name")
        if repository.isEmpty { repository = text(obj(record, "project"), "path_with_namespace") }
        var number = CollaborationAPI.number(record, "number")
        if number == 0 { number = CollaborationAPI.number(record, "iid") }
        if number == 0 { number = CollaborationAPI.number(target, "iid") }
        if number == 0 { number = Int(text(subject, "url").split(separator: "/").last ?? "") ?? 0 }
        var raw = text(record, "html_url")
        if raw.isEmpty { raw = text(record, "web_url") }
        if raw.isEmpty { raw = text(record, "target_url") }
        if c.target.provider == .github {
            if repository.isEmpty, let api = URL(string: text(record, "repository_url")),
                api.host == server.host, api.scheme == server.scheme, api.port == server.port
            {
                repository = api.path.replacingOccurrences(of: "/repos/", with: "")
            }
            if kind == "inbox", !["Issue", "PullRequest"].contains(text(subject, "type")) {
                number = 0
            }
            if raw.isEmpty, !repository.isEmpty {
                raw =
                    "https://github.com/\(repository)"
                    + (number > 0
                        ? "/\(text(subject,"type")=="PullRequest" ? "pull":"issues")/\(number)"
                        : "")
            }
        }
        guard let url = URL(string: raw), url.scheme == server.scheme, url.user == nil,
            url.password == nil
        else { return nil }
        if c.target.provider == .github {
            guard url.host == "github.com", url.port == nil || url.port == 443 else { return nil }
        } else {
            guard url.host == server.host, url.port == server.port else { return nil }
        }
        if repository.isEmpty {
            var path = url.path
            let base = server.path.replacingOccurrences(of: "/api/v4", with: "")
            if !base.isEmpty, path.hasPrefix(base) { path = String(path.dropFirst(base.count)) }
            repository =
                path.components(separatedBy: "/-/").first?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")) ?? ""
        }
        guard !repository.isEmpty else { return nil }
        let id =
            (record["id"] as? String) ?? (record["id"] as? Int).map(String.init) ?? String(number)
        let title =
            text(record, "title").isEmpty
            ? (text(subject, "title").isEmpty ? text(target, "title") : text(subject, "title"))
            : text(record, "title")
        let state =
            text(record, "state").isEmpty
            ? (text(record, "target_type").isEmpty
                ? text(subject, "type") : text(record, "target_type")) : text(record, "state")
        let author =
            text(obj(record, "user"), "login").isEmpty
            ? text(obj(record, "author"), "username") : text(obj(record, "user"), "login")
        return AccountWorkItem(
            id: "\(kind)-\(id)-\(repository)", title: title, repository: repository,
            host: c.target.host, url: url.absoluteString, number: number, state: state,
            author: author,
            unread: kind == "inbox"
                && (c.target.provider == .gitlab || CollaborationAPI.bool(record, "unread")),
            readID: kind == "inbox" ? id : nil, origin: origin(c, accountID: accountID))
    }
    static func read(_ c: ReviewAccess, item: AccountWorkItem, accountID: String = "") async throws
    {
        guard item.origin == origin(c, accountID: accountID), let id = item.readID,
            id.allSatisfy(\.isNumber), !id.isEmpty,
            item.host == c.target.host
        else { throw CollaborationAPI.fail(String(localized: "Invalid notification.")) }
        let path =
            c.target.provider == .github
            ? "/notifications/threads/\(id)" : "/todos/\(id)/mark_as_done"
        _ = try await CollaborationAPI.value(
            c, c.apiBase + path, method: c.target.provider == .github ? "PATCH" : "POST")
    }
}
