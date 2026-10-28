import SwiftUI

/// A provider-aware organization workspace keeps invitations tied to the reviewed account and organization.
struct OrganizationWorkspace: View {
    @Bindable var store: RepoStore
    let detail: HubDetail
    var onClone: ((String) -> Void)?
    @ViewState private var inviting = false
    @ViewState private var accessRequest: OrganizationAccessRequest?
    @ViewState private var query = ""
    @ViewState private var toolsExpanded = false
    @ViewState private var showInvitations = false
    private var github: Bool { store.hubProvider == .github }
    private var locked: Bool { store.hostingHub.loading || store.hostingHub.detailLoading || store.hostingHub.busy }
    private var canInvite: Bool { detail.organizationAccess?.canInvite == true && !store.hostingHub.uncertainWrite }
    private var managementLocked: Bool { locked || store.hubOrganizationLoading }
    private func matches(_ value: String) -> Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var filteredMembers: [HubMember] { detail.members.filter { matches($0.name + " " + $0.username) } }
    private var filteredTeams: [HubOrganizationTeam] { detail.teams.filter { team in matches(team.name + " " + team.description + " " + team.members.map { $0.name + " " + $0.username }.joined(separator: " ")) } }
    private var links: [HubOrganizationLink] { HostingHubAPI.organizationLinks(provider: store.hubProvider, host: store.hubAccount?.host ?? "", item: detail.item) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            WorkbenchFlow(spacing: 6) {
                tab(String(localized: "Overview"), "overview", "square.grid.2x2")
                tab(String(localized: "Repositories"), "repositories", "folder")
                tab(String(localized: "Members"), "members", "person.2")
                tab(github ? String(localized: "Teams") : String(localized: "Subgroups"), "teams", "person.3")
                tab(String(localized: "Invitations"), "invitations", "envelope")
            }.disabled(locked)
            switch store.hostingHub.tab {
            case "overview": overview
            case "members": members; sectionStatus("members")
            case "teams": teams; sectionStatus("teams")
            case "invitations": invitations; sectionStatus("invitations")
            default: repositories; sectionStatus("repositories")
            }
        }
        .sheet(isPresented: $inviting) { OrganizationInvitationSheet(store: store, detail: detail) }
        .sheet(item: $accessRequest) { request in OrganizationAccessSheet(store: store, detail: detail, request: request) }
        .onChange(of: showInvitations) { _, showing in
            if showing && detail.organizationSections["invitations"]?.loaded != true && detail.organizationSections["invitations"]?.loading != true {
                Task { await store.loadOrganizationSection("invitations") }
            }
        }
        .onChange(of: detail.item.id) { _, _ in resetInvitation() }
        .onChange(of: store.hubAccount?.id) { _, _ in resetInvitation() }
        .onChange(of: store.hostingHub.uncertainWrite) { _, value in if value { inviting = false; accessRequest = nil } }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HostingAvatar(name: detail.item.title, username: detail.item.subtitle, avatarURL: detail.item.avatarURL, size: 38, style: .organization)
                VStack(alignment: .leading, spacing: 3) { Text(detail.item.title).font(.title3.weight(.semibold)); Text(detail.item.subtitle + " · " + (detail.organizationAccess?.role ?? String(localized: "Unknown"))).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if canInvite {
                    Button("Invite member") { inviting = true }.buttonStyle(.borderedProminent).disabled(managementLocked)
                    Button("Manage access") { accessRequest = OrganizationAccessRequest() }.disabled(managementLocked)
                }
            }
            Text("Invite colleagues, organize teams, and grant the access each person needs.").font(.callout).foregroundStyle(.secondary)
            if let notice = detail.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if canInvite || !detail.invitations.isEmpty {
                DisclosureGroup(isExpanded: $showInvitations) {
                    invitations
                    sectionStatus("invitations")
                } label: {
                    HStack { Label("Pending invitations", systemImage: "envelope"); if detail.organizationSections["invitations"]?.error != nil { Text("Unavailable").font(.caption).foregroundStyle(.secondary) } else if detail.organizationSections["invitations"]?.loading == true { ProgressView().controlSize(.small) } else if detail.organizationSections["invitations"]?.loaded != true { Text("Not loaded").font(.caption).foregroundStyle(.secondary) } else { Text(verbatim: String(localized: "{0} loaded").replacingOccurrences(of: "{0}", with: detail.invitations.count.formatted())).font(.caption).foregroundStyle(.secondary) } }
                }
            }
            TextField("Search loaded people and teams", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 390)
        }
    }
    private func tab(_ title: String, _ value: String, _ icon: String) -> some View {
        Button { inviting = false; Task { await store.selectHostingHubItem(detail.item, tab: value) } } label: { Label(title, systemImage: icon) }
            .buttonStyle(.bordered).tint(store.hostingHub.tab == value ? .accentColor : .secondary)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { peopleDashboard.frame(minWidth: 320); teamsDashboard.frame(minWidth: 320) }
                VStack(alignment: .leading, spacing: 18) { peopleDashboard; teamsDashboard }
            }
            dashboardSection(String(localized: "Repositories"), section: "repositories", count: detail.repositories.count) { repositories }
            DisclosureGroup("Organization tools", isExpanded: $toolsExpanded) {
            Text("Open administration tools on the connected server. Availability depends on your role, account permissions, and plan.").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(links) { link in
                    Button { open(link.url) } label: { HStack { Text(link.title); Spacer(); Image(systemName: "arrow.up.right") }.frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }
            }
            }
        }
    }
    private var peopleDashboard: some View { dashboardSection(String(localized: "Members"), section: "members", count: detail.members.count) { members } }
    private var teamsDashboard: some View { dashboardSection(github ? String(localized: "Teams") : String(localized: "Subgroups"), section: "teams", count: detail.teams.count) { teams } }
    private func dashboardSection<Content: View>(_ title: String, section: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.headline); Spacer(); Text(verbatim: (section == "members" ? String(localized: "{0} people loaded") : String(localized: "{0} loaded")).replacingOccurrences(of: "{0}", with: count.formatted())).font(.caption).foregroundStyle(.secondary) }
            content()
            sectionStatus(section)
        }.frame(maxWidth: .infinity, alignment: .topLeading).padding(14).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private func sectionStatus(_ section: String) -> some View {
        let state = detail.organizationSections[section] ?? HubOrganizationSectionState()
        if let error = state.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        if state.loading { ProgressView().controlSize(.small) }
        else if state.more || state.error != nil || !state.loaded {
            Button(state.error == nil ? String(localized: "Load more") : String(localized: "Retry")) { Task { await store.loadOrganizationSection(section) } }.disabled(locked)
        }
    }
    private var repositories: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(detail.repositories) { repository in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) { Text(repository.name).fontWeight(.semibold).textSelection(.enabled); if !repository.description.isEmpty { Text(repository.description).font(.caption).foregroundStyle(.secondary) } }
                    Spacer(minLength: 0)
                    Button(onClone == nil ? String(localized: "Copy clone URL") : String(localized: "Clone")) {
                        if let onClone { onClone(repository.cloneURL) } else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(repository.cloneURL, forType: .string) }
                    }.disabled(locked || safeURL(repository.cloneURL) == nil)
                    if safeURL(repository.url) != nil { Button { open(repository.url) } label: { Image(systemName: "arrow.up.right.square") }.help("Open in browser") }
                }.padding(14).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            if detail.repositories.isEmpty && detail.organizationSections["repositories"]?.error == nil { Text("No repositories visible to this account.").foregroundStyle(.secondary) }
        }
    }
    private var members: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 12) {
            ForEach(filteredMembers) { member in memberCard(member) }
            if detail.members.isEmpty && detail.organizationSections["members"]?.error == nil { Text("No members visible to this account.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func memberCard(_ member: HubMember, team: HubOrganizationTeam? = nil) -> some View {
        HStack(spacing: 8) {
            HostingAvatar(name: member.name, username: member.username, avatarURL: member.avatarURL, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.name).font(.callout.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(member.name)
                Text(verbatim: "@" + member.username).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if !github { Text(member.role).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if canInvite { Button { accessRequest = OrganizationAccessRequest(member: member, team: team) } label: { Image(systemName: "key").font(.caption2) }.buttonStyle(.borderless).help("Manage access").accessibilityLabel("Manage access").disabled(managementLocked) }
            if let url = member.profileURL { Link(destination: url) { Image(systemName: "arrow.up.right").font(.caption2) }.help("Open profile").accessibilityLabel("Open profile") }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(7).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private var teams: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(filteredTeams) { team in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) { Text(team.name).font(.callout.weight(.semibold)); if !team.description.isEmpty { Text(team.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }
                        Spacer(minLength: 0)
                        if canInvite { Button("Add member") { accessRequest = OrganizationAccessRequest(team: team, assigning: true) }.controlSize(.small).disabled(managementLocked) }
                        if safeURL(team.url) != nil { Button { open(team.url) } label: { Image(systemName: "arrow.up.right.square") }.help("Open in browser") }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(team.members.filter { matches(team.name) || matches($0.name + " " + $0.username) }) { member in memberCard(member, team: team) }
                    }
                    HStack {
                        Text(verbatim: String(localized: "{0} people loaded").replacingOccurrences(of: "{0}", with: team.members.count.formatted())).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if team.memberState.loading { ProgressView().controlSize(.small) }
                        else if team.memberState.more || team.memberState.error != nil || !team.memberState.loaded {
                            Button(team.memberState.error == nil ? String(localized: "Load more") : String(localized: "Retry")) { Task { await store.loadOrganizationTeamMembers(team.id) } }.controlSize(.small).disabled(locked)
                        }
                    }
                    if let error = team.memberState.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    else if team.memberState.loaded && team.members.isEmpty { Text("No members visible to this account.").font(.caption).foregroundStyle(.secondary) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            if detail.teams.isEmpty && detail.organizationSections["teams"]?.error == nil { Text("No visible teams or subgroups.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var invitations: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.hostingHub.tab != "overview" { HStack { Text("Pending invitations").font(.headline); Spacer(); if canInvite { Button("Invite member") { inviting = true }.buttonStyle(.borderedProminent).disabled(locked) } } }
            ForEach(detail.invitations) { invitation in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) { Text(invitation.email).fontWeight(.semibold).textSelection(.enabled); Text(invitation.role).font(.caption).foregroundStyle(.secondary); if !invitation.createdAt.isEmpty { Text(String(invitation.createdAt.prefix(10))).font(.caption2).foregroundStyle(.secondary) } }
                    Spacer()
                    if canInvite { Button("Cancel invitation", role: .destructive) { cancel(invitation) }.disabled(locked) }
                }.padding(14).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            if detail.invitations.isEmpty && detail.organizationSections["invitations"]?.loaded == true && detail.organizationSections["invitations"]?.error == nil && detail.notice == nil { Text("No pending invitations.").foregroundStyle(.secondary) }
        }
    }
    private func resetInvitation() { inviting = false; accessRequest = nil; query = "" }
    private func cancel(_ invitation: HubOrganizationInvitation) {
        let item = detail.item, context = store.hubActionStamp
        store.confirm = ConfirmRequest(title: String(localized: "Cancel this invitation?"), message: item.title + "\n" + invitation.email + "\n" + invitation.role, actionTitle: String(localized: "Cancel invitation"), destructive: true) {
            await store.hostingHubAction(expected: context) { c in try await HostingHubAPI.cancelOrganizationInvitation(c, item: item, invitation: invitation) }
        }
    }
    private func safeURL(_ value: String) -> URL? { HostingHubAPI.safeURL(provider: store.hubProvider, host: store.hubAccount?.host ?? "", value) }
    private func open(_ value: String) { if let url = safeURL(value) { NSWorkspace.shared.open(url) } }
}
