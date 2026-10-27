import Foundation

enum HostingHubSection: String, CaseIterable, Identifiable {
    case releases, projects, organizations, gists
    var id: String { rawValue }
    var title: String { switch self { case .releases: return String(localized: "Releases"); case .projects: return String(localized: "Projects"); case .organizations: return String(localized: "Organizations"); case .gists: return String(localized: "Gists") } }
}
struct HubItem: Identifiable { var id: String; var title: String; var subtitle = ""; var body = ""; var url = ""; var editable = false; var data: [String: Any] = [:]; var avatarURL: URL? = nil }
struct HubFile: Identifiable { var id: String { name }; var name: String; var content: String; var truncated = false }
struct HubMember: Identifiable {
    var id: String
    var name: String
    var role: String
    var username = ""
    var avatarURL: URL?
    var profileURL: URL?
}
struct HubRepository: Identifiable { var id: String; var name: String; var description: String; var cloneURL: String; var url: String }
struct HubAsset: Identifiable { var id: String; var name: String; var size: Int?; var downloads: Int?; var url: String }
enum HubProjectFieldKind: String { case singleSelect, text, number, date, iteration, unsupported }
struct HubProjectOption: Identifiable { var id: String; var name: String; var startDate: String?; var duration: Int? }
struct HubProjectField: Identifiable { var id: String; var name: String; var options: [HubProjectOption]; var kind: HubProjectFieldKind = .singleSelect }
struct HubProjectColumn: Identifiable { var id: String; var title: String; var rows: [HubProjectRow] }
enum HubProjectRowKind: String { case issue, pullRequest, draft, redacted }
struct HubProjectRow: Identifiable { var id: String; var title: String; var body: String; var url: String; var contentID: String; var statuses: [String: String]; var labels: [String] = []; var kind: HubProjectRowKind = .issue; var number: Int?; var repository = ""; var state = ""; var assignees: [String] = []; var updatedAt = ""; var headRefName = ""; var archived = false; var values: [String: String] = [:]; var author: String? = nil; var createdAt: String? = nil }
struct HubDetail { var item: HubItem; var files: [HubFile] = []; var members: [HubMember] = []; var repositories: [HubRepository] = []; var assets: [HubAsset] = []; var fields: [HubProjectField] = []; var rows: [HubProjectRow] = []; var more = false; var cursor: String?; var notice: String?; var starred: Bool? }
struct HubPage { var items: [HubItem]; var more: Bool; var cursor: String?; var notice: String? }
struct HubReleaseInput { var tag = ""; var name = ""; var body = ""; var target = ""; var draft = true; var prerelease = false }
struct HubGistInput { var description = ""; var isPublic = false; var files = [HubFile(name: "snippet.txt", content: "")] }
struct HostingHubState {
    var section: HostingHubSection = .releases
    var selectedAccountID: String?
    var requestedProjectRowID: String?
    var projectScope = "repository"
    var projectSource = "remote"
    var items: [HubItem] = []; var detail: HubDetail?
    var projectPermissionRequired = false
    var allowingCredentialAccess = false
    var uncertainWrite = false; var loading = false; var detailLoading = false; var busy = false; var error: String?; var notice: String?
    var query = ""; var page = 0; var cursor: String?; var more = false; var detailPage = 1; var detailCursor: String?; var tab = "repositories"
    var generation = UUID(); var listID = UUID(); var detailID = UUID(); var context = ""
    var filteredItems: [HubItem] { let q = query.trimmingCharacters(in: .whitespacesAndNewlines); return q.isEmpty ? items : items.filter { ($0.title + " " + $0.subtitle + " " + $0.body).localizedCaseInsensitiveContains(q) } }
}
struct HubAccess { let target: RepoTarget; let token: String; let apiBase: String; let me: String; var isCurrent: (() -> Bool)?; var local = false }

struct HubProjectPermissionError: LocalizedError {
    var errorDescription: String? { String(localized: "Connect project access for this GitHub account to load projects.") }
}

struct HubProjectActionDeniedError: LocalizedError {
    var detail: String? = nil
    var errorDescription: String? {
        String(localized: "GitHub denied this project action. Check the token's Projects access and the owner's policies. A paid plan does not grant these permissions.") + (detail.map { "\n\n" + $0 } ?? "")
    }
}

struct HubUncertainWriteError: LocalizedError { let message: String; var createdProject: HubItem? = nil; var errorDescription: String? { message } }

