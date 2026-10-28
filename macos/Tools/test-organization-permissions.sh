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
@main struct PermissionTests {
    @MainActor static func main() async throws {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let gh = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/app"), token: "fixture", apiBase: "https://api.github.com", me: "me")
        let gl = HubAccess(target: RepoTarget(provider: .gitlab, remote: "origin", host: "gitlab.test", path: "team/app"), token: "fixture", apiBase: "https://gitlab.test/api/v4", me: "me")
        let org = HubItem(id: "team", title: "Team"), group = HubItem(id: "9", title: "Team", subtitle: "team")
        let team = HubOrganizationTeam(id: "2", name: "Platform", description: "", url: "", privacy: "closed", slug: "platform")
        let subgroup = HubOrganizationTeam(id: "11", name: "Platform", description: "", url: "", privacy: "private")
        var actor = "me", targetState = "active", targetRole = "member", targetExists = true, teamExists = false, responsePending = false, wrongResponseUser = false
        var actualTeamID = 2
        var writes = [URLRequest]()
        Hosting.handler = { request in
            let path = request.url!.path.lowercased()
            if request.httpMethod == "PUT" {
                writes.append(request)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                var value: [String: Any] = ["state": responsePending ? "pending" : "active", "role": body["role"]!]
                if !path.contains("/teams/") { value["user"] = ["id": wrongResponseUser ? 99 : 7, "login": "alex"] }
                return try json(value)
            }
            if path == "/user/memberships/orgs/team" { return try json(["role": "admin", "state": "active", "user": ["login": actor]]) }
            if path == "/orgs/team/memberships/alex" {
                if !targetExists { throw HostingError(status: 404) }
                return try json(["role": targetRole, "state": targetState, "user": ["id": 7, "login": "alex"]])
            }
            if path == "/orgs/team/memberships/me" { return try json(["role": "admin", "state": "active", "user": ["id": 1, "login": "me"]]) }
            if path == "/orgs/team/teams/platform" { return try json(["id": actualTeamID, "slug": "platform"]) }
            if path == "/orgs/team/teams/platform/memberships/alex" {
                if !teamExists { throw HostingError(status: 404) }
                return try json(["role": "member", "state": "active"])
            }
            fatalError("Unexpected permission request \(request)")
        }
        let member = try await HostingHubAPI.organizationMemberPermission(gh, item: org, username: "alex", userID: "7")
        try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: member, role: "admin")
        precondition(writes.count == 1 && writes[0].url!.path == "/orgs/team/memberships/alex")
        let before = writes.count
        for denied in ["actor", "pending", "absent", "stale"] {
            actor = denied == "actor" ? "wrong-account" : "me"; targetState = denied == "pending" ? "pending" : "active"; targetExists = denied != "absent"; targetRole = denied == "stale" ? "admin" : "member"
            do { try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: member, role: "admin"); fatalError("Unsafe org upsert accepted") } catch {}
        }
        precondition(writes.count == before)
        actor = "me"; targetState = "active"; targetRole = "member"; targetExists = true
        let selfRole = try await HostingHubAPI.organizationMemberPermission(gh, item: org, username: "ME", userID: "1")
        do { try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: selfRole, role: "member"); fatalError("Self demotion accepted") } catch {}
        let absentTeam = try await HostingHubAPI.organizationMemberPermission(gh, item: org, username: "alex", userID: "7", team: team)
        try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: absentTeam, role: "maintainer", team: team, allowAssignment: true)
        precondition(writes.last!.url!.path == "/orgs/team/teams/platform/memberships/alex")
        let afterTeam = writes.count
        actualTeamID = 99
        do { try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: absentTeam, role: "member", team: team, allowAssignment: true); fatalError("A reused team slug received an access grant") } catch {}
        precondition(writes.count == afterTeam, "A changed team identity reached a permission write")
        actualTeamID = 2
        targetExists = false
        do { try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: absentTeam, role: "member", team: team, allowAssignment: true); fatalError("Team assignment invited a nonmember") } catch {}
        precondition(writes.count == afterTeam)
        targetExists = true; responsePending = true
        do { try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: member, role: "admin"); fatalError("Pending upsert reported granted") } catch is HubUncertainWriteError {}
        responsePending = false; wrongResponseUser = true
        do { try await HostingHubAPI.saveOrganizationPermission(gh, item: org, previous: member, role: "admin"); fatalError("Wrong response person reported granted") } catch is HubUncertainWriteError {}
        var stale = gh; stale.isCurrent = { false }
        let beforeStale = writes.count
        do { try await HostingHubAPI.saveOrganizationPermission(stale, item: org, previous: member, role: "admin"); fatalError("Stale permission accepted") } catch {}
        precondition(writes.count == beforeStale)

        var direct = true, custom = false, subgroupDirect = false, queue = false, subgroupOwner = true, parentID = 9
        var gitlabWrites = [URLRequest]()
        Hosting.handler = { request in
            let path = request.url!.path.lowercased()
            if request.httpMethod == "PUT" || request.httpMethod == "POST" {
                gitlabWrites.append(request)
                if queue { return try json(["message": ["alex": "Request queued for administrator approval."]]) }
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                return try json(["id": 7, "username": "alex", "access_level": body["access_level"]!, "state": "active"])
            }
            if path == "/api/v4/user" { return try json(["id": 1, "username": "me"]) }
            if path == "/api/v4/users/7" { return try json(["id": 7, "username": "alex", "state": "active"]) }
            if path == "/api/v4/groups/9/members/all/1" { return try json(["id": 1, "username": "me", "access_level": 50, "state": "active"]) }
            if path == "/api/v4/groups/11/members/all/1" { return try json(["id": 1, "username": "me", "access_level": subgroupOwner ? 50 : 30, "state": "active"]) }
            if path == "/api/v4/groups/11" { return try json(["id": 11, "parent_id": parentID, "full_path": "team/platform"]) }
            if path.hasSuffix("/members/all/7") { return try json(["id": 7, "username": "alex", "access_level": 30, "state": "active"]) }
            if path.hasSuffix("/members/7") {
                if path.contains("/groups/9/") ? !direct : !subgroupDirect { throw HostingError(status: 404) }
                var value: [String: Any] = ["id": 7, "username": "alex", "access_level": 30, "state": "active"]
                if custom { value["member_role_id"] = 99 }
                return try json(value)
            }
            fatalError("Unexpected GitLab request \(request)")
        }
        let existing = try await HostingHubAPI.organizationMemberPermission(gl, item: group, username: "alex", userID: "7")
        try await HostingHubAPI.saveOrganizationPermission(gl, item: group, previous: existing, role: "40")
        precondition(gitlabWrites.last?.httpMethod == "PUT" && gitlabWrites.last?.url?.path == "/api/v4/groups/9/members/7")
        direct = false
        let inherited = try await HostingHubAPI.organizationMemberPermission(gl, item: group, username: "alex", userID: "7")
        let inheritedBefore = gitlabWrites.count
        do { try await HostingHubAPI.saveOrganizationPermission(gl, item: group, previous: inherited, role: "40"); fatalError("Inherited org role edited") } catch {}
        precondition(gitlabWrites.count == inheritedBefore)
        direct = true; custom = true
        let customRole = try await HostingHubAPI.organizationMemberPermission(gl, item: group, username: "alex", userID: "7")
        do { try await HostingHubAPI.saveOrganizationPermission(gl, item: group, previous: customRole, role: "40"); fatalError("Custom role removed") } catch {}
        precondition(gitlabWrites.count == inheritedBefore)
        custom = false
        let inheritedTeam = try await HostingHubAPI.organizationMemberPermission(gl, item: group, username: "alex", userID: "7", team: subgroup)
        precondition(inheritedTeam.inherited && !inheritedTeam.hasDirect)
        try await HostingHubAPI.saveOrganizationPermission(gl, item: group, previous: inheritedTeam, role: "40", team: subgroup, allowAssignment: true)
        let grant = gitlabWrites.last!, grantBody = try JSONSerialization.jsonObject(with: grant.httpBody!) as! [String: Any]
        precondition(grant.httpMethod == "POST" && grant.url!.path == "/api/v4/groups/11/members" && grantBody["user_id"] as? Int == 7 && grantBody["access_level"] as? Int == 40)
        let grantsBefore = gitlabWrites.count
        for denied in ["lower", "equal", "owner", "parent"] {
            subgroupOwner = denied != "owner"; parentID = denied == "parent" ? 99 : 9
            let role = denied == "lower" ? "20" : denied == "equal" ? "30" : "40"
            do { try await HostingHubAPI.saveOrganizationPermission(gl, item: group, previous: inheritedTeam, role: role, team: subgroup, allowAssignment: true); fatalError("Invalid inherited grant accepted") } catch {}
        }
        precondition(gitlabWrites.count == grantsBefore)
        subgroupOwner = true; parentID = 9; queue = true
        let queued = try await HostingHubAPI.saveOrganizationPermission(gl, item: group, previous: inheritedTeam, role: "40", team: subgroup, allowAssignment: true)
        precondition(queued?.contains("administrator approval") == true)
        print("Organization permissions: fresh actor/target identity, no invitation upsert, owner and self guards, stale role rejection, active response verification, exact team identity and slug-reuse guard, team assignment, direct/inherited/custom GitLab roles, subgroup parent/owner/floor checks and queued promotion notice passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-organization-permissions"
"$TASK_TMP/test-organization-permissions"
