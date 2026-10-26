#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct HostingError: LocalizedError { let status: Int; var errorDescription: String? { "HTTP \(status)" } }
enum Hosting {
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected HTTP") }
    static func projectID(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~")))! }
    static func request(_ p: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest { var r = URLRequest(url: URL(string: url)!); r.httpMethod = method; if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }; return r }
    static func data(_ request: URLRequest) async throws -> Data { try handler(request) }
}
@main struct HubTests {
    @MainActor static func main() async throws {
        func json(_ x: Any) throws -> Data { try JSONSerialization.data(withJSONObject: x) }
        let gh = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/repo"), token: "fixture", apiBase: "https://api.github.com", me: "me")
        let gl = HubAccess(target: RepoTarget(provider: .gitlab, remote: "origin", host: "gitlab.test", path: "team/repo"), token: "fixture", apiBase: "https://gitlab.test/api/v4", me: "me")
        let ownerTarget = HostingHubAPI.projectTarget(gh.target, provider: .github, host: "github.com", username: "me", personal: false)
        let myTarget = HostingHubAPI.projectTarget(gh.target, provider: .github, host: "github.com", username: "me", personal: true)
        precondition(ownerTarget.path == "team/repo" && myTarget.path == "me/workspace" && myTarget.host == "github.com")
        let absentTarget = HostingHubAPI.projectTarget(nil, provider: .github, host: "github.com", username: "me", personal: false)
        precondition(absentTarget.path == "me/workspace")
        var calls = [URLRequest]()
        Hosting.handler = { r in calls.append(r); return try json((0..<30).map { ["id": $0, "tag_name": "v\($0)", "name": "Release \($0)"] }) }
        let releases = try await HostingHubAPI.page(gh, section: .releases, page: 2)
        precondition(releases.items.count == 30 && releases.more && calls[0].url!.query!.contains("page=2"))
        let githubOrganization: [String: Any] = ["id": 77, "login": "octo", "description": "Team", "avatar_url": "https://avatars.githubusercontent.com/u/77?v=4"]
        var organizationPaths = [String]()
        Hosting.handler = { request in
            organizationPaths.append(request.url!.path)
            if request.url!.path == "/user/orgs" { return try json([githubOrganization]) }
            if request.url!.path == "/orgs/octo" {
                var detail = githubOrganization; detail["name"] = "Octo team"; detail["html_url"] = "https://github.com/octo"; detail["avatar_url"] = "https://avatars.githubusercontent.com/u/77?v=5"
                return try json(detail)
            }
            precondition(request.url!.path == "/orgs/octo/repos")
            return try json([])
        }
        let githubOrganizations = try await HostingHubAPI.page(gh, section: .organizations)
        let githubOrganizationItem = githubOrganizations.items[0]
        precondition(githubOrganizationItem.id == "octo" && githubOrganizationItem.title == "octo" && githubOrganizationItem.subtitle == "octo" && githubOrganizationItem.url == "https://github.com/octo")
        precondition(githubOrganizationItem.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/77?v=4" && !githubOrganizations.more)
        let githubOrganizationDetail = try await HostingHubAPI.detail(gh, section: .organizations, item: githubOrganizationItem)
        precondition(githubOrganizationDetail.item.title == "Octo team" && githubOrganizationDetail.item.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/77?v=5")
        precondition(organizationPaths == ["/user/orgs", "/orgs/octo", "/orgs/octo/repos"])
        Hosting.handler = { request in try json(request.url!.path == "/orgs/octo" ? ["description": "Updated team"] : [] as [Any]) }
        let sparseGithubOrganization = try await HostingHubAPI.detail(gh, section: .organizations, item: githubOrganizationDetail.item)
        precondition(sparseGithubOrganization.item.id == "octo" && sparseGithubOrganization.item.title == "Octo team" && sparseGithubOrganization.item.subtitle == "octo")
        precondition(sparseGithubOrganization.item.url == "https://github.com/octo" && sparseGithubOrganization.item.body == "Updated team")
        precondition(sparseGithubOrganization.item.avatarURL == githubOrganizationDetail.item.avatarURL)
        let gitlabOrganization: [String: Any] = ["id": 9, "name": "Design", "full_path": "team/design", "avatar_url": "/uploads/groups/9/avatar.png", "web_url": "https://gitlab.test/team/design"]
        Hosting.handler = { request in
            if request.url!.path == "/api/v4/groups" { return try json([gitlabOrganization]) }
            if request.url!.path == "/api/v4/groups/9" { return try json(gitlabOrganization) }
            precondition(request.url!.path == "/api/v4/groups/9/projects")
            return try json([])
        }
        let gitlabOrganizations = try await HostingHubAPI.page(gl, section: .organizations)
        let gitlabOrganizationItem = gitlabOrganizations.items[0]
        precondition(gitlabOrganizationItem.id == "9" && gitlabOrganizationItem.title == "Design" && gitlabOrganizationItem.subtitle == "team/design")
        precondition(gitlabOrganizationItem.avatarURL?.absoluteString == "https://gitlab.test/uploads/groups/9/avatar.png")
        let gitlabOrganizationDetail = try await HostingHubAPI.detail(gl, section: .organizations, item: gitlabOrganizationItem)
        precondition(gitlabOrganizationDetail.item.avatarURL == gitlabOrganizationItem.avatarURL)
        Hosting.handler = { request in try json(request.url!.path == "/api/v4/groups/9" ? ["avatar_url": NSNull(), "web_url": ""] : [] as [Any]) }
        let clearedGitlabOrganization = try await HostingHubAPI.detail(gl, section: .organizations, item: gitlabOrganizationItem)
        precondition(clearedGitlabOrganization.item.id == "9" && clearedGitlabOrganization.item.title == "Design" && clearedGitlabOrganization.item.subtitle == "team/design")
        precondition(clearedGitlabOrganization.item.url == gitlabOrganizationItem.url && clearedGitlabOrganization.item.avatarURL == nil)
        precondition(HostingHubAPI.organizationItem(gl, ["id": 10, "full_name": "Team / Fallback", "avatar_url": NSNull()]).avatarURL == nil)
        precondition(HostingHubAPI.organizationItem(gh, ["login": "unsafe", "avatar_url": "https://untrusted.test/logo.png"]).avatarURL == nil)
        precondition(HostingHubAPI.organizationItem(gl, ["id": 11, "avatar_url": "//untrusted.test/logo.png"]).avatarURL == nil)
        Hosting.handler = { r in
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any], variables = body["variables"] as! [String: Any]
            precondition((body["query"] as! String).contains("user(login:$owner)") && variables["owner"] as? String == "me")
            return try json(["data": ["user": ["projectsV2": ["nodes": [["id": "personal", "title": "My project"]], "pageInfo": ["hasNextPage": false]]]]])
        }
        let personalPage = try await HostingHubAPI.page(HubAccess(target: myTarget, token: "fixture", apiBase: gh.apiBase, me: "me"), section: .projects)
        precondition(personalPage.items.first?.id == "personal")
        var stale = gh; stale.isCurrent = { false }
        let n = calls.count
        do { try await HostingHubAPI.saveRelease(stale, HubReleaseInput(tag: "v1", name: "One")); fatalError("Stale write") } catch {}
        precondition(calls.count == n)
        precondition(HostingHubAPI.safeURL(gh, "javascript:alert(1)") == nil)
        precondition(HostingHubAPI.safeURL(gh, "https://evil.test/x") == nil)
        precondition(HostingHubAPI.safeURL(gh, "https://github.com/team/repo") != nil)
        precondition(HostingHubAPI.safeURL(gh, "https://user:pass@github.com/x") == nil)
        let gitlabMember = HostingHubAPI.member(gl, ["id": 7, "username": "alex", "name": "Alex Kim", "access_level": 40, "avatar_url": "/uploads/alex.png", "web_url": "https://gitlab.test/alex"])
        precondition(gitlabMember.id == "7" && gitlabMember.name == "Alex Kim" && gitlabMember.username == "alex" && gitlabMember.role == "Maintainer")
        precondition(gitlabMember.avatarURL?.absoluteString == "https://gitlab.test/uploads/alex.png" && gitlabMember.profileURL?.absoluteString == "https://gitlab.test/alex")
        let memberFallback = HostingHubAPI.member(gl, ["id": 8, "username": "sam", "name": " ", "avatar_url": "https://untrusted.test/photo.png", "web_url": "javascript:alert(1)"])
        precondition(memberFallback.name == "sam" && memberFallback.role == "Member" && memberFallback.avatarURL == nil && memberFallback.profileURL?.absoluteString == "https://gitlab.test/sam")
        let roleLabels = [5: "Minimal access", 10: "Guest", 15: "Planner", 20: "Reporter", 30: "Developer", 40: "Maintainer", 50: "Owner"]
        for (level, label) in roleLabels { precondition(HostingHubAPI.member(gl, ["username": "sam", "access_level": level]).role == label) }
        precondition(HostingHubAPI.safeAvatarURL(provider: .github, host: "github.com", "https://avatars.githubusercontent.com/u/7") != nil)
        precondition(HostingHubAPI.safeAvatarURL(provider: .github, host: "github.com", "https://avatars.githubusercontent.com.evil.test/u/7") == nil)
        precondition(HostingHubAPI.safeAvatarURL(provider: .gitlab, host: "gitlab.test", "https://user:pass@gitlab.test/alex.png") == nil)
        precondition(HostingHubAPI.safeAvatarURL(provider: .gitlab, host: "gitlab.test", "http://gitlab.test/alex.png") == nil)
        var profileCalls = 0
        Hosting.handler = { request in
            profileCalls += 1
            precondition(request.url?.absoluteString == "https://api.github.com/graphql")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any], variables = body["variables"] as! [String: Any]
            precondition(variables.count == 2 && variables["login0"] as? String == "alex" && variables["login1"] as? String == "sam")
            precondition((body["query"] as! String).contains("member0:user(login:$login0)"))
            return try json(["data": ["member0": ["name": "Alex Kim", "avatarUrl": "https://untrusted.test/photo.png", "url": "https://untrusted.test/alex"], "member1": NSNull()], "errors": [["message": "One public profile is unavailable"]]])
        }
        let profiles = try await HostingHubAPI.members(gh, rows: [["id": 7, "login": "alex", "avatar_url": "https://avatars.githubusercontent.com/u/7", "html_url": "https://github.com/alex"], ["id": 8, "login": "sam"]])
        precondition(profileCalls == 1 && profiles.count == 2 && profiles[0].name == "Alex Kim" && profiles[1].name == "sam")
        precondition(profiles[0].avatarURL?.host == "avatars.githubusercontent.com" && profiles[0].profileURL?.host == "github.com")
        Hosting.handler = { _ in throw HostingError(status: 403) }
        let unavailableProfiles = try await HostingHubAPI.members(gh, rows: [["id": 7, "login": "alex"]])
        precondition(unavailableProfiles.first?.name == "alex" && unavailableProfiles.first?.profileURL?.absoluteString == "https://github.com/alex")
        var profilesCurrent = true, staleProfiles = gh
        staleProfiles.isCurrent = { profilesCurrent }
        Hosting.handler = { _ in profilesCurrent = false; return try json(["data": ["member0": ["name": "Stale profile"]]]) }
        do { _ = try await HostingHubAPI.members(staleProfiles, rows: [["id": 7, "login": "alex"]]); fatalError("Stale profiles accepted") } catch {}
        Hosting.handler = { r in calls.append(r); if r.url!.path.hasSuffix("/star") { throw HostingError(status: 404) }; return try json(["id": "g1", "description": "Example", "owner": ["login": "me"], "updated_at": "a", "files": ["a.txt": ["content": "first", "truncated": false]]]) }
        let detail = try await HostingHubAPI.detail(gh, section: .gists, item: HubItem(id: "g1", title: "Example"))
        precondition(detail.files.first?.content == "first" && detail.item.editable && detail.starred == false)
        var changed = detail; changed.files[0].content = "outdated"
        let writesBefore = calls.filter { $0.httpMethod != "GET" }.count
        do { try await HostingHubAPI.saveGist(gh, HubGistInput(description: "new", files: [HubFile(name: "a.txt", content: "updated")]), previous: changed); fatalError("Overwrote remote changes") } catch {}
        precondition(calls.filter { $0.httpMethod != "GET" }.count == writesBefore)
        var draft = HubReleaseInput(tag: "v1", name: "One"); draft.draft = true
        do { try await HostingHubAPI.saveRelease(gl, draft); fatalError("GitLab draft unsupported") } catch {}
        precondition(HostingHubAPI.snippetRef(rawURL: "https://gitlab.test/-/snippets/1/raw/feature/x/folder/a.txt", file: "folder/a.txt") == "feature/x")
        Hosting.handler = { r in calls.append(r); if r.httpMethod == "GET" { return try json(["iid": 2, "labels": ["Todo", "Done", "security"]]) }; let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]; precondition(body["remove_labels"] as? String == "Todo" && body["add_labels"] as? String == "Done"); return try json([:]) }
        let field = HubProjectField(id: "board", name: "Status", options: [HubProjectOption(id: "1", name: "Todo"), HubProjectOption(id: "2", name: "Done")]), row = HubProjectRow(id: "2", title: "Issue", body: "", url: "", contentID: "22", statuses: [:])
        try await HostingHubAPI.move(gl, detail: HubDetail(item: HubItem(id: "1", title: "Board"), fields: [field], rows: [row]), row: row, field: field, option: "2")
        let scope = HostingHubAPI.boardIssueQuery(["hide_closed_list": true, "labels": [["name": "security"]], "assignee": ["id": 7], "milestone": ["title": "1.0"], "weight": 0], page: 2)
        precondition(scope.contains("assignee_id=7") && scope.contains("labels=security") && scope.contains("milestone=1.0") && scope.contains("weight=0") && scope.contains("state=opened"))
        var creations = 0
        Hosting.handler = { request in creations += 1; throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "connection lost"]) }
        do { try await HostingHubAPI.saveGist(gh, HubGistInput(description: "new", files: [HubFile(name: "a.txt", content: "text")])); fatalError("Uncertain creation accepted") } catch is HubUncertainWriteError {} catch { fatalError("Unexpected error type") }
        precondition(creations == 1)
        let boardFields = [HubProjectField(id: "priority", name: "Priority", options: [HubProjectOption(id: "high", name: "High")]), HubProjectField(id: "status", name: "Status", options: [HubProjectOption(id: "todo", name: "Todo"), HubProjectOption(id: "done", name: "Done")])]
        let boardRows = [HubProjectRow(id: "1", title: "Task", body: "", url: "", contentID: "1", statuses: ["status": "todo"]), HubProjectRow(id: "2", title: "Unassigned", body: "", url: "", contentID: "2", statuses: [:]), HubProjectRow(id: "3", title: "Old status", body: "", url: "", contentID: "3", statuses: ["status": "removed"])]
        let board = HubDetail(item: HubItem(id: "board", title: "Board"), fields: boardFields, rows: boardRows)
        let columns = HostingHubAPI.projectColumns(board)
        precondition(columns.map(\.id) == ["", "todo", "done"] && columns.map { $0.rows.count } == [2, 1, 0])
        precondition(columns.flatMap(\.rows).map(\.id).sorted() == ["1", "2", "3"])
        precondition(HostingHubAPI.projectColumns(board, fieldID: "priority").map(\.id) == ["", "high"])
        Hosting.handler = { _ in try json(["errors": [["type": "INSUFFICIENT_SCOPES", "message": "id requires read:project"], ["message": "title requires read:project"]]]) }
        do { _ = try await HostingHubAPI.page(gh, section: .projects); fatalError("Missing scope accepted") }
        catch let error as HubProjectPermissionError { precondition(error.localizedDescription.contains("Connect project access") && !error.localizedDescription.contains("id requires")) }
        catch { fatalError("Scope recovery type missing") }
        Hosting.handler = { _ in try json(["errors": [["message": "unrelated internal exception"]]]) }
        do { _ = try await HostingHubAPI.page(gh, section: .projects); fatalError("GraphQL failure accepted") }
        catch is HubProjectPermissionError { fatalError("Unrelated error offered authorization") }
        catch { precondition(error.localizedDescription.contains("Projects could not be loaded") && !error.localizedDescription.contains("internal exception")) }
        let secret = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture github_pat_abc token"])
        precondition(!HostingHubAPI.error(secret, token: "fixture").contains("fixture"))
        print("Hosting hub: organization avatars in lists and details, pagination, stale context, safe member profiles, batched profile enrichment and fallback, URL restrictions, gist conflict protection, GitLab drafts, snippet refs, status-board grouping and project scope recovery passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-hub"
"$TASK_TMP/test-hub"
