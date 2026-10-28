import Foundation

extension RepoStore {
    /// Dashboard sections append independently without changing the selected organization or tab.
    func loadOrganizationSection(_ section: String) async {
        guard hostingHub.section == .organizations, !hostingHub.busy, !hostingHub.detailLoading, var detail = hostingHub.detail else { return }
        var state = detail.organizationSections[section] ?? HubOrganizationSectionState()
        guard !state.loading, !state.loaded || state.more || state.error != nil else { return }
        let page = state.loaded && state.error == nil ? state.page + 1 : state.page
        let item = detail.item, generation = hostingHub.generation, detailID = hostingHub.detailID, stamp = hubContextStamp
        hostingHub.organizationReadRevision = UUID()
        state.loading = true; state.error = nil; detail.organizationSections[section] = state; hostingHub.detail = detail
        let current = { self.hostingHub.generation == generation && self.hostingHub.detailID == detailID && self.hubContextStamp == stamp && self.hostingHub.detail?.item.id == item.id }
        var access: HubAccess?
        do {
            var c = try await hubAccess(); let previous = c.isCurrent; c.isCurrent = { previous?() != false && current() }; access = c
            let permission = section == "invitations" ? try await HostingHubAPI.organizationAccess(c, item: item) : detail.organizationAccess ?? HubOrganizationAccess()
            let result = try await HostingHubAPI.organizationSection(c, item: item, access: permission, section: section, page: page)
            guard current(), c.isCurrent?() != false, var latest = hostingHub.detail else { return }
            latest.members += result.members.filter { row in !latest.members.contains(where: { $0.id == row.id }) }
            latest.repositories += result.repositories.filter { row in !latest.repositories.contains(where: { $0.id == row.id }) }
            latest.teams += result.teams.filter { row in !latest.teams.contains(where: { $0.id == row.id }) }
            latest.invitations += result.invitations.filter { row in !latest.invitations.contains(where: { $0.id == row.id }) }
            latest.organizationSections[section] = result.organizationSections[section]
            hostingHub.detail = latest
        } catch {
            guard current(), var latest = hostingHub.detail else { return }
            var failed = latest.organizationSections[section] ?? state; failed.loading = false; failed.error = HostingHubAPI.error(error, token: access?.token)
            latest.organizationSections[section] = failed; hostingHub.detail = latest
        }
    }
    /// Each team keeps its own page and captured context so a slow result cannot replace another organization.
    func loadOrganizationTeamMembers(_ teamID: String) async {
        guard hostingHub.section == .organizations, !hostingHub.busy, !hostingHub.detailLoading, var detail = hostingHub.detail, let index = detail.teams.firstIndex(where: { $0.id == teamID }) else { return }
        let team = detail.teams[index], state = team.memberState
        guard !state.loading, !state.loaded || state.more || state.error != nil else { return }
        let page = state.loaded && state.error == nil ? state.page + 1 : state.page
        let item = detail.item, generation = hostingHub.generation, detailID = hostingHub.detailID, stamp = hubContextStamp
        hostingHub.organizationReadRevision = UUID()
        detail.teams[index].memberState.loading = true; detail.teams[index].memberState.error = nil; hostingHub.detail = detail
        let current = { self.hostingHub.generation == generation && self.hostingHub.detailID == detailID && self.hubContextStamp == stamp && self.hostingHub.detail?.item.id == item.id }
        var access: HubAccess?
        do {
            var c = try await hubAccess(); let previous = c.isCurrent; c.isCurrent = { previous?() != false && current() }; access = c
            let result = try await HostingHubAPI.organizationTeamMembers(c, item: item, team: team, page: page)
            guard current(), c.isCurrent?() != false, var latest = hostingHub.detail, let index = latest.teams.firstIndex(where: { $0.id == teamID }) else { return }
            latest.teams[index].members += result.members.filter { row in !latest.teams[index].members.contains(where: { $0.id == row.id }) }
            latest.teams[index].memberState = result.memberState; hostingHub.detail = latest
        } catch {
            guard current(), var latest = hostingHub.detail, let index = latest.teams.firstIndex(where: { $0.id == teamID }) else { return }
            latest.teams[index].memberState.loading = false; latest.teams[index].memberState.error = HostingHubAPI.error(error, token: access?.token); hostingHub.detail = latest
        }
    }
}
