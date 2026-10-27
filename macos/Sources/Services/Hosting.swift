import Foundation

struct HostingError: LocalizedError {
    let status: Int
    let message: String

    init(status: Int, body: Data) {
        self.status = status
        var msg = String(decoding: body.prefix(400), as: UTF8.self)
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let m = obj["message"] as? String {
                msg = m
                if let errors = obj["errors"] as? [[String: Any]] {
                    let details = errors.compactMap { $0["message"] as? String ?? $0["code"] as? String }
                    if !details.isEmpty { msg += " — " + details.joined(separator: ", ") }
                }
            } else if let m = obj["message"], let data = try? JSONSerialization.data(withJSONObject: m) {
                msg = String(decoding: data, as: UTF8.self)        // GitLab: 배열·객체 메시지
            } else if let e = obj["error_description"] as? String ?? obj["error"] as? String {
                msg = e
            }
        }
        message = msg
    }

    var errorDescription: String? {
        switch status {
        case 401: return String(localized: "Authentication failed (401). The token expired or is wrong. Reconnect the account in Settings.")
        case 403: return String(localized: "No permission (403): \(message)")
        case 404: return String(localized: "Not found (404). Check that the token has access to the repository.")
        default: return String(localized: "Server error \(status): \(message)")
        }
    }
}

/// GitHub REST API / GitLab REST API v4 클라이언트
enum Hosting {
    // MARK: 원격 URL → 호스팅 저장소

    struct ParsedRemote { let host: String; let path: String }

