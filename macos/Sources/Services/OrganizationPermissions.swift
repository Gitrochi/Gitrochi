import Foundation

/// A reviewed permission snapshot is bound to one existing person and organization scope.
struct HubOrganizationPermission: Equatable {
    var organizationID: String
    var teamID = ""
    var userID: String
    var username: String
    var role: String
    var active: Bool
    var inherited = false
    var exists = true
    var hasDirect = true
    var customRole = false
}

@MainActor extension HostingHubAPI {
    static func organizationPermissionRoles(_ provider: Provider, team: Bool) -> [(String, String)] {
        if provider == .github { return team ? [("member", String(localized: "Member")), ("maintainer", String(localized: "Maintainer"))] : [("member", String(localized: "Member")), ("admin", String(localized: "Owner"))] }
        return organizationRoles(provider)
    }
    static func organizationRoleMeaning(_ provider: Provider, role: String, team: Bool = false) -> String {
        if provider == .github {
            if role == "admin" { return String(localized: "Owners can manage people, teams, organization settings, and billing.") }
            if role == "maintainer" { return String(localized: "Team maintainers can manage this team's membership and settings.") }
            if role == "billing_manager" { return String(localized: "Billing managers can manage billing but do not receive repository access.") }
            return team ? String(localized: "Team members receive the repository access granted to this team.") : String(localized: "Members receive the organization's base permissions and access granted through teams.")
        }
        switch role {
        case "10": return String(localized: "Guests can participate in issues and discussions, with limited code access.")
        case "15": return String(localized: "Planners can organize issues, milestones, and planning work.")
        case "20": return String(localized: "Reporters can read code and review project information.")
        case "30": return String(localized: "Developers can contribute code and work with merge requests.")
        case "40": return String(localized: "Maintainers can manage project settings and development workflows.")
        case "50": return String(localized: "Owners can manage this group, its members, and group settings.")
        default: return ""
        }
    }
    static func organizationPermissionTitle(_ provider: Provider, role: String, team: Bool = false) -> String {
        if role.isEmpty { return String(localized: "No direct access") }
        return organizationPermissionRoles(provider, team: team).first { $0.0 == role }?.1 ?? String(localized: "Unknown")
    }
    static func organizationPerson(_ c: HubAccess, username: String, userID: String = "") async throws -> J {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !username.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else { throw fail(String(localized: "Enter an existing member's username.")) }
        if c.target.provider == .github { return ["login": username, "id": userID] }
        let person: J
        if !userID.isEmpty { person = try await object(c, c.apiBase + "/users/" + enc(userID)) }
        else {
            let matches = try await list(c, c.apiBase + "/users?username=" + enc(username) + "&per_page=100")
            guard let match = matches.first(where: { s($0, "username").caseInsensitiveCompare(username) == .orderedSame }) else { throw fail(String(localized: "This person is not an active member of the organization.")) }
            person = match
        }
        guard !id(person).isEmpty, s(person, "username").caseInsensitiveCompare(username) == .orderedSame else { throw fail(String(localized: "This member changed on the server. Refresh before editing access.")) }
        return person
    }
    static func organizationMemberPermission(_ c: HubAccess, item: HubItem, username: String, userID: String = "", team: HubOrganizationTeam? = nil) async throws -> HubOrganizationPermission {
        try check(c)
        let person = try await organizationPerson(c, username: username, userID: userID)
        let username = s(person, c.target.provider == .github ? "login" : "username")
        if c.target.provider == .github {
            let route = team.map { "/teams/" + enc($0.slug) + "/memberships/" } ?? "/memberships/"
            if let team {
                guard !team.id.isEmpty, !team.slug.isEmpty else { throw fail(String(localized: "The server returned an unexpected response.")) }
                let identity = try await object(c, organizationBase(c, item: item) + "/teams/" + enc(team.slug))
                guard id(identity) == team.id, s(identity, "slug").isEmpty || s(identity, "slug") == team.slug else { throw fail(String(localized: "This team changed on the server. Refresh before editing access.")) }
            }
            do {
                let x = try await object(c, organizationBase(c, item: item) + route + enc(username))
                let user = obj(x, "user"), returned = s(user, "login")
                if team == nil { guard returned.caseInsensitiveCompare(username) == .orderedSame, !id(user).isEmpty, userID.isEmpty || id(user) == userID else { throw fail(String(localized: "This member changed on the server. Refresh before editing access.")) } }
                return HubOrganizationPermission(organizationID: item.id, teamID: team?.id ?? "", userID: team == nil ? id(user) : userID, username: username, role: s(x, "role"), active: s(x, "state") == "active", inherited: x["inherited"] as? Bool == true)
            } catch let error as HostingError where error.status == 404 {
                return HubOrganizationPermission(organizationID: item.id, teamID: team?.id ?? "", userID: userID, username: username, role: "", active: false, exists: false, hasDirect: false)
            }
        }
        let scopeID = team?.id ?? item.id, base = c.apiBase + "/groups/" + enc(scopeID), personID = id(person)
        let effective: J
        do { effective = try await object(c, base + "/members/all/" + enc(personID)) }
        catch let error as HostingError where error.status == 404 { return HubOrganizationPermission(organizationID: item.id, teamID: team?.id ?? "", userID: personID, username: username, role: "", active: false, exists: false, hasDirect: false) }
        guard id(effective) == personID, s(effective, "username").caseInsensitiveCompare(username) == .orderedSame else { throw fail(String(localized: "This member changed on the server. Refresh before editing access.")) }
        let effectiveRole = id(effective, "access_level")
        let direct: J?
        do { direct = try await object(c, base + "/members/" + enc(personID)) }
        catch let error as HostingError where error.status == 404 { direct = nil }
        if let direct { guard id(direct) == personID, s(direct, "username").caseInsensitiveCompare(username) == .orderedSame else { throw fail(String(localized: "This member changed on the server. Refresh before editing access.")) } }
        let inherited = direct == nil || (Int(effectiveRole) ?? 0) > (Int(id(direct ?? [:], "access_level")) ?? 0)
        let active = (s(effective, "state").isEmpty || s(effective, "state") == "active") && (s(effective, "membership_state").isEmpty || s(effective, "membership_state") == "active")
        return HubOrganizationPermission(organizationID: item.id, teamID: team?.id ?? "", userID: personID, username: username, role: effectiveRole, active: active, inherited: inherited, hasDirect: direct != nil, customRole: !id(direct ?? [:], "member_role_id").isEmpty || !id(obj(direct ?? [:], "member_role")).isEmpty)
    }
    static func organizationPermissionReason(_ c: HubAccess, permission: HubOrganizationPermission, assigning: Bool = false) -> String? {
        if permission.username.caseInsensitiveCompare(c.me) == .orderedSame { return String(localized: "Your own access cannot be changed here. Ask another organization owner to review it.") }
        if permission.customRole { return String(localized: "This member has a custom role. Manage it in the provider to preserve its permissions.") }
        if permission.inherited && !(assigning && !permission.hasDirect) { return String(localized: "This access is inherited from a parent group or shared membership. Change it at its source.") }
        if !permission.active && !(assigning && !permission.exists) { return String(localized: "This person is not an active member of the organization.") }
        return nil
    }
    @discardableResult
    static func saveOrganizationPermission(_ c: HubAccess, item: HubItem, previous: HubOrganizationPermission, role: String, team: HubOrganizationTeam? = nil, allowAssignment: Bool = false) async throws -> String? {
        guard previous.organizationID == item.id, previous.teamID == (team?.id ?? ""), organizationPermissionRoles(c.target.provider, team: team != nil).contains(where: { $0.0 == role }) else { throw fail(String(localized: "Choose a valid access role.")) }
        let actor = try await organizationAccess(c, item: item)
        guard actor.canInvite else { throw fail(String(localized: "Only organization owners with the required account access can manage permissions.")) }
        if c.target.provider == .gitlab, let team {
            let subgroup = try await object(c, c.apiBase + "/groups/" + enc(team.id))
            guard id(subgroup, "parent_id") == item.id else { throw fail(String(localized: "This subgroup changed on the server. Refresh the organization before editing access.")) }
            let subgroupOwner = try await organizationAccess(c, item: HubItem(id: team.id, title: team.name))
            guard subgroupOwner.canInvite else { throw fail(String(localized: "Only organization owners with the required account access can manage permissions.")) }
        }
        let organizationPerson = try await organizationMemberPermission(c, item: item, username: previous.username, userID: previous.userID)
        guard organizationPerson.active, organizationPerson.exists else { throw fail(String(localized: "This person is not an active member of the organization.")) }
        if c.target.provider == .gitlab, team != nil, (Int(role) ?? 0) < (Int(organizationPerson.role) ?? 0) { throw fail(String(localized: "Choose a role at least as high as this person's inherited parent-group access.")) }
        let fresh = team == nil ? organizationPerson : try await organizationMemberPermission(c, item: item, username: previous.username, userID: organizationPerson.userID, team: team)
        guard fresh == previous else { throw fail(String(localized: "This member changed on the server. Refresh before editing access.")) }
        if let reason = organizationPermissionReason(c, permission: fresh, assigning: allowAssignment && team != nil) { throw fail(reason) }
        if team != nil && !fresh.hasDirect {
            guard allowAssignment else { throw fail(String(localized: "This access is inherited from a parent group or shared membership. Change it at its source.")) }
            if c.target.provider == .gitlab, fresh.exists, (Int(role) ?? 0) <= (Int(fresh.role) ?? 0) { throw fail(String(localized: "Choose a direct role higher than the inherited access. Inherited permissions stay unchanged.")) }
        }
        let github = c.target.provider == .github
        let base: String
        if let team {
            if github { base = organizationBase(c, item: item) + "/teams/" + enc(team.slug) + "/memberships/" + enc(fresh.username) }
            else { base = c.apiBase + "/groups/" + enc(team.id) + "/members" }
        } else {
            base = organizationBase(c, item: item) + (github ? "/memberships/" + enc(fresh.username) : "/members")
        }
        let adding = team != nil && !fresh.hasDirect
        let endpoint = github || adding ? base : base + "/" + enc(fresh.userID)
        var body: J = [github ? "role" : "access_level": github ? role : Int(role) as Any]
        if !github && adding { body["user_id"] = Int(fresh.userID) }
        do {
            let response = try await object(c, endpoint, method: !github && adding ? "POST" : "PUT", body: body)
            if s(response, "status") == "error" { throw fail(String(localized: "The server rejected this access change. Check organization policies and account permissions.")) }
            if !obj(response, "queued_users").isEmpty || obj(response, "message").values.contains(where: { ($0 as? String)?.localizedCaseInsensitiveContains("queued") == true }) || s(response, "membership_state") == "awaiting" { return String(localized: "The access change is queued for administrator approval. Refresh before making another change.") }
            let savedRole = github ? s(response, "role") : id(response, "access_level")
            let returnedUser = obj(response, "user")
            let verifiedGithub = s(response, "state") == "active" && (team != nil || id(returnedUser) == fresh.userID && s(returnedUser, "login").caseInsensitiveCompare(fresh.username) == .orderedSame)
            guard savedRole == role, github ? verifiedGithub : id(response) == fresh.userID else { throw HubUncertainWriteError(message: String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
            return nil
        } catch let error as HostingError where (400..<500).contains(error.status) { throw error }
        catch let error as HubUncertainWriteError { throw error }
        catch let error as NSError where error.domain == "HostingHub" { throw error }
        catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
    }
}
