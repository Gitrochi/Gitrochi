import Foundation

/// Organization reads and writes use the same account boundary as the hosting workspace.
@MainActor extension HostingHubAPI {
    static func organizationBase(_ c: HubAccess, item: HubItem) -> String {
        c.apiBase + (c.target.provider == .github ? "/orgs/" : "/groups/") + enc(item.id)
    }
    static func organizationAccess(_ c: HubAccess, item: HubItem) async throws -> HubOrganizationAccess {
        do {
            if c.target.provider == .github {
                let membership = try await object(c, c.apiBase + "/user/memberships/orgs/" + enc(item.id))
                let actor = s(obj(membership, "user"), "login")
                guard !actor.isEmpty, actor.caseInsensitiveCompare(c.me) == .orderedSame else { throw fail(String(localized: "The selected account does not match the server identity. Reconnect this account before managing access.")) }
                let active = s(membership, "state") == "active", owner = s(membership, "role") == "admin"
                return HubOrganizationAccess(role: active ? owner ? String(localized: "Owner") : String(localized: "Member") : String(localized: "Pending"), canInvite: active && owner)
            }
            let user = try await object(c, c.apiBase + "/user")
            guard !id(user).isEmpty, s(user, "username").caseInsensitiveCompare(c.me) == .orderedSame else { throw fail(String(localized: "The server returned an unexpected response.")) }
            let membership = try await object(c, organizationBase(c, item: item) + "/members/all/" + enc(id(user)))
            let active = (s(membership, "state").isEmpty || s(membership, "state") == "active") && (s(membership, "membership_state").isEmpty || s(membership, "membership_state") == "active")
            return HubOrganizationAccess(role: member(c, membership).role, canInvite: active && Int(id(membership, "access_level")) == 50)
        } catch {
            try check(c)
            return HubOrganizationAccess(role: String(localized: "Unknown"), notice: String(localized: "Organization permissions could not be verified. Check account access or open the organization in your browser."))
        }
    }
    static func organizationDetail(_ c: HubAccess, item: HubItem, page: Int, tab: String) async throws -> HubDetail {
        let x = try await object(c, organizationBase(c, item: item))
        var updated = organizationItem(c, x)
        if updated.id.isEmpty { updated.id = item.id }
        if s(x, "name").isEmpty { updated.title = item.title }
        if updated.subtitle.isEmpty { updated.subtitle = item.subtitle }
        if s(x, c.target.provider == .github ? "html_url" : "web_url").isEmpty { updated.url = item.url }
        if x["avatar_url"] == nil { updated.avatarURL = item.avatarURL }
        let access = try await organizationAccess(c, item: updated)
        var result = HubDetail(item: updated, organizationAccess: access)
        result.notice = access.notice
        let organization = updated
        if tab == "overview" {
            async let members = organizationSection(c, item: organization, access: access, section: "members", page: 0)
            async let teams = organizationSection(c, item: organization, access: access, section: "teams", page: 1)
            async let repositories = organizationSection(c, item: organization, access: access, section: "repositories", page: 0)
            async let invitations = organizationSection(c, item: organization, access: access, section: "invitations", page: 0)
            for page in try await [members, teams, repositories, invitations] {
                result.members += page.members; result.teams += page.teams; result.repositories += page.repositories; result.invitations += page.invitations
                result.organizationSections.merge(page.organizationSections) { _, fresh in fresh }
            }
            return result
        }
        let section = try await organizationSection(c, item: organization, access: access, section: tab, page: page)
        result.members = section.members; result.teams = section.teams; result.repositories = section.repositories; result.invitations = section.invitations
        result.organizationSections = section.organizationSections; result.more = section.more; result.notice = section.organizationSections[tab]?.error ?? result.notice
        return result
    }
    /// Preview pages stay bounded; full people lists restart at page one before appending further pages.
    static func organizationSection(_ c: HubAccess, item: HubItem, access: HubOrganizationAccess, section: String, page: Int) async throws -> HubDetail {
        let size = section == "teams" ? 6 : page == 0 ? section == "members" ? 12 : 6 : 30
        var result = HubDetail(item: item), state = HubOrganizationSectionState(page: page, loaded: true)
        if section == "invitations", !access.canInvite {
            state.error = String(localized: "Only organization owners with the required account access can manage invitations.")
            result.organizationSections[section] = state; return result
        }
        do {
            let github = c.target.provider == .github
            let route: String
            switch section {
            case "members": route = github ? "/members" : "/members/all"
            case "teams": route = github ? "/teams" : "/subgroups"
            case "repositories": route = github ? "/repos" : "/projects"
            case "invitations": route = "/invitations"
            default: throw fail(String(localized: "The server returned an unexpected response."))
            }
            let extra = section == "teams" && !github ? "&all_available=true" : section == "repositories" ? github ? "&sort=updated" : "&include_subgroups=true&order_by=last_activity_at" : ""
            let rawRows = try await list(c, organizationBase(c, item: item) + route + "?per_page=\(size)&page=\(max(1, page))" + extra)
            let rows = Array(rawRows.prefix(size))
            state.more = rawRows.count >= size; result.more = state.more
            switch section {
            case "members": result.members = try await members(c, rows: rows)
            case "repositories": result.repositories = rows.map { HubRepository(id: id($0), name: s($0, github ? "full_name" : "path_with_namespace"), description: s($0, "description"), cloneURL: s($0, github ? "clone_url" : "http_url_to_repo"), url: s($0, github ? "html_url" : "web_url")) }
            case "teams":
                for row in rows {
                    var team = HubOrganizationTeam(id: id(row), name: s(row, "name"), description: s(row, "description"), url: s(row, github ? "html_url" : "web_url"), privacy: s(row, github ? "privacy" : "visibility"), slug: s(row, "slug"))
                    team = try await organizationTeamMembers(c, item: item, team: team, page: 0)
                    result.teams.append(team)
                }
            default:
                result.invitations = rows.map { row in
                    let email = s(row, github ? "email" : "invite_email"), username = s(row, "login")
                    let role = github ? s(row, "role") == "admin" ? String(localized: "Owner") : s(row, "role") == "billing_manager" ? String(localized: "Billing manager") : String(localized: "Member") : member(c, row).role
                    return HubOrganizationInvitation(id: github ? id(row) : email, email: email.isEmpty ? username : email, role: role, createdAt: s(row, "created_at"), inviter: s(obj(row, "inviter"), github ? "login" : "username"))
                }
            }
        } catch {
            try check(c)
            state.error = String(localized: "This section could not be loaded. Check account permissions, retry, or open it in your browser.") + "\n" + Self.error(error, token: c.token)
        }
        result.organizationSections[section] = state
        return result
    }
    static func organizationTeamMembers(_ c: HubAccess, item: HubItem, team: HubOrganizationTeam, page: Int) async throws -> HubOrganizationTeam {
        var result = team
        result.memberState = HubOrganizationSectionState(page: page, loaded: true)
        do {
            let github = c.target.provider == .github
            guard !team.id.isEmpty, !github || !team.slug.isEmpty else { throw fail(String(localized: "The server returned an unexpected response.")) }
            let base = github ? organizationBase(c, item: item) + "/teams/" + enc(team.slug) + "/members" : c.apiBase + "/groups/" + enc(team.id) + "/members/all"
            let size = page == 0 ? 6 : 30
            let rawRows = try await list(c, base + "?per_page=\(size)&page=\(max(1, page))" + (github ? "&role=all" : ""))
            result.members = try await members(c, rows: Array(rawRows.prefix(size)))
            result.memberState.more = rawRows.count >= size
        } catch {
            try check(c)
            result.memberState.error = String(localized: "Team members could not be loaded. Retry here to see people in this team.") + "\n" + Self.error(error, token: c.token)
        }
        return result
    }
    static func organizationRoles(_ provider: Provider) -> [(String, String)] {
        provider == .github ? [("direct_member", String(localized: "Member")), ("admin", String(localized: "Owner")), ("billing_manager", String(localized: "Billing manager"))] : [("10", String(localized: "Guest")), ("15", String(localized: "Planner")), ("20", String(localized: "Reporter")), ("30", String(localized: "Developer")), ("40", String(localized: "Maintainer")), ("50", String(localized: "Owner"))]
    }
    static func validOrganizationEmail(_ value: String) -> Bool {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", omittingEmptySubsequences: false)
        return value.count <= 254 && parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".") && !value.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" })
    }
    @discardableResult
    static func inviteOrganizationMember(_ c: HubAccess, item: HubItem, email: String, role: String, expiresAt: String) async throws -> String? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines), date = expiresAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validOrganizationEmail(email), organizationRoles(c.target.provider).contains(where: { $0.0 == role }) else { throw fail(String(localized: "Enter a valid email address and invitation role.")) }
        if c.target.provider == .github, !date.isEmpty { throw fail(String(localized: "Expiration dates are only supported for GitLab invitations.")) }
        if !date.isEmpty {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date, Calendar.current.startOfDay(for: parsed) >= Calendar.current.startOfDay(for: Date()) else { throw fail(String(localized: "Enter an expiration date today or later in YYYY-MM-DD format.")) }
        }
        let permission = try await organizationAccess(c, item: item)
        guard permission.canInvite else { throw fail(String(localized: "Only organization owners with the required account access can manage invitations.")) }
        var body: J = ["email": email, c.target.provider == .github ? "role" : "access_level": c.target.provider == .github ? role : Int(role) as Any]
        if c.target.provider == .gitlab, !date.isEmpty { body["expires_at"] = date }
        do {
            let response = try await object(c, organizationBase(c, item: item) + "/invitations", method: "POST", body: body)
            if c.target.provider == .gitlab {
                if s(response, "status") == "error" { throw fail(String(localized: "The server rejected this invitation. Check the email, role, and group invitation policies.")) }
                if !obj(response, "queued_users").isEmpty { return String(localized: "The invitation is queued for administrator approval. Check pending invitations before trying again.") }
                guard s(response, "status") == "success" else { throw HubUncertainWriteError(message: String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
            }
            return nil
        } catch let error as HostingError where (400..<500).contains(error.status) { throw error }
        catch let error as HubUncertainWriteError { throw error }
        catch let error as NSError where error.domain == "HostingHub" { throw error }
        catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
    }
    static func cancelOrganizationInvitation(_ c: HubAccess, item: HubItem, invitation: HubOrganizationInvitation) async throws {
        let permission = try await organizationAccess(c, item: item)
        guard permission.canInvite, !invitation.id.isEmpty else { throw fail(String(localized: "Only organization owners with the required account access can manage invitations.")) }
        do { _ = try await value(c, organizationBase(c, item: item) + "/invitations/" + enc(invitation.id), method: "DELETE") }
        catch let error as HostingError where (400..<500).contains(error.status) { throw error }
        catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
    }
    static func organizationLinks(provider: Provider, host: String, item: HubItem) -> [HubOrganizationLink] {
        let github = provider == .github
        let path = github ? enc(item.id) : item.subtitle.split(separator: "/").map { enc(String($0)) }.joined(separator: "/")
        guard !path.isEmpty else { return [] }
        let base = "https://" + host
        let entries = github ? [
            (String(localized: "People"), "/orgs/" + path + "/people"), (String(localized: "Teams"), "/orgs/" + path + "/teams"),
            (String(localized: "Projects"), "/orgs/" + path + "/projects"), (String(localized: "Packages"), "/orgs/" + path + "/packages"),
            (String(localized: "Settings"), "/organizations/" + path + "/settings/profile"), (String(localized: "Security"), "/orgs/" + path + "/security"),
            (String(localized: "Audit log"), "/organizations/" + path + "/settings/audit-log"), (String(localized: "Billing"), "/organizations/" + path + "/settings/billing")
        ] : [
            (String(localized: "People"), "/groups/" + path + "/-/group_members"), (String(localized: "Subgroups"), "/groups/" + path + "/-/children"),
            (String(localized: "Issues"), "/groups/" + path + "/-/issues"), (String(localized: "Merge requests"), "/groups/" + path + "/-/merge_requests"),
            (String(localized: "Issue boards"), "/groups/" + path + "/-/boards"), (String(localized: "Packages"), "/groups/" + path + "/-/packages"),
            (String(localized: "Settings"), "/groups/" + path + "/-/edit"), (String(localized: "Security"), "/groups/" + path + "/-/security/dashboard"),
            (String(localized: "Audit log"), "/groups/" + path + "/-/audit_events")
        ]
        return entries.compactMap { title, route in guard let url = safeURL(provider: provider, host: host, base + route) else { return nil }; return HubOrganizationLink(title: title, url: url.absoluteString) }
    }
}