    /// https://host/a/b(.git), git@host:a/b(.git), ssh://git@host/a/b.git
    static func parseRemote(_ s: String) -> ParsedRemote? {
        var host = "", path = ""
        if s.contains("://") {
            guard let c = URLComponents(string: s), let h = c.host else { return nil }
            host = h
            path = c.path
        } else if let colon = s.firstIndex(of: ":") {
            let before = s[..<colon]
            host = String(before.split(separator: "@").last ?? before)
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, path.contains("/") else { return nil }
        return ParsedRemote(host: host.lowercased(), path: path)
    }

    static func target(remotes: [String], urls: [String: String], gitlabHosts: [String], sshAliases: [String: String] = [:]) -> RepoTarget? {
        let order = remotes.contains("origin") ? ["origin"] + remotes.filter { $0 != "origin" } : remotes
        for name in order {
            guard let u = urls[name], let parsed = parseRemote(u) else { continue }
            // SSH 별칭은 연결된 계정의 gitch 별칭과 정확히 일치할 때만 API 서버로 바꾼다.
            let ssh = !u.contains("://") || u.lowercased().hasPrefix("ssh://")
            let r = ParsedRemote(host: ssh ? sshAliases[parsed.host] ?? parsed.host : parsed.host, path: parsed.path)
            if r.host == "github.com" {
                return RepoTarget(provider: .github, remote: name, host: r.host, path: r.path)
            }
            if gitlabHosts.contains(r.host) || r.host.contains("gitlab") {
                return RepoTarget(provider: .gitlab, remote: name, host: r.host, path: r.path)
            }
        }
        return nil
    }

    // MARK: 요청 공통

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()


    static func request(_ p: Provider, _ url: String, token: String, method: String = "GET",
                                body: [String: Any]? = nil) throws -> URLRequest {
        guard let u = URL(string: url) else { throw HostingError(status: 0, body: Data(String(localized: "Invalid address: \(url)").utf8)) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.httpMethod = method
        r.setValue("Gitrochi", forHTTPHeaderField: "User-Agent")
        switch p {
        case .github:
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        case .gitlab:
            r.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    static func send<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        try decoder.decode(T.self, from: try await data(req))
    }

    /// 응답 본문(204 처럼 본문이 없어도 성공이면 빈 Data)
    @discardableResult
    static func data(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HostingError(status: code, body: data) }
        return data
    }

    static func projectID(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: 응답 모델

    private struct GHUser: Decodable { let login: String; let name: String?; let avatarUrl: String? }
    private struct GHRepoRef: Decodable { let fullName: String }
    private struct GHRef: Decodable { let ref: String; let sha: String; let repo: GHRepoRef? }
    private struct GHPull: Decodable {
        let number: Int; let title: String; let htmlUrl: String; let draft: Bool?
        let updatedAt: String?; let body: String?; let user: GHUser; let head: GHRef; let base: GHRef
    }
    private struct GHRepo: Decodable {
        let fullName: String; let cloneUrl: String; let `private`: Bool; let description: String?; let defaultBranch: String?
    }

    private struct GLUser: Decodable { let username: String; let name: String?; let avatarUrl: String? }
    private struct GLMergeRequest: Decodable {
        let iid: Int; let title: String; let webUrl: String; let draft: Bool?; let workInProgress: Bool?
        let updatedAt: String?; let description: String?; let author: GLUser
        let sourceBranch: String; let targetBranch: String; let sha: String?
        let sourceProjectId: Int?; let targetProjectId: Int?
    }
    private struct GLProject: Decodable {
        let pathWithNamespace: String; let httpUrlToRepo: String; let visibility: String?
        let description: String?; let defaultBranch: String?
    }

    private static func pull(_ p: GHPull, repoPath: String) -> PullRequest {
        PullRequest(number: p.number, title: p.title, author: p.user.login, source: p.head.ref, target: p.base.ref,
                    url: p.htmlUrl, isDraft: p.draft ?? false, updated: date(p.updatedAt), body: p.body ?? "",
                    headSHA: p.head.sha, fromFork: p.head.repo.map { $0.fullName.lowercased() != repoPath.lowercased() } ?? true)
    }

    private static func merge(_ m: GLMergeRequest) -> PullRequest {
        PullRequest(number: m.iid, title: m.title, author: m.author.username, source: m.sourceBranch, target: m.targetBranch,
                    url: m.webUrl, isDraft: m.draft ?? m.workInProgress ?? false, updated: date(m.updatedAt),
                    body: m.description ?? "", headSHA: m.sha,
                    fromFork: m.sourceProjectId != nil && m.sourceProjectId != m.targetProjectId)
    }

    // MARK: API

    struct Me { let username: String; let name: String?; let avatarURL: String? }

    static func me(_ p: Provider, token: String, apiBase: String) async throws -> Me {
        let req = try request(p, apiBase + "/user", token: token)
        switch p {
        case .github:
            let u = try await send(GHUser.self, req)
            return Me(username: u.login, name: u.name, avatarURL: u.avatarUrl)
        case .gitlab:
            let u = try await send(GLUser.self, req)
            return Me(username: u.username, name: u.name, avatarURL: u.avatarUrl)
        }
    }

    static func defaultBranch(_ t: RepoTarget, token: String, apiBase: String) async throws -> String? {
        switch t.provider {
        case .github:
            let req = try request(.github, apiBase + "/repos/\(t.path)", token: token)
            return try await send(GHRepo.self, req).defaultBranch
        case .gitlab:
            let req = try request(.gitlab, apiBase + "/projects/\(projectID(t.path))", token: token)
            return try await send(GLProject.self, req).defaultBranch
        }
    }

    static func createPullRequest(_ t: RepoTarget, token: String, apiBase: String, title: String, body: String,
                                  source: String, target: String, draft: Bool) async throws -> PullRequest {
        switch t.provider {
        case .github:
            let req = try request(.github, apiBase + "/repos/\(t.path)/pulls", token: token, method: "POST",
                                  body: ["title": title, "body": body, "head": source, "base": target, "draft": draft])
            return pull(try await send(GHPull.self, req), repoPath: t.path)
        case .gitlab:
            let req = try request(.gitlab, apiBase + "/projects/\(projectID(t.path))/merge_requests", token: token, method: "POST",
                                  body: ["title": draft ? "Draft: " + title : title, "description": body,
                                         "source_branch": source, "target_branch": target])
            return merge(try await send(GLMergeRequest.self, req))
        }
    }

    /// 계정이 접근할 수 있는 저장소(최근 활동 순)
    static func repositories(_ p: Provider, token: String, apiBase: String) async throws -> [RemoteRepo] {
        switch p {
        case .github:
            let req = try request(.github, apiBase + "/user/repos?per_page=100&sort=updated", token: token)
            return try await send([GHRepo].self, req).map {
                RemoteRepo(fullName: $0.fullName, cloneURL: $0.cloneUrl, isPrivate: $0.private, summary: $0.description)
            }
        case .gitlab:
            let req = try request(.gitlab, apiBase + "/projects?membership=true&simple=true&order_by=last_activity_at&per_page=100", token: token)
            return try await send([GLProject].self, req).map {
                RemoteRepo(fullName: $0.pathWithNamespace, cloneURL: $0.httpUrlToRepo,
                           isPrivate: $0.visibility != "public", summary: $0.description)
            }
        }
    }
}
