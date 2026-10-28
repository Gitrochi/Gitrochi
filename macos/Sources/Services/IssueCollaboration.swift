import Foundation

struct IssueLinkedRequest: Identifiable {
    var id: String { url }
    let number: Int
    let title: String
    let url: String
    let state: String
}

extension CollaborationAPI {
    /// Own comments are re-read before writes so another edit is never silently overwritten.
    static func changeIssueComment(_ c: ReviewAccess, item: CollaborationInboxItem, comment: CollaborationInboxComment, body: String?) async throws {
        guard item.kind == "issue", !item.isRequest, comment.id.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil, body == nil || !body!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(String(localized: "Choose a loaded issue comment.")) }
        let github = c.target.provider == .github, base = repo(c)
        let endpoint = github ? base + "/issues/comments/" + comment.id : base + "/issues/\(item.number)/notes/" + comment.id
        let fresh = try await object(c, endpoint)
        let user = fresh[github ? "user" : "author"] as? [String: Any] ?? [:]
        let author = user[github ? "login" : "username"] as? String ?? ""
        guard fresh["system"] as? Bool != true, author.caseInsensitiveCompare(c.me) == .orderedSame, author.caseInsensitiveCompare(comment.author) == .orderedSame else { throw fail(String(localized: "Only your own comments can be changed here.")) }
        guard fresh["body"] as? String == comment.body, !github || (fresh["issue_url"] as? String)?.lowercased() == (base + "/issues/\(item.number)").lowercased() else { throw fail(String(localized: "This comment changed on the server. Refresh before saving.")) }
        _ = try await value(c, endpoint, method: body == nil ? "DELETE" : github ? "PATCH" : "PUT", body: body.map { ["body": $0] })
    }
    /// GitHub timeline references and GitLab related MRs remain paginated and server scoped.
    static func issueLinkedRequests(_ c: ReviewAccess, item: CollaborationInboxItem, page: Int) async throws -> ([IssueLinkedRequest], Bool) {
        let github = c.target.provider == .github
        let endpoint = repo(c) + "/issues/\(item.number)/" + (github ? "timeline" : "related_merge_requests") + "?per_page=30&page=\(max(1, page))"
        let rows = try await list(c, endpoint)
        var items: [IssueLinkedRequest] = []
        for row in rows {
            let source = (row["source"] as? [String: Any])?["issue"] as? [String: Any]
            guard let entry = github ? (row["event"] as? String == "cross-referenced" && source?["pull_request"] != nil ? source : nil) : row else { continue }
            let address = entry[github ? "html_url" : "web_url"] as? String ?? ""
            guard let url = URL(string: address), let origin = URL(string: "https://" + c.target.host), url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port, url.user == nil, url.password == nil,
                  url.path.range(of: github ? #"/pull/[0-9]+/?$"# : #"/(?:-/)?merge_requests/[0-9]+/?$"#, options: .regularExpression) != nil,
                  let number = entry[github ? "number" : "iid"] as? Int, number > 0, !items.contains(where: { $0.url == address }) else { continue }
            items.append(IssueLinkedRequest(number: number, title: entry["title"] as? String ?? "", url: address, state: entry["state"] as? String ?? ""))
        }
        return (items, rows.count == 30)
    }
}
