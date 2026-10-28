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
@main struct OrganizationTests {
    @MainActor static func main() async throws {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let gh = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/repo"), token: "fixture", apiBase: "https://api.github.com", me: "me")
        let gl = HubAccess(target: RepoTarget(provider: .gitlab, remote: "origin", host: "gitlab.test", path: "team/repo"), token: "fixture", apiBase: "https://gitlab.test/api/v4", me: "me")
        let org = HubItem(id: "team", title: "Team", subtitle: "team", url: "https://github.com/team")
        let group = HubItem(id: "9", title: "Design", subtitle: "team/design", url: "https://gitlab.test/team/design")
        var writes = [URLRequest](), owner = true
        Hosting.handler = { request in
            let path = request.url!.path
            if path == "/orgs/team" { return try json(["login": "team", "name": "Team", "public_repos": 4]) }
            if path == "/user/memberships/orgs/team" { return try json(["role": owner ? "admin" : "member", "state": "active"]) }
            if path == "/orgs/team/teams" { return try json((0..<6).map { ["id": $0, "slug": "team-\($0)", "name": "Team \($0)", "html_url": "https://github.com/orgs/team/teams/demo"] }) }
            if path == "/orgs/team/members" || path.hasPrefix("/orgs/team/teams/") && path.hasSuffix("/members") { return try json([["id": 7, "login": "developer", "name": "Demo developer"]]) }
            if path == "/orgs/team/repos" { return try json([["id": 12, "full_name": "team/app", "html_url": "https://github.com/team/app"]]) }
            if path == "/graphql" { return try json(["data": [:]]) }
            if request.httpMethod == "POST" || request.httpMethod == "DELETE" { writes.append(request); return try json(["id": 3]) }
            if path == "/orgs/team/invitations" { return try json([["id": 3, "email": "member@example.com", "role": "direct_member"]]) }
            fatalError("Unexpected request \(request)")
        }
        let overview = try await HostingHubAPI.detail(gh, section: .organizations, item: org, tab: "overview")
        precondition(overview.organizationAccess?.canInvite == true && overview.item.data["public_repos"] as? Int == 4 && overview.members.first?.username == "developer" && overview.teams.first?.members.first?.name == "Demo developer" && overview.repositories.count == 1 && overview.invitations.count == 1)
        let initialHandler = Hosting.handler
        Hosting.handler = { request in
            if request.url!.path == "/orgs/team/invitations" { throw HostingError(status: 403) }
            if request.url!.path == "/orgs/team/teams/team-0/members" { throw HostingError(status: 403) }
            return try initialHandler(request)
        }
        let partial = try await HostingHubAPI.detail(gh, section: .organizations, item: org, tab: "overview")
        precondition(partial.members.count == 1 && partial.repositories.count == 1 && partial.teams.count == 6 && partial.teams[0].memberState.error != nil && partial.teams[1].members.count == 1 && partial.organizationSections["invitations"]?.error != nil, "A failed invitation or team request hid visible people")
        var teamMemberReads = 0
        Hosting.handler = { request in
            if request.url!.path == "/orgs/team/teams" { return try json((0..<50).map { ["id": $0, "slug": "team-\($0)", "name": "Team \($0)"] }) }
            if request.url!.path.hasPrefix("/orgs/team/teams/") && request.url!.path.hasSuffix("/members") { teamMemberReads += 1 }
            return try initialHandler(request)
        }
        let bounded = try await HostingHubAPI.detail(gh, section: .organizations, item: org, tab: "overview")
        precondition(bounded.teams.count == 6 && teamMemberReads == 6 && bounded.organizationSections["teams"]?.more == true, "A server page expanded eager work beyond the team preview bound")
        Hosting.handler = initialHandler
        let teams = try await HostingHubAPI.detail(gh, section: .organizations, item: org, page: 2, tab: "teams")
        precondition(teams.teams.count == 6 && teams.more)
        let invitations = try await HostingHubAPI.detail(gh, section: .organizations, item: org, tab: "invitations")
        precondition(invitations.invitations.first?.email == "member@example.com")
        try await HostingHubAPI.inviteOrganizationMember(gh, item: org, email: "member@example.com", role: "direct_member", expiresAt: "")
        let body = try JSONSerialization.jsonObject(with: writes[0].httpBody!) as! [String: Any]
        precondition(body["email"] as? String == "member@example.com" && body["role"] as? String == "direct_member")
        try await HostingHubAPI.cancelOrganizationInvitation(gh, item: org, invitation: invitations.invitations[0])
        precondition(writes.last?.url?.path == "/orgs/team/invitations/3" && writes.last?.httpMethod == "DELETE")
        owner = false
        do { try await HostingHubAPI.inviteOrganizationMember(gh, item: org, email: "member@example.com", role: "admin", expiresAt: ""); fatalError("Nonowner invite accepted") } catch {}
        precondition(writes.count == 2)
        Hosting.handler = { request in
            if request.url!.path == "/orgs/team" { return try json(["login": "team", "name": "Team"]) }
            throw HostingError(status: 403)
        }
        let denied = try await HostingHubAPI.detail(gh, section: .organizations, item: org, tab: "overview")
        precondition(denied.item.title == "Team" && denied.organizationAccess?.canInvite == false && denied.notice != nil)
        var gitlabResponse: [String: Any] = ["status": "success"], gitlabWrites = [URLRequest]()
        Hosting.handler = { request in
            let path = request.url!.path
            if path == "/api/v4/user" { return try json(["id": 7, "username": "me"]) }
            if path == "/api/v4/groups/9/members/all/7" { return try json(["id": 7, "username": "me", "access_level": 50]) }
            if path == "/api/v4/groups/9" { return try json(["id": 9, "name": "Design", "full_path": "team/design"]) }
            if request.httpMethod == "POST" || request.httpMethod == "DELETE" { gitlabWrites.append(request); return try json(gitlabResponse) }
            if path == "/api/v4/groups/9/invitations" { return try json([["invite_email": "member+test@example.com", "access_level": 30]]) }
            if path == "/api/v4/groups/11/members/all" { return try json([["id": 8, "username": "designer", "name": "Demo designer", "access_level": 30]]) }
            if path == "/api/v4/groups/9/subgroups" { precondition(request.url!.query!.contains("all_available=true")); return try json([["id": 11, "name": "Backend", "web_url": "https://gitlab.test/team/design/backend"]]) }
            fatalError("Unexpected request \(request)")
        }
        let pending = try await HostingHubAPI.detail(gl, section: .organizations, item: group, tab: "invitations")
        precondition(pending.organizationAccess?.role == "Owner" && pending.invitations.first?.id == "member+test@example.com")
        let subgroups = try await HostingHubAPI.detail(gl, section: .organizations, item: group, tab: "teams")
        precondition(subgroups.teams.first?.name == "Backend")
        try await HostingHubAPI.inviteOrganizationMember(gl, item: group, email: "member@example.com", role: "30", expiresAt: "2099-12-31")
        let gitlabBody = try JSONSerialization.jsonObject(with: gitlabWrites[0].httpBody!) as! [String: Any]
        precondition(gitlabBody["access_level"] as? Int == 30 && gitlabBody["expires_at"] as? String == "2099-12-31")
        try await HostingHubAPI.cancelOrganizationInvitation(gl, item: group, invitation: pending.invitations[0])
        precondition(gitlabWrites.last?.url?.absoluteString.hasSuffix("member%2Btest%40example.com") == true)
        gitlabResponse = ["status": "error", "message": ["member@example.com": "Rejected"]]
        do { try await HostingHubAPI.inviteOrganizationMember(gl, item: group, email: "member@example.com", role: "30", expiresAt: ""); fatalError("Rejected invitation accepted") } catch is HubUncertainWriteError { fatalError("Definite rejection treated as uncertain") } catch {}
        gitlabResponse = ["status": "success", "queued_users": ["member@example.com": "Approval pending"]]
        let queued = try await HostingHubAPI.inviteOrganizationMember(gl, item: group, email: "member@example.com", role: "30", expiresAt: "")
        precondition(queued?.contains("administrator approval") == true)
        let before = gitlabWrites.count
        do { try await HostingHubAPI.inviteOrganizationMember(gl, item: group, email: "member@example.com", role: "30", expiresAt: "2099-02-30"); fatalError("Invalid expiration accepted") } catch {}
        do { try await HostingHubAPI.inviteOrganizationMember(gl, item: group, email: "member@example.com,other@example.com", role: "30", expiresAt: ""); fatalError("Batch email accepted") } catch {}
        var stale = gl; stale.isCurrent = { false }
        do { try await HostingHubAPI.inviteOrganizationMember(stale, item: group, email: "member@example.com", role: "30", expiresAt: ""); fatalError("Stale invitation accepted") } catch {}
        precondition(gitlabWrites.count == before)
        Hosting.handler = { request in
            if request.url!.path == "/user/orgs" { return try json([]) }
            precondition(request.url!.path == "/user/memberships/orgs" && request.url!.query!.contains("state=active"))
            return try json((0..<30).map { ["organization": ["login": "team\($0)"]] })
        }
        let membershipsPage = try await HostingHubAPI.page(gh, section: .organizations)
        precondition(membershipsPage.items.count == 30 && membershipsPage.cursor == "organizationMemberships" && membershipsPage.more)
        let membershipsNext = try await HostingHubAPI.page(gh, section: .organizations, page: 2, cursor: membershipsPage.cursor)
        precondition(membershipsNext.items.count == 30)
        Hosting.handler = { request in if request.url!.path == "/user/orgs" { return try json([]) }; throw HostingError(status: 403) }
        let emptyOrganizations = try await HostingHubAPI.page(gh, section: .organizations)
        precondition(emptyOrganizations.items.isEmpty && !emptyOrganizations.more)
        let links = HostingHubAPI.organizationLinks(provider: .gitlab, host: "gitlab.test", item: group)
        precondition(links.contains { $0.url == "https://gitlab.test/groups/team/design/-/group_members" })
        precondition(HostingHubAPI.organizationLinks(provider: .github, host: "github.com", item: org).contains { $0.title == "Audit log" })
        print("Organizations: populated people/team/repository/invitation overview, bounded team people previews, independent failures, owner permissions, teams/subgroups, invitation pagination, request payloads, cancellation encoding, server rejections, queued approval, expiration and stale-context guards passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-organizations"
"$TASK_TMP/test-organizations"