/// Every authenticated request remains on the selected account's API origin and checks the captured context.
@MainActor enum HostingHubAPI {
    typealias J = [String: Any]
    static func s(_ x: J, _ key: String) -> String { x[key] as? String ?? "" }
    static func obj(_ x: J, _ key: String) -> J { x[key] as? J ?? [:] }
    static func arr(_ x: J, _ key: String) -> [J] { x[key] as? [J] ?? [] }
    static func id(_ x: J, _ key: String = "id") -> String { (x[key] as? String) ?? (x[key] as? NSNumber)?.stringValue ?? "" }
    static func enc(_ s: String) -> String { Hosting.projectID(s) }
    static func fail(_ text: String) -> NSError { NSError(domain: "HostingHub", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func check(_ c: HubAccess) throws { guard c.isCurrent?() != false else { throw fail(String(localized: "The repository or account changed. Reopen this action.")) } }
    static func repo(_ c: HubAccess) -> String { c.apiBase + (c.target.provider == .github ? "/repos/" + c.target.path.split(separator: "/").map { enc(String($0)) }.joined(separator: "/") : "/projects/" + enc(c.target.path)) }
    static func value(_ c: HubAccess, _ url: String, method: String = "GET", body: J? = nil) async throws -> Any {
        try check(c)
        guard !c.local else { throw fail(String(localized: "Local projects do not send requests to GitHub.")) }
        guard let base = URL(string: c.apiBase), let u = URL(string: url), u.scheme == base.scheme, u.host == base.host, u.port == base.port, u.path.hasPrefix(base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "/" : base.path + "/") else { throw fail(String(localized: "The server returned an unsafe address.")) }
        let data = try await Hosting.data(Hosting.request(c.target.provider, url, token: c.token, method: method, body: body)); try check(c)
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }
    static func create(_ c: HubAccess, _ url: String, body: J) async throws {
        do { _ = try await value(c, url, method: "POST", body: body) }
        catch let error as HostingError where (400..<500).contains(error.status) { throw error }
        catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
    }
    static func boardIssueQuery(_ board: J, page: Int) -> String {
        var parameters = ["state": board["hide_closed_list"] as? Bool == true ? "opened" : "all", "scope": "all", "per_page": "30", "page": String(max(1, page)), "order_by": "updated_at"]
        let labels = arr(board, "labels").map { s($0, "name") }.filter { !$0.isEmpty }; if !labels.isEmpty { parameters["labels"] = labels.joined(separator: ",") }
        let assignee = id(obj(board, "assignee")); if !assignee.isEmpty { parameters["assignee_id"] = assignee }
        let milestone = s(obj(board, "milestone"), "title"); if !milestone.isEmpty { parameters["milestone"] = milestone }
        if let weight = board["weight"] as? NSNumber { parameters["weight"] = weight.stringValue }
        let iteration = id(obj(board, "iteration")); if !iteration.isEmpty { parameters["iteration_id"] = iteration }
        var components = URLComponents(); components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return components.percentEncodedQuery ?? ""
    }
    static func object(_ c: HubAccess, _ url: String, method: String = "GET", body: J? = nil) async throws -> J { guard let x = try await value(c, url, method: method, body: body) as? J else { throw fail(String(localized: "The server returned an unexpected response.")) }; return x }
    static func list(_ c: HubAccess, _ url: String) async throws -> [J] { guard let x = try await value(c, url) as? [J] else { throw fail(String(localized: "The server returned an unexpected response.")) }; return x }
    static func graph(_ c: HubAccess, _ query: String, _ variables: J) async throws -> J {
        let x = try await object(c, c.apiBase + "/graphql", method: "POST", body: ["query": query, "variables": variables])
        let errors = arr(x, "errors")
        if errors.contains(where: { error in
            let message = s(error, "message").lowercased()
            return s(error, "type") == "INSUFFICIENT_SCOPES" || message.contains("insufficient scope") || message.contains("required scopes") || message.contains("read:project")
        }) { throw HubProjectPermissionError() }
        if errors.contains(where: { ["FORBIDDEN", "RESOURCE_NOT_ACCESSIBLE"].contains(s($0, "type")) }) { throw HubProjectActionDeniedError() }
        guard errors.isEmpty, let data = x["data"] as? J else { throw fail(String(localized: "Projects could not be loaded. Retry or open GitHub in your browser.")) }
        return data
    }
    static func safeURL(_ c: HubAccess, _ value: String, asset: Bool = false) -> URL? { safeURL(provider: c.target.provider, host: c.target.host, value, asset: asset) }
    static func safeURL(provider: Provider, host: String, _ value: String, asset: Bool = false) -> URL? {
        guard let u = URL(string: value), u.scheme == "https", u.user == nil, u.password == nil, let h = u.host?.lowercased() else { return nil }
        var allowed = [host.lowercased()]; if provider == .github { allowed += ["github.com", "gist.github.com"]; if asset { allowed += ["objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"] } }
        return allowed.contains(h) ? u : nil
    }
    /// Profile photos are fetched without account credentials, only from the connected host or known avatar CDNs.
    static func safeAvatarURL(provider: Provider, host: String, _ value: String) -> URL? {
        guard let u = URL(string: value), u.scheme == "https", u.user == nil, u.password == nil,
              let avatarHost = u.host?.lowercased() else { return nil }
        let allowed = [host.lowercased(), "gravatar.com", "www.gravatar.com", "secure.gravatar.com"]
            + (provider == .github ? ["avatars.githubusercontent.com", "github.com"] : [])
        return allowed.contains(avatarHost) ? u : nil
    }
    static func avatarURL(_ c: HubAccess, _ value: String) -> URL? {
        let server = c.target.provider == .gitlab && c.apiBase.hasSuffix("/api/v4") ? String(c.apiBase.dropLast("/api/v4".count)) : "https://" + c.target.host
        let resolved = value.hasPrefix("/") && !value.hasPrefix("//") ? URL(string: value, relativeTo: URL(string: server))?.absoluteURL.absoluteString ?? "" : value
        return safeAvatarURL(provider: c.target.provider, host: c.target.host, resolved)
    }
    static func member(_ c: HubAccess, _ x: J) -> HubMember {
        let username = s(x, c.target.provider == .github ? "login" : "username").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = s(x, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        let server = c.target.provider == .gitlab && c.apiBase.hasSuffix("/api/v4") ? String(c.apiBase.dropLast("/api/v4".count)) : "https://" + c.target.host
        let rawProfile = s(x, c.target.provider == .github ? "html_url" : "web_url")
        let profile = safeURL(c, rawProfile) ?? (username.isEmpty ? nil : safeURL(c, server + "/" + enc(username)))
        let role: String
        if c.target.provider == .gitlab {
            switch Int(id(x, "access_level")) {
            case 5: role = String(localized: "Minimal access")
            case 10: role = String(localized: "Guest")
            case 15: role = String(localized: "Planner")
            case 20: role = String(localized: "Reporter")
            case 30: role = String(localized: "Developer")
            case 40: role = String(localized: "Maintainer")
            case 50: role = String(localized: "Owner")
            default: role = String(localized: "Member")
            }
        } else { role = String(localized: "Member") }
        return HubMember(id: id(x).isEmpty ? username : id(x), name: name.isEmpty ? username : name, role: role, username: username,
                         avatarURL: avatarURL(c, s(x, "avatar_url")), profileURL: profile)
    }
    static func members(_ c: HubAccess, rows: [J]) async throws -> [HubMember] {
        var result = rows.map { member(c, $0) }
        guard c.target.provider == .github, !result.isEmpty else { return result }
        // REST organization members omit display names. Enrich the page in one optional public-profile lookup.
        let indices = result.indices.filter { !result[$0].username.isEmpty }.prefix(30)
        guard !indices.isEmpty else { return result }
        let definitions = indices.map { "$login\($0):String!" }.joined(separator: ",")
        let fields = indices.map { "member\($0):user(login:$login\($0)){name avatarUrl url}" }.joined(separator: " ")
        let variables = Dictionary(uniqueKeysWithValues: indices.map { ("login\($0)", result[$0].username) })
        do {
            let response = try await object(c, c.apiBase + "/graphql", method: "POST", body: ["query": "query(\(definitions)){\(fields)}", "variables": variables])
            let profiles = obj(response, "data")
            for index in indices {
                let profile = obj(profiles, "member\(index)"), name = s(profile, "name").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { result[index].name = name }
                if let avatar = safeAvatarURL(provider: c.target.provider, host: c.target.host, s(profile, "avatarUrl")) { result[index].avatarURL = avatar }
                if let url = safeURL(c, s(profile, "url")) { result[index].profileURL = url }
            }
        } catch { try check(c) } // An unavailable profile must not hide the organization's members.
        return result
    }
    static func error(_ e: Error, token: String? = nil) -> String { var text = e.localizedDescription; if let token, !token.isEmpty { text = text.replacingOccurrences(of: token, with: "[redacted]") }; for pattern in ["\\b(?:gh[pousr]_[\\w]+|github_pat_[\\w]+|glpat-[\\w-]+)\\b", "(?i)[?&](?:access_token|private_token|token|api_key)=[^&\\s]+"] { if let regex = try? NSRegularExpression(pattern: pattern) { text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]") } }; return String(text.prefix(1200)) }
    static func projectTarget(_ repository: RepoTarget?, provider: Provider, host: String, username: String, personal: Bool) -> RepoTarget {
        if !personal, let repository { return repository }
        return RepoTarget(provider: provider, remote: "origin", host: host, path: username + "/workspace")
    }
    static func projectColumns(_ detail: HubDetail, fieldID: String? = nil) -> [HubProjectColumn] {
        let fields = detail.fields.filter { !$0.options.isEmpty }
        guard let field = fields.first(where: { $0.id == fieldID }) ?? fields.first(where: { ["status", "상태"].contains($0.name.lowercased()) }) ?? fields.first else { return [HubProjectColumn(id: "", title: String(localized: "Not set"), rows: detail.rows)] }
        let options = Set(field.options.map(\.id)), unset = detail.rows.filter { !options.contains(($0.values[field.id] ?? $0.statuses[field.id]) ?? "") }
        return (unset.isEmpty ? [] : [HubProjectColumn(id: "", title: String(localized: "Not set"), rows: unset)]) + field.options.map { option in HubProjectColumn(id: option.id, title: option.name, rows: detail.rows.filter { ($0.values[field.id] ?? $0.statuses[field.id]) == option.id }) }
    }
    static func releaseItem(_ p: Provider, _ x: J) -> HubItem {
        let tag = s(x, "tag_name"), name = s(x, "name"), draft = x["draft"] as? Bool == true, prerelease = x["prerelease"] as? Bool == true
        return HubItem(id: p == .github ? id(x) : tag, title: name.isEmpty ? tag : name, subtitle: tag + (draft ? " · draft" : "") + (prerelease ? " · prerelease" : ""), body: s(x, p == .github ? "body" : "description"), url: p == .github ? s(x, "html_url") : s(obj(x, "_links"), "self"), data: x)
    }
    static func gistItem(_ c: HubAccess, _ x: J) -> HubItem { let p = c.target.provider, description = s(x, "description"), title = s(x, "title"), owner = p == .github ? s(obj(x, "owner"), "login") : s(obj(x, "author"), "username"); return HubItem(id: id(x), title: !description.isEmpty ? description : !title.isEmpty ? title : obj(x, "files").keys.sorted().first ?? id(x), subtitle: (p == .github ? x["public"] as? Bool == true ? "public" : "secret" : s(x, "visibility")) + " · " + owner, body: description, url: s(x, p == .github ? "html_url" : "web_url"), editable: owner == c.me, data: x) }
    static func organizationItem(_ c: HubAccess, _ x: J) -> HubItem {
        let github = c.target.provider == .github, login = s(x, "login"), name = s(x, "name")
        let url = s(x, github ? "html_url" : "web_url")
        return HubItem(id: github ? login : id(x), title: name.isEmpty ? github ? login : s(x, "full_name") : name,
                       subtitle: github ? login : s(x, "full_path"), body: s(x, "description"),
                       url: github && url.isEmpty ? "https://" + c.target.host + "/" + enc(login) : url,
                       data: x, avatarURL: avatarURL(c, s(x, "avatar_url")))
    }
    static let projectFields = "id number title shortDescription url closed updatedAt"
    // Windows: projectDetailQuery uses the same fields and bounded connections.
    static let projectDetailQuery = """
    query($id:ID!,$cursor:String){node(id:$id){... on ProjectV2{
      id title shortDescription readme url closed public updatedAt
      fields(first:100){nodes{
        ... on ProjectV2FieldCommon{id name dataType}
        ... on ProjectV2SingleSelectField{id name options{id name}}
        ... on ProjectV2IterationField{id name configuration{iterations{id title startDate duration} completedIterations{id title startDate duration}}}
      } pageInfo{hasNextPage}}
      items(first:30,after:$cursor,archivedStates:[ARCHIVED,NOT_ARCHIVED]){nodes{id type isArchived updatedAt content{__typename
        ... on Issue{id title body url number state createdAt author{login} updatedAt repository{nameWithOwner} assignees(first:100){nodes{login}} labels(first:100){nodes{name}}}
        ... on PullRequest{id title body url number state createdAt author{login} updatedAt headRefName repository{nameWithOwner} assignees(first:100){nodes{login}} labels(first:100){nodes{name}}}
        ... on DraftIssue{id title body createdAt creator{login} updatedAt assignees(first:100){nodes{login}}}
      } fieldValues(first:100){nodes{
        ... on ProjectV2ItemFieldSingleSelectValue{optionId field{... on ProjectV2SingleSelectField{id}}}
        ... on ProjectV2ItemFieldTextValue{text field{... on ProjectV2Field{id}}}
        ... on ProjectV2ItemFieldNumberValue{number field{... on ProjectV2Field{id}}}
        ... on ProjectV2ItemFieldDateValue{date field{... on ProjectV2Field{id}}}
        ... on ProjectV2ItemFieldIterationValue{iterationId field{... on ProjectV2IterationField{id}}}
      } pageInfo{hasNextPage}}} pageInfo{hasNextPage endCursor}}
    }}}
    """
    static func projectField(_ x: J) -> HubProjectField {
        if x["options"] is [J] { return HubProjectField(id: id(x), name: s(x, "name"), options: arr(x, "options").map { HubProjectOption(id: id($0), name: s($0, "name")) }) }
        if x["configuration"] != nil { let configuration = obj(x, "configuration"); return HubProjectField(id: id(x), name: s(x, "name"), options: (arr(configuration, "iterations") + arr(configuration, "completedIterations")).map { HubProjectOption(id: id($0), name: s($0, "title"), startDate: s($0, "startDate"), duration: $0["duration"] as? Int) }, kind: .iteration) }
        let kind: HubProjectFieldKind = s(x, "dataType") == "TEXT" ? .text : s(x, "dataType") == "NUMBER" ? .number : s(x, "dataType") == "DATE" ? .date : .unsupported
        return HubProjectField(id: id(x), name: s(x, "name"), options: [], kind: kind)
    }
    static func projectRow(_ x: J) -> HubProjectRow {
        let content = obj(x, "content"); var values: [String: String] = [:], statuses: [String: String] = [:]
        for field in arr(obj(x, "fieldValues"), "nodes") {
            let fieldID = id(obj(field, "field")); guard !fieldID.isEmpty else { continue }
            for key in ["optionId", "iterationId", "text", "number", "date"] where field[key] != nil && !(field[key] is NSNull) { values[fieldID] = id(field, key); break }
            if let option = field["optionId"] as? String { statuses[fieldID] = option }
        }
        let type = s(content, "__typename"), kind: HubProjectRowKind = type == "PullRequest" ? .pullRequest : type == "DraftIssue" ? .draft : type == "Issue" ? .issue : s(x, "type") == "DRAFT_ISSUE" ? .draft : s(x, "type") == "PULL_REQUEST" ? .pullRequest : !id(content).isEmpty ? .issue : .redacted
        return HubProjectRow(id: id(x), title: s(content, "title").isEmpty ? String(localized: "Redacted project item") : s(content, "title"), body: s(content, "body"), url: s(content, "url"), contentID: id(content), statuses: statuses, labels: arr(obj(content, "labels"), "nodes").map { s($0, "name") }, kind: kind, number: content["number"] as? Int, repository: s(obj(content, "repository"), "nameWithOwner"), state: s(content, "state"), assignees: arr(obj(content, "assignees"), "nodes").map { s($0, "login") }, updatedAt: s(x, "updatedAt").isEmpty ? s(content, "updatedAt") : s(x, "updatedAt"), headRefName: s(content, "headRefName"), archived: x["isArchived"] as? Bool == true, values: values, author: (obj(content, kind == .draft ? "creator" : "author")["login"] as? String).flatMap { $0.isEmpty ? nil : $0 }, createdAt: (content["createdAt"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
    static func page(_ c: HubAccess, section: HostingHubSection, page: Int = 1, cursor: String? = nil) async throws -> HubPage {
        if c.local { try check(c); guard section == .projects else { throw fail(String(localized: "This action requires a GitHub project.")) }; await localProjectStore.load(); try check(c); if let error = localProjectStore.error { throw fail(error) }; return HubPage(items: localProjectStore.projects, more: false, notice: String(localized: "Saved on this device. Local projects do not sync with GitHub.")) }
        let p = c.target.provider, query = "per_page=30&page=\(max(1, page))"
        switch section {
        case .releases:
            let rows = try await list(c, repo(c) + "/releases?" + query)
            return HubPage(items: rows.map { releaseItem(p, $0) }, more: rows.count == 30, notice: p == .gitlab ? String(localized: "GitLab releases are published immediately; GitHub-style drafts and prereleases are unavailable.") : nil)
        case .organizations:
            let rows = try await list(c, c.apiBase + (p == .github ? "/user/orgs?" : "/groups?all_available=false&") + query)
            return HubPage(items: rows.map { organizationItem(c, $0) }, more: rows.count == 30)
        case .gists:
            let rows = try await list(c, c.apiBase + (p == .github ? "/gists?" : "/snippets?") + query)
            return HubPage(items: rows.map { gistItem(c, $0) }, more: rows.count == 30, notice: p == .gitlab ? String(localized: "GitLab personal snippets correspond to gists. Stars are not supported by its snippets API.") : nil)
        case .projects:
            if p == .gitlab { guard !c.target.path.hasSuffix("/workspace") else { throw fail(String(localized: "Open a GitLab repository to browse its issue boards.")) }; let rows = try await list(c, repo(c) + "/boards"); return HubPage(items: Array(rows.dropFirst((page - 1) * 30).prefix(30)).map { HubItem(id: id($0), title: s($0, "name"), subtitle: String(localized: "GitLab issue board"), url: "https://\(c.target.host)/\(c.target.path)/-/boards/\(id($0))", data: $0) }, more: rows.count > page * 30) }
            let parts = c.target.path.split(separator: "/").map(String.init), owner = parts.first ?? c.me, name = parts.last ?? "workspace", noRepo = name == "workspace"
            let connection = "projectsV2(first:30,after:$cursor){nodes{\(projectFields)} pageInfo{hasNextPage endCursor}}"
            let query = noRepo ? "query($owner:String!,$cursor:String){user(login:$owner){\(connection)}}" : "query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){owner{... on User{\(connection)} ... on Organization{\(connection)}}}}"
            var variables: J = ["owner": owner, "cursor": cursor as Any? ?? NSNull()]; if !noRepo { variables["name"] = name }
            let data = try await graph(c, query, variables), connectionData = obj(noRepo ? obj(data, "user") : obj(obj(data, "repository"), "owner"), "projectsV2")
            guard !connectionData.isEmpty else { throw fail(String(localized: "Projects are unavailable for this repository owner.")) }
            return HubPage(items: arr(connectionData, "nodes").map { HubItem(id: id($0), title: s($0, "title"), subtitle: "#\(id($0, "number"))" + ($0["closed"] as? Bool == true ? " · closed" : ""), body: s($0, "shortDescription"), url: s($0, "url"), data: $0) }, more: obj(connectionData, "pageInfo")["hasNextPage"] as? Bool == true, cursor: obj(connectionData, "pageInfo")["endCursor"] as? String, notice: String(localized: "Projects sync with GitHub. Changes are saved after confirmation."))
        }
    }
    static func detail(_ c: HubAccess, section: HostingHubSection, item: HubItem, page: Int = 1, cursor: String? = nil, tab: String = "repositories") async throws -> HubDetail {
        if try usesLocal(c, item: item) { guard section == .projects else { throw fail(String(localized: "This action requires a GitHub project.")) }; let result = try await localProjectStore.detail(projectID: item.id); try check(c); return result }
        let p = c.target.provider, qs = "per_page=30&page=\(page)"
        switch section {
        case .releases:
            let x = try await object(c, repo(c) + "/releases/" + enc(item.id)); var d = HubDetail(item: releaseItem(p, x))
            if p == .github { d.assets = arr(x, "assets").map { HubAsset(id: id($0), name: s($0, "name"), size: $0["size"] as? Int, downloads: $0["download_count"] as? Int, url: s($0, "browser_download_url")) } }
            else { let assets = obj(x, "assets"); d.assets = arr(assets, "links").map { HubAsset(id: id($0), name: s($0, "name"), url: s($0, "direct_asset_url").isEmpty ? s($0, "url") : s($0, "direct_asset_url")) } + arr(assets, "sources").map { HubAsset(id: s($0, "format"), name: s($0, "format"), url: s($0, "url")) } }; return d
        case .organizations:
            let base = c.apiBase + (p == .github ? "/orgs/" : "/groups/") + enc(item.id), x = try await object(c, base)
            var updated = organizationItem(c, x)
            if updated.id.isEmpty { updated.id = item.id }
            if s(x, "name").isEmpty { updated.title = item.title }
            if updated.subtitle.isEmpty { updated.subtitle = item.subtitle }
            if s(x, p == .github ? "html_url" : "web_url").isEmpty { updated.url = item.url }
            if x["avatar_url"] == nil { updated.avatarURL = item.avatarURL }
            var d = HubDetail(item: updated)
            let route = tab == "members" ? p == .github ? "/members" : "/members/all" : p == .github ? "/repos" : "/projects"
            let extra = tab == "repositories" ? p == .github ? "&sort=updated" : "&include_subgroups=true&order_by=last_activity_at" : ""
            let rows = try await list(c, base + route + "?" + qs + extra)
            if tab == "members" { d.members = try await members(c, rows: rows); if p == .github { d.notice = String(localized: "Only members visible to this account are returned by the server.") } }
            else { d.repositories = rows.map { HubRepository(id: id($0), name: s($0, p == .github ? "full_name" : "path_with_namespace"), description: s($0, "description"), cloneURL: s($0, p == .github ? "clone_url" : "http_url_to_repo"), url: s($0, p == .github ? "html_url" : "web_url")) } }; d.more = rows.count == 30; return d
        case .gists:
            let base = c.apiBase + (p == .github ? "/gists/" : "/snippets/") + enc(item.id), x = try await object(c, base); var d = HubDetail(item: gistItem(c, x))
            if p == .github { d.files = obj(x, "files").sorted { $0.key < $1.key }.map { key, value in let f = value as? J ?? [:]; return HubFile(name: key, content: s(f, "content"), truncated: f["truncated"] as? Bool == true) }; do { _ = try await value(c, base + "/star"); d.starred = true } catch let error as HostingError where error.status == 404 { d.starred = false } catch { d.notice = String(localized: "Star status could not be loaded: \(Self.error(error, token: c.token))") }; if x["truncated"] as? Bool == true { d.notice = String(localized: "The server truncated the file list. Open the gist in a browser before editing.") } }
            else { let files = arr(x, "files").isEmpty ? [["path": s(x, "file_name")]] : arr(x, "files"); for f in files.prefix(30) { let name = s(f, "path"), branch = snippetRef(rawURL: s(f, "raw_url"), file: name) ?? "main"; try check(c); let data = try await Hosting.data(Hosting.request(p, base + "/files/\(enc(branch))/\(enc(name))/raw", token: c.token)); try check(c); d.files.append(HubFile(name: name, content: String(decoding: data.prefix(1_000_000), as: UTF8.self), truncated: data.count > 1_000_000)) }; if files.count > 30 { d.notice = String(localized: "The server returned more files. Open the snippet in a browser before editing.") } }; return d
        case .projects:
            if p == .gitlab { let board = try await object(c, repo(c) + "/boards/" + enc(item.id)), lists = try await list(c, repo(c) + "/boards/" + enc(item.id) + "/lists?per_page=100"), labels = lists.compactMap { x -> HubProjectOption? in guard let label = x["label"] as? J else { return nil }; return HubProjectOption(id: id(label), name: s(label, "name")) }, issues = try await list(c, repo(c) + "/issues?" + boardIssueQuery(board, page: page)); var updated = item; updated.title = s(board, "name"); updated.data = board; var d = HubDetail(item: updated); d.fields = [HubProjectField(id: "board", name: String(localized: "Board column"), options: [HubProjectOption(id: "__open", name: String(localized: "Open"))] + labels + [HubProjectOption(id: "__closed", name: String(localized: "Closed"))])]; d.rows = issues.map { x in let names = x["labels"] as? [String] ?? []; return HubProjectRow(id: id(x, "iid"), title: s(x, "title"), body: s(x, "description"), url: s(x, "web_url"), contentID: id(x), statuses: ["board": s(x, "state") == "closed" ? "__closed" : labels.first { names.contains($0.name) }?.id ?? "__open"], labels: names, number: x["iid"] as? Int, repository: c.target.path, state: s(x, "state") == "closed" ? "CLOSED" : "OPEN", assignees: arr(x, "assignees").map { s($0, "username") }, updatedAt: s(x, "updated_at"), author: obj(x, "author")["username"] as? String, createdAt: x["created_at"] as? String) }; d.more = issues.count == 30; d.notice = String(localized: "GitLab board scope filters are applied. Only label columns can be moved here; assignee, milestone, iteration and custom status columns remain available in the browser. Moving to Open reopens the issue and removes its board column labels."); return d }
            let data = try await graph(c, projectDetailQuery, ["id": item.id, "cursor": cursor as Any? ?? NSNull()]), x = obj(data, "node")
            guard !id(x).isEmpty else { throw fail(String(localized: "Project is unavailable or this account cannot access it.")) }
            var updated = item; updated.title = s(x, "title"); updated.body = s(x, "shortDescription"); updated.url = s(x, "url"); updated.data.merge(x) { _, new in new }; var d = HubDetail(item: updated)
            d.fields = arr(obj(x, "fields"), "nodes").filter { !id($0).isEmpty }.map(projectField)
            d.rows = arr(obj(x, "items"), "nodes").map(projectRow)
            d.more = obj(obj(x, "items"), "pageInfo")["hasNextPage"] as? Bool == true; d.cursor = obj(obj(x, "items"), "pageInfo")["endCursor"] as? String
            if obj(obj(x, "fields"), "pageInfo")["hasNextPage"] as? Bool == true || arr(obj(x, "items"), "nodes").contains(where: { obj(obj($0, "fieldValues"), "pageInfo")["hasNextPage"] as? Bool == true }) { d.notice = String(localized: "Some project fields were truncated by the server. Only loaded fields can be edited.") }; return d
        }
    }
    static func snippetRef(rawURL: String, file: String) -> String? { guard let u = URL(string: rawURL), let range = u.path.range(of: "/raw/"), u.path.hasSuffix("/" + file) else { return nil }; let value = String(u.path[range.upperBound...].dropLast(file.count + 1)); return value.isEmpty ? nil : value }
    static func saveRelease(_ c: HubAccess, _ input: HubReleaseInput, previous: HubItem? = nil) async throws {
        guard !input.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(String(localized: "A tag and release name are required.")) }
        guard c.target.provider == .github || !input.draft && !input.prerelease else { throw fail(String(localized: "GitLab releases are published immediately; GitHub-style drafts and prereleases are unavailable.")) }
        if let previous { guard input.tag == s(previous.data, "tag_name") else { throw fail(String(localized: "The existing release tag cannot be changed here.")) }; let fresh = try await detail(c, section: .releases, item: previous); guard s(fresh.item.data, "updated_at") == s(previous.data, "updated_at"), fresh.item.body == previous.body, fresh.item.title == previous.title else { throw fail(String(localized: "This item changed on the server. Refresh before saving.")) } }
        let github = c.target.provider == .github; var body: J = ["tag_name": input.tag, "name": input.name, github ? "body" : "description": input.body]
        if github { body["draft"] = input.draft; body["prerelease"] = input.prerelease; if !input.target.isEmpty { body["target_commitish"] = input.target } } else if previous == nil && !input.target.isEmpty { body["ref"] = input.target }
        if let previous { _ = try await value(c, repo(c) + "/releases/" + enc(previous.id), method: github ? "PATCH" : "PUT", body: body) } else { try await create(c, repo(c) + "/releases", body: body) }
    }
    static func delete(_ c: HubAccess, section: HostingHubSection, item: HubItem) async throws { guard section == .releases || section == .gists else { return }; let fresh = try await detail(c, section: section, item: item); guard section != .gists || fresh.item.editable else { throw fail(String(localized: "Only items owned by this account can be deleted.")) }; guard s(fresh.item.data, "updated_at") == s(item.data, "updated_at"), fresh.item.title == item.title, fresh.item.body == item.body else { throw fail(String(localized: "This item changed on the server. Refresh before saving.")) }; _ = try await value(c, section == .releases ? repo(c) + "/releases/" + enc(item.id) : c.apiBase + (c.target.provider == .github ? "/gists/" : "/snippets/") + enc(item.id), method: "DELETE") }
    static func saveGist(_ c: HubAccess, _ input: HubGistInput, previous: HubDetail? = nil) async throws {
        guard !input.files.isEmpty, input.files.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(input.files.map(\.name)).count == input.files.count else { throw fail(String(localized: "Each file needs a unique name and content.")) }
        if let previous { guard previous.item.editable, !previous.files.contains(where: \.truncated), previous.item.data["truncated"] as? Bool != true else { throw fail(String(localized: "Only complete files owned by this account can be edited.")) }; let fresh = try await detail(c, section: .gists, item: previous.item); guard s(fresh.item.data, "updated_at") == s(previous.item.data, "updated_at"), fresh.files.map({ $0.name + "\0" + $0.content }) == previous.files.map({ $0.name + "\0" + $0.content }) else { throw fail(String(localized: "This item changed on the server. Refresh before saving.")) } }
        let github = c.target.provider == .github; var body: J = ["description": input.description]
        if github { var files: J = [:]; for f in input.files { files[f.name] = ["content": f.content] }; if let previous { for f in previous.files where !input.files.contains(where: { $0.name == f.name }) { files[f.name] = NSNull() } }; body["files"] = files; if previous == nil { body["public"] = input.isPublic } }
        else { body["title"] = input.description.isEmpty ? input.files[0].name : input.description; var files: [J] = input.files.map { f in var x: J = ["file_path": f.name, "content": f.content]; if let previous { x["action"] = previous.files.contains(where: { $0.name == f.name }) ? "update" : "create" }; return x }; if let previous { for f in previous.files where !input.files.contains(where: { $0.name == f.name }) { files.append(["file_path": f.name, "action": "delete"]) } }; body["files"] = files; if previous == nil { body["visibility"] = input.isPublic ? "public" : "private" } }
        let base = c.apiBase + (github ? "/gists" : "/snippets"); if let previous { _ = try await value(c, base + "/" + enc(previous.item.id), method: github ? "PATCH" : "PUT", body: body) } else { try await create(c, base, body: body) }
    }
    static func star(_ c: HubAccess, item: HubItem, starred: Bool) async throws { guard c.target.provider == .github else { throw fail(String(localized: "GitLab snippets do not support stars.")) }; _ = try await value(c, c.apiBase + "/gists/" + enc(item.id) + "/star", method: starred ? "PUT" : "DELETE") }
    static func loadedProjectRow(_ detail: HubDetail, row: HubProjectRow) throws -> HubProjectRow {
        guard !detail.item.id.isEmpty, let loaded = detail.rows.first(where: { $0.id == row.id }) else { throw fail(String(localized: "Select a loaded project field and item.")) }; return loaded
    }
    static func githubProject(_ c: HubAccess, detail: HubDetail) throws { try check(c); guard try !usesLocal(c, item: detail.item), c.target.provider == .github, !detail.item.id.isEmpty else { throw fail(String(localized: "This action requires a GitHub project.")) } }
    static func updateProjectField(_ c: HubAccess, detail: HubDetail, row: HubProjectRow, field: HubProjectField, value: String?) async throws {
        if try usesLocal(c, item: detail.item) { _ = try await localProjectStore.updateField(detail: detail, row: row, field: field, value: value); try check(c); return }
        try githubProject(c, detail: detail); let loaded = try loadedProjectRow(detail, row: row)
        guard let actual = detail.fields.first(where: { $0.id == field.id }) else { throw fail(String(localized: "Select a loaded project field and item.")) }
        guard actual.kind != .unsupported else { throw fail(String(localized: "This project field is managed by its issue or pull request.")) }
        var input: J = ["projectId": detail.item.id, "itemId": loaded.id, "fieldId": actual.id]
        guard let value else { _ = try await graph(c, "mutation($input:ClearProjectV2ItemFieldValueInput!){clearProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}", ["input": input]); return }
        let fieldValue: J
        switch actual.kind {
        case .singleSelect, .iteration:
            guard actual.options.contains(where: { $0.id == value }) else { throw fail(String(localized: "Select a loaded project field and item.")) }; fieldValue = [actual.kind == .iteration ? "iterationId" : "singleSelectOptionId": value]
        case .number:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil, let number = Double(trimmed), number.isFinite else { throw fail(String(localized: "Enter a valid number.")) }; fieldValue = ["number": number]
        case .date:
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil, let date = formatter.date(from: value), formatter.string(from: date) == value else { throw fail(String(localized: "Enter a date as YYYY-MM-DD.")) }; fieldValue = ["date": value]
        case .text: fieldValue = ["text": value]
        case .unsupported: throw fail(String(localized: "This project field is managed by its issue or pull request."))
        }
        input["value"] = fieldValue
        _ = try await graph(c, "mutation($input:UpdateProjectV2ItemFieldValueInput!){updateProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}", ["input": input])
    }
    static func saveProjectDraft(_ c: HubAccess, detail: HubDetail, title: String, body: String, row: HubProjectRow? = nil) async throws {
        if try usesLocal(c, item: detail.item) { _ = try await localProjectStore.saveDraft(detail: detail, title: title, body: body, row: row); try check(c); return }
        try githubProject(c, detail: detail); let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw fail(String(localized: "A draft title is required.")) }
        if let row {
            let loaded = try loadedProjectRow(detail, row: row)
            guard loaded.kind == .draft, !loaded.contentID.isEmpty else { throw fail(String(localized: "Select a loaded draft item.")) }
            let data = try await graph(c, "query($id:ID!){node(id:$id){... on DraftIssue{id title body}}}", ["id": loaded.contentID]), fresh = obj(data, "node")
            guard id(fresh) == loaded.contentID, s(fresh, "title") == loaded.title, s(fresh, "body") == loaded.body else { throw fail(String(localized: "This item changed on the server. Refresh before saving.")) }
            _ = try await graph(c, "mutation($input:UpdateProjectV2DraftIssueInput!){updateProjectV2DraftIssue(input:$input){draftIssue{id}}}", ["input": ["draftIssueId": loaded.contentID, "title": title, "body": body]])
        }
        else {
            do { _ = try await graph(c, "mutation($input:AddProjectV2DraftIssueInput!){addProjectV2DraftIssue(input:$input){projectItem{id}}}", ["input": ["projectId": detail.item.id, "title": title, "body": body]]) }
            catch let error as HostingError where (400..<500).contains(error.status) { throw error }
            catch let error as HubProjectPermissionError { throw error }
            catch let error as HubProjectActionDeniedError { throw error }
            catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
        }
    }
    static func archiveProjectItem(_ c: HubAccess, detail: HubDetail, row: HubProjectRow, archived: Bool) async throws {
        if try usesLocal(c, item: detail.item) { _ = try await localProjectStore.archive(detail: detail, row: row, archived: archived); try check(c); return }
        try githubProject(c, detail: detail); let loaded = try loadedProjectRow(detail, row: row), operation = archived ? "archiveProjectV2Item" : "unarchiveProjectV2Item", inputType = archived ? "ArchiveProjectV2ItemInput" : "UnarchiveProjectV2ItemInput"
        _ = try await graph(c, "mutation($input:\(inputType)!){\(operation)(input:$input){item{id}}}", ["input": ["projectId": detail.item.id, "itemId": loaded.id]])
    }
    static func deleteProjectItem(_ c: HubAccess, detail: HubDetail, row: HubProjectRow) async throws {
        if try usesLocal(c, item: detail.item) { _ = try await localProjectStore.removeItem(detail: detail, row: row); try check(c); return }
        try githubProject(c, detail: detail); let loaded = try loadedProjectRow(detail, row: row)
        _ = try await graph(c, "mutation($input:DeleteProjectV2ItemInput!){deleteProjectV2Item(input:$input){deletedItemId}}", ["input": ["projectId": detail.item.id, "itemId": loaded.id]])
    }
    static func moveProjectItem(_ c: HubAccess, detail: HubDetail, row: HubProjectRow, afterRow: HubProjectRow?) async throws {
        if try usesLocal(c, item: detail.item) { _ = try await localProjectStore.reorder(detail: detail, row: row, afterRow: afterRow); try check(c); return }
        try githubProject(c, detail: detail); let loaded = try loadedProjectRow(detail, row: row)
        let anchor = try afterRow.map { try loadedProjectRow(detail, row: $0) }
        guard anchor?.id != loaded.id else { throw fail(String(localized: "Select a loaded project field and item.")) }
        _ = try await graph(c, "mutation($input:UpdateProjectV2ItemPositionInput!){updateProjectV2ItemPosition(input:$input){items{nodes{id}}}}", ["input": ["projectId": detail.item.id, "itemId": loaded.id, "afterId": anchor?.id as Any? ?? NSNull()]])
    }
    static func convertProjectDraftToIssue(_ c: HubAccess, detail: HubDetail, row: HubProjectRow, repository: String) async throws {
        try githubProject(c, detail: detail); let loaded = try loadedProjectRow(detail, row: row)
        guard loaded.kind == .draft, !loaded.contentID.isEmpty else { throw fail(String(localized: "Select a loaded draft item.")) }
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines), parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { throw fail(String(localized: "Enter a repository as owner/name on the connected server.")) }
        let data = try await graph(c, "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id nameWithOwner}}", ["owner": parts[0], "name": parts[1]]), remote = obj(data, "repository")
        guard !id(remote).isEmpty, s(remote, "nameWithOwner").caseInsensitiveCompare(repository) == .orderedSame else { throw fail(String(localized: "Repository is unavailable or this account cannot access it.")) }
        do { _ = try await graph(c, "mutation($input:ConvertProjectV2DraftIssueItemToIssueInput!){convertProjectV2DraftIssueItemToIssue(input:$input){item{id}}}", ["input": ["itemId": loaded.id, "repositoryId": id(remote)]]) }
        catch let error as HostingError where (400..<500).contains(error.status) { throw error }
        catch let error as HubProjectPermissionError { throw error }
            catch let error as HubProjectActionDeniedError { throw error }
        catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
    }
    static func move(_ c: HubAccess, detail: HubDetail, row: HubProjectRow, field: HubProjectField, option: String) async throws {
        if c.target.provider == .github { try await updateProjectField(c, detail: detail, row: row, field: field, value: option); return }
        let loaded = try loadedProjectRow(detail, row: row)
        guard let actual = detail.fields.first(where: { $0.id == field.id }), actual.options.contains(where: { $0.id == option }) else { throw fail(String(localized: "Select a loaded project field and item.")) }
        let fresh = try await object(c, repo(c) + "/issues/" + enc(loaded.id)), labels = fresh["labels"] as? [String] ?? [], boardLabels = actual.options.filter { !$0.id.hasPrefix("__") }.map(\.name), selectedLabel = actual.options.first(where: { $0.id == option && !$0.id.hasPrefix("__") })?.name
        var body: J = ["remove_labels": labels.filter { boardLabels.contains($0) && $0 != selectedLabel }.joined(separator: ","), "state_event": option == "__closed" ? "close" : "reopen"]
        if let selectedLabel { body["add_labels"] = selectedLabel }; _ = try await value(c, repo(c) + "/issues/" + enc(loaded.id), method: "PUT", body: body)
    }
    static func addIssue(_ c: HubAccess, detail: HubDetail, issueURL: String) async throws {
        guard let url = safeURL(c, issueURL), url.host?.lowercased() == c.target.host.lowercased() else { throw fail(String(localized: "Enter an issue URL from the connected server.")) }
        let parts = url.path.split(separator: "/").map(String.init)
        if c.target.provider == .github {
            try githubProject(c, detail: detail)
            guard parts.count == 4, ["issues", "pull"].contains(parts[2]), let number = Int(parts[3]), number > 0 else { throw fail(String(localized: "Enter a full issue or pull request URL.")) }
            let isPR = parts[2] == "pull", issue = try await object(c, c.apiBase + "/repos/\(enc(parts[0]))/\(enc(parts[1]))/\(isPR ? "pulls" : "issues")/\(number)")
            guard !s(issue, "node_id").isEmpty, isPR || issue["pull_request"] == nil else { throw fail(String(localized: "Select an issue or pull request from this server.")) }
            _ = try await graph(c, "mutation($input:AddProjectV2ItemByIdInput!){addProjectV2ItemById(input:$input){item{id}}}", ["input": ["projectId": detail.item.id, "contentId": s(issue, "node_id")]])
        } else {
            guard let split = url.path.range(of: "/-/issues/"), String(url.path[..<split.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == c.target.path, let number = Int(url.path[split.upperBound...]), number > 0, let field = detail.fields.first else { throw fail(String(localized: "Select an issue from this board's repository.")) }
            let issue = try await object(c, repo(c) + "/issues/\(number)"), row = HubProjectRow(id: id(issue, "iid"), title: s(issue, "title"), body: "", url: issueURL, contentID: id(issue), statuses: [:]); var copy = detail; copy.rows.append(row); try await move(c, detail: copy, row: row, field: field, option: "__open")
        }
    }
}
