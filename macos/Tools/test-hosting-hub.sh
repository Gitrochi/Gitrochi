#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tools/project-backend-test-sources.sh"
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
            if request.url!.path == "/user/memberships/orgs/octo" { return try json(["role": "admin", "state": "active", "user": ["login": "me"]]) }
            precondition(request.url!.path == "/orgs/octo/repos")
            return try json([])
        }
        let githubOrganizations = try await HostingHubAPI.page(gh, section: .organizations)
        let githubOrganizationItem = githubOrganizations.items[0]
        precondition(githubOrganizationItem.id == "octo" && githubOrganizationItem.title == "octo" && githubOrganizationItem.subtitle == "octo" && githubOrganizationItem.url == "https://github.com/octo")
        precondition(githubOrganizationItem.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/77?v=4" && !githubOrganizations.more)
        let githubOrganizationDetail = try await HostingHubAPI.detail(gh, section: .organizations, item: githubOrganizationItem)
        precondition(githubOrganizationDetail.item.title == "Octo team" && githubOrganizationDetail.item.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/77?v=5")
        precondition(organizationPaths == ["/user/orgs", "/orgs/octo", "/user/memberships/orgs/octo", "/orgs/octo/repos"])
        Hosting.handler = { request in
            precondition(request.url!.path == "/user/orgs" && request.url!.query!.contains("page=2"))
            return try json((0..<30).map { ["id": 100 + $0, "login": "team-\($0)"] })
        }
        let organizationDiscoveryPage = try await HostingHubAPI.page(gh, section: .organizations, page: 2)
        precondition(organizationDiscoveryPage.items.count == 30 && organizationDiscoveryPage.more)
        Hosting.handler = { request in
            precondition(request.url!.path == "/user/memberships/orgs" && request.url!.query!.contains("page=3"))
            return try json([["organization": ["id": 201, "login": "membership-team"]]])
        }
        let membershipDiscoveryPage = try await HostingHubAPI.page(gh, section: .organizations, page: 3, cursor: "organizationMemberships")
        precondition(membershipDiscoveryPage.items.first?.id == "membership-team" && !membershipDiscoveryPage.more && membershipDiscoveryPage.cursor == "organizationMemberships")
        Hosting.handler = { request in try json(request.url!.path == "/orgs/octo" ? ["description": "Updated team"] : [] as [Any]) }
        let sparseGithubOrganization = try await HostingHubAPI.detail(gh, section: .organizations, item: githubOrganizationDetail.item)
        precondition(sparseGithubOrganization.item.id == "octo" && sparseGithubOrganization.item.title == "Octo team" && sparseGithubOrganization.item.subtitle == "octo")
        precondition(sparseGithubOrganization.item.url == "https://github.com/octo" && sparseGithubOrganization.item.body == "Updated team")
        precondition(sparseGithubOrganization.item.avatarURL == githubOrganizationDetail.item.avatarURL)
        let gitlabOrganization: [String: Any] = ["id": 9, "name": "Design", "full_path": "team/design", "avatar_url": "/uploads/groups/9/avatar.png", "web_url": "https://gitlab.test/team/design"]
        Hosting.handler = { request in
            if request.url!.path == "/api/v4/groups" { return try json([gitlabOrganization]) }
            if request.url!.path == "/api/v4/groups/9" { return try json(gitlabOrganization) }
            if request.url!.path == "/api/v4/user" { return try json(["id": 7, "username": "me"]) }
            if request.url!.path == "/api/v4/groups/9/members/all/7" { return try json(["id": 7, "username": "me", "access_level": 50]) }
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
        precondition(HostingHubAPI.projectOrganization(scope: "organization:demo-team") == "demo-team")
        for invalid in ["organization:", "organization:../team", "organization:team/path", "organization:team name", "organization:team-", "organization:two--hyphens", "personal", "organization:" + String(repeating: "a", count: 40)] {
            precondition(HostingHubAPI.projectOrganization(scope: invalid) == nil)
        }
        let organizationTarget = HostingHubAPI.projectTarget(nil, provider: .github, host: "github.com", username: "me", personal: false, organization: "demo-team")
        precondition(organizationTarget.path == "demo-team/workspace")
        // An explicit organization never resolves through a local repository or personal-project query.
        var organizationAccess = HubAccess(target: myTarget, token: "fixture", apiBase: gh.apiBase, me: "me", projectOrganization: "demo-team")
        var organizationPageCalls = 0
        Hosting.handler = { request in
            organizationPageCalls += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any], variables = body["variables"] as! [String: Any], query = body["query"] as! String
            precondition(query.contains("organization(login:$owner)") && !query.contains("repository(owner:") && !query.contains("user(login:"))
            precondition(variables["owner"] as? String == "demo-team" && variables["name"] == nil)
            if organizationPageCalls == 1 { precondition(variables["cursor"] is NSNull) }
            else { precondition(variables["cursor"] as? String == "organization-next") }
            return try json(["data": ["organization": ["projectsV2": ["nodes": [["id": "ORG-\(organizationPageCalls)", "title": "Team roadmap"]], "pageInfo": ["hasNextPage": organizationPageCalls == 1, "endCursor": "organization-next"]]]]])
        }
        let firstOrganizationPage = try await HostingHubAPI.page(organizationAccess, section: .projects)
        let secondOrganizationPage = try await HostingHubAPI.page(organizationAccess, section: .projects, page: 2, cursor: firstOrganizationPage.cursor)
        precondition(firstOrganizationPage.more && firstOrganizationPage.items.first?.id == "ORG-1")
        precondition(!secondOrganizationPage.more && secondOrganizationPage.items.first?.id == "ORG-2")
        organizationAccess.isCurrent = { false }
        do { _ = try await HostingHubAPI.page(organizationAccess, section: .projects); fatalError("Stale organization request") } catch {}
        precondition(organizationPageCalls == 2)
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
        Hosting.handler = { r in
            if r.url!.path.hasSuffix("/issues") { return try json([["id": 20, "iid": 2, "title": "Fix", "state": "opened", "web_url": "https://gitlab.test/team/repo/-/issues/2", "assignees": [["username": "alex"]], "labels": ["bug"], "updated_at": "today"]]) }
            if r.url!.path.hasSuffix("/lists") { return try json([]) }; return try json(["id": 1, "name": "Board"])
        }
        let labProject = try await HostingHubAPI.detail(gl, section: .projects, item: HubItem(id: "1", title: "Board"))
        precondition(labProject.rows[0].kind == .issue && labProject.rows[0].number == 2 && labProject.rows[0].repository == "team/repo" && labProject.rows[0].state == "OPEN" && labProject.rows[0].assignees == ["alex"] && labProject.rows[0].updatedAt == "today")
        // GitLab groups: full paths, every board and issue page, and writes through each issue's own project.
        precondition(HostingHubAPI.projectOrganization(scope: "organization:team/design", provider: .gitlab) == "team/design" && HostingHubAPI.projectOrganization(scope: "organization:team/design") == nil)
        for value in ["", "../team", "team//design", "team/..", "-team", "team/design?x", String(repeating: "a", count: 256)] { precondition(HostingHubAPI.projectOrganization(scope: "organization:" + value, provider: .gitlab) == nil) }
        let labGroup = HubAccess(target: HostingHubAPI.projectTarget(nil, provider: .gitlab, host: "gitlab.test", username: "me", personal: false, organization: "team/design"), token: "fixture", apiBase: "https://gitlab.test/api/v4", me: "me", projectOrganization: "team/design")
        func pageNumber(_ r: URLRequest) -> Int { Int(URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "") ?? 0 }
        calls = []
        Hosting.handler = { r in calls.append(r); return try json((0..<(pageNumber(r) == 1 ? 100 : 5)).map { ["id": (pageNumber(r) - 1) * 100 + $0, "name": "Board \($0)"] as [String: Any] }) }
        let groupBoards = try await HostingHubAPI.page(labGroup, section: .projects)
        precondition(groupBoards.items.count == 105 && !groupBoards.more && groupBoards.items[0].url == "https://gitlab.test/groups/team/design/-/boards/0")
        precondition(calls.map { $0.url!.absoluteString } == ["https://gitlab.test/api/v4/groups/team%2Fdesign/boards?per_page=100&page=1", "https://gitlab.test/api/v4/groups/team%2Fdesign/boards?per_page=100&page=2"])
        do { _ = try await HostingHubAPI.page(HubAccess(target: RepoTarget(provider: .gitlab, remote: "origin", host: "gitlab.test", path: "me/workspace"), token: "fixture", apiBase: "https://gitlab.test/api/v4", me: "me"), section: .projects); fatalError("GitLab boards without a scope") } catch { precondition(error.localizedDescription.contains("Choose a group")) }
        func labIssue(_ id: Int, _ project: String, _ iid: Int, _ labels: [String] = []) -> [String: Any] { ["id": id, "iid": iid, "title": "Task \(id)", "state": "opened", "web_url": "https://gitlab.test/\(project)/-/issues/\(iid)", "references": ["full": "\(project)#\(iid)"], "labels": labels] }
        var writes = [URLRequest]()
        Hosting.handler = { r in
            calls.append(r); let url = r.url!.absoluteString
            if r.httpMethod == "PUT" { writes.append(r); return try json([String: Any]()) }
            if url.contains("/lists?") { return try json([["label": ["id": 11, "name": "Doing"] as [String: Any]]]) }
            if url.contains("/issues?") { return try json(pageNumber(r) == 1 ? (0..<100).map { labIssue($0 + 1, $0 % 2 == 1 ? "team/design/app" : "team/design/web", $0 / 2 + 1) } : [labIssue(100, "team/design/app", 50), labIssue(101, "team/design/app", 51, ["Doing"])]) }
            if url.contains("/issues/") { return try json(["labels": [String]()]) }
            return try json(["id": 4, "name": "Delivery", "labels": [Any]()] as [String: Any])
        }
        calls = []
        let groupBoard = try await HostingHubAPI.detail(labGroup, section: .projects, item: HubItem(id: "4", title: "Delivery"))
        precondition(groupBoard.rows.count == 101 && !groupBoard.more && Set(groupBoard.rows.map(\.id)).count == 101)
        precondition(groupBoard.rows[0].id == "1" && groupBoard.rows[0].number == 1 && groupBoard.rows[0].repository == "team/design/web")
        precondition(groupBoard.rows[100].id == "101" && groupBoard.rows[100].repository == "team/design/app" && groupBoard.rows[100].statuses["board"] == "11")
        precondition(calls.allSatisfy { $0.url!.absoluteString.hasPrefix("https://gitlab.test/api/v4/groups/team%2Fdesign/") })
        try await HostingHubAPI.move(labGroup, detail: groupBoard, row: groupBoard.rows[1], field: groupBoard.fields[0], option: "11")
        precondition(writes.map { $0.url!.absoluteString } == ["https://gitlab.test/api/v4/projects/team%2Fdesign%2Fapp/issues/1"])
        let moved = try JSONSerialization.jsonObject(with: writes[0].httpBody!) as! [String: Any]
        precondition(moved["add_labels"] as? String == "Doing" && moved["state_event"] as? String == "reopen")
        calls = []
        Hosting.handler = { r in calls.append(r); let value: [String: Any] = r.httpMethod == "PUT" ? [:] : ["id": 70, "iid": 7, "title": "Task", "labels": [String]()]; return try json(value) }
        let emptyBoard = HubDetail(item: groupBoard.item, fields: groupBoard.fields)
        for foreign in ["https://gitlab.test/other/app/-/issues/7", "https://gitlab.test/team/designer/app/-/issues/7"] {
            do { try await HostingHubAPI.addIssue(labGroup, detail: emptyBoard, issueURL: foreign); fatalError("Foreign group issue accepted") } catch { precondition(error.localizedDescription.contains("repository in this group")) }
        }
        precondition(calls.isEmpty)
        try await HostingHubAPI.addIssue(labGroup, detail: emptyBoard, issueURL: "https://gitlab.test/team/design/sub/app/-/issues/7")
        precondition(calls.map { $0.url!.absoluteString } == Array(repeating: "https://gitlab.test/api/v4/projects/team%2Fdesign%2Fsub%2Fapp/issues/7", count: 3) && calls.last?.httpMethod == "PUT")
        Hosting.handler = { r in
            let url = r.url!.absoluteString, page = pageNumber(r)
            if url.contains("/boards?") { return try json((0..<(page == 1 ? 100 : 1)).map { ["id": (page - 1) * 100 + $0, "name": "Board"] as [String: Any] }) }
            if url.contains("/lists?") { return try json([Any]()) }
            if url.contains("/issues?") {
                let count = page == 1 ? 100 : 3, first = (page - 1) * 100
                let issues: [[String: Any]] = (0..<count).map { index in let iid: Int = first + index + 1; return ["id": page * 1000 + index, "iid": iid, "title": "Task", "state": "opened"] }
                return try json(issues)
            }
            return try json(["id": 4, "name": "Board"] as [String: Any])
        }
        let repositoryBoards = try await HostingHubAPI.page(gl, section: .projects)
        let repositoryBoard = try await HostingHubAPI.detail(gl, section: .projects, item: HubItem(id: "4", title: "Board"))
        precondition(repositoryBoards.items.count == 101 && !repositoryBoards.more && repositoryBoard.rows.count == 103 && !repositoryBoard.more && repositoryBoard.rows[102].id == "103" && repositoryBoard.rows[102].repository == "team/repo")
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
        let richFields: [[String: Any]] = [["id": "S", "name": "Status", "options": [["id": "done", "name": "Done"]]], ["id": "T", "name": "Notes", "dataType": "TEXT"], ["id": "N", "name": "Estimate", "dataType": "NUMBER"], ["id": "D", "name": "Due", "dataType": "DATE"], ["id": "I", "name": "Sprint", "configuration": ["iterations": [["id": "current", "title": "Sprint 2", "startDate": "2026-10-20", "duration": 14]], "completedIterations": [["id": "previous", "title": "Sprint 1"]]]], ["id": "L", "name": "Labels", "dataType": "LABELS"], ["id": "M", "name": "Teams", "dataType": "MULTI_SELECT"]]
        let richRows: [[String: Any]] = [
            ["id": "R", "type": "ISSUE", "isArchived": true, "updatedAt": "project-newer", "content": ["__typename": "Issue", "id": "C", "title": "Fix", "number": 12, "state": "OPEN", "repository": ["nameWithOwner": "team/repo"], "assignees": ["nodes": [["login": "alex"]]], "labels": ["nodes": [["name": "bug"]]], "updatedAt": "today"], "fieldValues": ["nodes": [["optionId": "done", "field": ["id": "S"]], ["text": "Note", "field": ["id": "T"]], ["number": 0, "field": ["id": "N"]], ["date": "2026-11-01", "field": ["id": "D"]], ["iterationId": "current", "field": ["id": "I"]]]]],
            ["id": "PR", "content": ["__typename": "PullRequest", "id": "CPR", "title": "Feature", "headRefName": "feature/plan"]],
            ["id": "draft", "content": ["__typename": "DraftIssue", "id": "draft-content", "title": "Draft"]], ["id": "redacted", "type": "REDACTED"]
        ]
        Hosting.handler = { r in
            calls.append(r)
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
            precondition((body["query"] as! String).contains("completedIterations") && (body["query"] as! String).contains("ProjectV2ItemFieldDateValue") && (body["query"] as! String).contains("archivedStates:[ARCHIVED,NOT_ARCHIVED]") && (body["query"] as! String).contains("... on ProjectV2FieldCommon{id name dataType}"))
            return try json(["data": ["node": ["id": "P", "title": "Plan", "readme": "Handbook", "public": true, "fields": ["nodes": richFields, "pageInfo": [:]], "items": ["nodes": richRows, "pageInfo": [:]]]]])
        }
        let project = try await HostingHubAPI.detail(gh, section: .projects, item: HubItem(id: "P", title: "Plan"))
        precondition(project.fields.map(\.kind) == [.singleSelect, .text, .number, .date, .iteration, .unsupported, .unsupported])
        precondition(project.fields[6].id == "M" && project.fields[6].name == "Teams")
        precondition(project.fields[4].options.map(\.id) == ["current", "previous"] && project.fields[4].options[0].duration == 14)
        precondition(project.rows.map(\.kind) == [.issue, .pullRequest, .draft, .redacted])
        precondition(project.rows[0].number == 12 && project.rows[0].repository == "team/repo" && project.rows[0].assignees == ["alex"] && project.rows[0].labels == ["bug"] && project.rows[0].archived && project.rows[0].updatedAt == "project-newer" && project.rows[0].values == ["S": "done", "T": "Note", "N": "0", "D": "2026-11-01", "I": "current"])
        precondition(project.rows[1].headRefName == "feature/plan" && project.item.data["readme"] as? String == "Handbook" && project.item.data["public"] as? Bool == true)
        var payloads = [[String: Any]](), queries = [String]()
        Hosting.handler = { r in calls.append(r); let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]; let query = body["query"] as! String; queries.append(query); if query.hasPrefix("query") { return try json(["data": ["node": ["id": "draft-content", "title": "Draft", "body": ""]]]) }; payloads.append((body["variables"] as! [String: Any])["input"] as! [String: Any]); return try json(["data": [:]]) }
        for (index, value) in ["done", "Notes", "2.5", "2026-11-01", "current"].enumerated() { try await HostingHubAPI.updateProjectField(gh, detail: project, row: project.rows[0], field: project.fields[index], value: value) }
        precondition((payloads[0]["value"] as! [String: Any])["singleSelectOptionId"] as? String == "done")
        precondition((payloads[1]["value"] as! [String: Any])["text"] as? String == "Notes")
        precondition((payloads[2]["value"] as! [String: Any])["number"] as? Double == 2.5)
        precondition((payloads[3]["value"] as! [String: Any])["date"] as? String == "2026-11-01")
        precondition((payloads[4]["value"] as! [String: Any])["iterationId"] as? String == "current")
        try await HostingHubAPI.updateProjectField(gh, detail: project, row: project.rows[0], field: project.fields[1], value: nil)
        precondition(queries.last!.contains("clearProjectV2ItemFieldValue"))
        let beforeInvalid = calls.count
        for (index, value) in [(0, "unknown"), (2, ""), (2, "NaN"), (2, "Infinity"), (2, "0x10"), (3, "2026-02-30"), (3, "2026-1-1"), (4, "unknown"), (5, "x")] {
            do { try await HostingHubAPI.updateProjectField(gh, detail: project, row: project.rows[0], field: project.fields[index], value: value); fatalError("Invalid field accepted") } catch {}
        }
        var forgedField = project.fields[0]; forgedField.options.append(HubProjectOption(id: "forged", name: "Forged"))
        do { try await HostingHubAPI.updateProjectField(gh, detail: project, row: project.rows[0], field: forgedField, value: "forged"); fatalError("Forged option accepted") } catch {}
        forgedField = project.fields[5]; forgedField.kind = .text
        do { try await HostingHubAPI.updateProjectField(gh, detail: project, row: project.rows[0], field: forgedField, value: "forged"); fatalError("Forged field kind accepted") } catch {}
        var forgedRow = project.rows[0]; forgedRow.id = "unknown"
        do { try await HostingHubAPI.deleteProjectItem(gh, detail: project, row: forgedRow); fatalError("Unloaded deletion accepted") } catch {}
        precondition(calls.count == beforeInvalid)
        try await HostingHubAPI.saveProjectDraft(gh, detail: project, title: "  New draft  ", body: "Body")
        precondition(payloads.last?["title"] as? String == "New draft" && payloads.last?["projectId"] as? String == "P")
        var draftRow = project.rows[2]; draftRow.contentID = "forged"
        try await HostingHubAPI.saveProjectDraft(gh, detail: project, title: "Edit", body: "Body", row: draftRow)
        precondition(payloads.last?["draftIssueId"] as? String == "draft-content")
        try await HostingHubAPI.archiveProjectItem(gh, detail: project, row: project.rows[0], archived: true)
        precondition(queries.last!.contains("archiveProjectV2Item(input:"))
        try await HostingHubAPI.archiveProjectItem(gh, detail: project, row: project.rows[0], archived: false)
        precondition(queries.last!.contains("unarchiveProjectV2Item(input:"))
        try await HostingHubAPI.deleteProjectItem(gh, detail: project, row: project.rows[0])
        precondition(queries.last!.contains("deleteProjectV2Item") && payloads.last?["itemId"] as? String == "R")
        let beforeDraftConflict = calls.count
        Hosting.handler = { r in calls.append(r); return try json(["data": ["node": ["id": "draft-content", "title": "Draft", "body": "Collaborator edit"]]]) }
        do { try await HostingHubAPI.saveProjectDraft(gh, detail: project, title: "Edit", body: "Updated", row: project.rows[2]); fatalError("Overwrote collaborator draft") } catch { precondition(error.localizedDescription.contains("changed on the server")) }
        precondition(calls.count == beforeDraftConflict + 1)
        var draftCurrent = true; var draftAccess = gh; draftAccess.isCurrent = { draftCurrent }
        Hosting.handler = { r in calls.append(r); draftCurrent = false; return try json(["data": ["node": ["id": "draft-content", "title": "Draft", "body": ""]]]) }
        do { try await HostingHubAPI.saveProjectDraft(draftAccess, detail: project, title: "Edit", body: "Updated", row: project.rows[2]); fatalError("Saved a switched-account draft") } catch { precondition(error.localizedDescription.contains("account changed")) }
        precondition(calls.count == beforeDraftConflict + 2)
        Hosting.handler = { r in
            calls.append(r)
            if r.httpMethod == "GET" { precondition(r.url!.path == "/repos/team/repo/pulls/42"); return try json(["node_id": "PR-CONTENT"]) }
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any], input = (body["variables"] as! [String: Any])["input"] as! [String: Any]; precondition(input["contentId"] as? String == "PR-CONTENT"); return try json(["data": [:]])
        }
        try await HostingHubAPI.addIssue(gh, detail: project, issueURL: "https://github.com/team/repo/pull/42")
        let beforeUnsafe = calls.count
        let enterprise = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "enterprise.test", path: "team/repo"), token: "fixture", apiBase: "https://enterprise.test/api", me: "me")
        do { try await HostingHubAPI.addIssue(enterprise, detail: project, issueURL: "https://github.com/team/repo/issues/1"); fatalError("Cross-server item accepted") } catch {}
        precondition(calls.count == beforeUnsafe)
        creations = 0
        Hosting.handler = { _ in creations += 1; throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "connection lost"]) }
        do { try await HostingHubAPI.saveProjectDraft(gh, detail: project, title: "Draft", body: "Body"); fatalError("Uncertain draft accepted") } catch is HubUncertainWriteError {} catch { fatalError("Unexpected error type") }
        precondition(creations == 1)
        let iterationOnly = HubDetail(item: HubItem(id: "P", title: "Plan"), fields: [project.fields[3], project.fields[4]], rows: [project.rows[0]])
        precondition(HostingHubAPI.projectColumns(iterationOnly).map(\.id) == ["current", "previous"])
        Hosting.handler = { _ in try json(["errors": [["type": "INSUFFICIENT_SCOPES", "message": "id requires read:project"], ["message": "title requires read:project"]]]) }
        do { _ = try await HostingHubAPI.page(gh, section: .projects); fatalError("Missing scope accepted") }
        catch let error as HubProjectPermissionError { precondition(error.localizedDescription.contains("Connect project access") && !error.localizedDescription.contains("id requires")) }
        catch { fatalError("Scope recovery type missing") }
        Hosting.handler = { _ in try json(["errors": [["message": "unrelated internal exception"]]]) }
        do { _ = try await HostingHubAPI.page(gh, section: .projects); fatalError("GraphQL failure accepted") }
        catch is HubProjectPermissionError { fatalError("Unrelated error offered authorization") }
        catch { precondition(error.localizedDescription.contains("Projects could not be loaded") && !error.localizedDescription.contains("internal exception")) }
        var actionInputs = [[String: Any]](), actionQueries = [String]()
        Hosting.handler = { request in
            calls.append(request); let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any], query = body["query"] as! String, variables = body["variables"] as! [String: Any]; actionQueries.append(query)
            if query.hasPrefix("query") { precondition(variables["owner"] as? String == "team" && variables["name"] as? String == "repo"); return try json(["data": ["repository": ["id": "REPOSITORY", "nameWithOwner": "Team/Repo"]]]) }
            actionInputs.append(variables["input"] as! [String: Any]); return try json(["data": [:]])
        }
        try await HostingHubAPI.moveProjectItem(gh, detail: project, row: project.rows[0], afterRow: project.rows[1])
        precondition(actionInputs.last?["projectId"] as? String == "P" && actionInputs.last?["itemId"] as? String == "R" && actionInputs.last?["afterId"] as? String == "PR" && actionQueries.last!.contains("updateProjectV2ItemPosition"))
        try await HostingHubAPI.moveProjectItem(gh, detail: project, row: project.rows[0], afterRow: nil)
        precondition(actionInputs.last?["afterId"] is NSNull)
        let beforeInvalidPosition = calls.count
        do { try await HostingHubAPI.moveProjectItem(gh, detail: project, row: project.rows[0], afterRow: project.rows[0]); fatalError("Self anchor accepted") } catch {}
        do { try await HostingHubAPI.moveProjectItem(gh, detail: project, row: project.rows[0], afterRow: forgedRow); fatalError("Foreign anchor accepted") } catch {}
        do { try await HostingHubAPI.moveProjectItem(gh, detail: project, row: forgedRow, afterRow: nil); fatalError("Foreign item accepted") } catch {}
        do { try await HostingHubAPI.moveProjectItem(gl, detail: project, row: project.rows[0], afterRow: nil); fatalError("GitLab position accepted") } catch {}
        do { try await HostingHubAPI.moveProjectItem(stale, detail: project, row: project.rows[0], afterRow: nil); fatalError("Stale position accepted") } catch {}
        precondition(calls.count == beforeInvalidPosition)
        try await HostingHubAPI.convertProjectDraftToIssue(gh, detail: project, row: project.rows[2], repository: "  team/repo  ")
        precondition(actionQueries.last!.contains("convertProjectV2DraftIssueItemToIssue") && actionInputs.last?["itemId"] as? String == "draft" && actionInputs.last?["repositoryId"] as? String == "REPOSITORY" && actionInputs.last?["projectId"] == nil)
        let beforeInvalidRepository = calls.count
        for repository in ["", "repo", "team/repo/extra", "https://evil.test/team/repo", "team/..", "team/repo?token=x", "team/%2frepo"] {
            do { try await HostingHubAPI.convertProjectDraftToIssue(gh, detail: project, row: project.rows[2], repository: repository); fatalError("Malformed repository accepted") } catch { precondition(error.localizedDescription.contains("owner/name")) }
        }
        do { try await HostingHubAPI.convertProjectDraftToIssue(gh, detail: project, row: project.rows[0], repository: "team/repo"); fatalError("Issue converted as draft") } catch {}
        do { try await HostingHubAPI.convertProjectDraftToIssue(gh, detail: project, row: forgedRow, repository: "team/repo"); fatalError("Foreign draft accepted") } catch {}
        do { try await HostingHubAPI.convertProjectDraftToIssue(gl, detail: project, row: project.rows[2], repository: "team/repo"); fatalError("Cross-provider draft accepted") } catch {}
        precondition(calls.count == beforeInvalidRepository)
        for remote: Any in [NSNull(), ["id": "OTHER", "nameWithOwner": "other/repo"]] {
            Hosting.handler = { request in calls.append(request); return try json(["data": ["repository": remote]]) }
            do { try await HostingHubAPI.convertProjectDraftToIssue(gh, detail: project, row: project.rows[2], repository: "team/repo"); fatalError("Unavailable repository accepted") } catch { precondition(error.localizedDescription.contains("unavailable")) }
        }
        var conversionCurrent = true; var conversionAccess = gh; conversionAccess.isCurrent = { conversionCurrent }
        Hosting.handler = { request in calls.append(request); conversionCurrent = false; return try json(["data": ["repository": ["id": "REPOSITORY", "nameWithOwner": "team/repo"]]]) }
        do { try await HostingHubAPI.convertProjectDraftToIssue(conversionAccess, detail: project, row: project.rows[2], repository: "team/repo"); fatalError("Switched conversion accepted") } catch { precondition(error.localizedDescription.contains("account changed")) }
        precondition(calls.count == beforeInvalidRepository + 3)
        var conversionRequests = 0
        Hosting.handler = { request in
            conversionRequests += 1
            if conversionRequests == 1 { return try json(["data": ["repository": ["id": "REPOSITORY", "nameWithOwner": "team/repo"]]]) }
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "connection lost"])
        }
        do { try await HostingHubAPI.convertProjectDraftToIssue(gh, detail: project, row: project.rows[2], repository: "team/repo"); fatalError("Uncertain conversion accepted") } catch is HubUncertainWriteError {} catch { fatalError("Unexpected conversion error") }
        precondition(conversionRequests == 2)
        let secret = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture github_pat_abc token"])
        precondition(!HostingHubAPI.error(secret, token: "fixture").contains("fixture"))
        print("Hosting hub: organization avatars in lists and details, pagination, stale context, safe member profiles, batched profile enrichment and fallback, URL restrictions, gist conflict protection, GitLab drafts, GitLab group boards and complete board reads, snippet refs, status-board grouping, project scope recovery, typed fields, rich project rows, drafts, item actions, manual position and draft conversion passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-hub"
"$TASK_TMP/test-hub"
