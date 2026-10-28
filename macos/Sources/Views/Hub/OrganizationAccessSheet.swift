import SwiftUI

struct OrganizationAccessRequest: Identifiable {
    let id = UUID()
    var member: HubMember?
    var team: HubOrganizationTeam?
    var assigning = false
}

/// Existing membership is read before review and checked again immediately before every permission write.
struct OrganizationAccessSheet: View {
    @Bindable var store: RepoStore
    let detail: HubDetail
    let request: OrganizationAccessRequest
    @Environment(\.dismiss) private var dismiss
    @ViewState private var username = ""
    @ViewState private var permission: HubOrganizationPermission?
    @ViewState private var role = ""
    @ViewState private var expected = ""
    @ViewState private var loading = false
    @ViewState private var saving = false
    @ViewState private var reviewing = false
    @ViewState private var error: String?
    @ViewState private var reason: String?
    @ViewState private var parentFloor = 0
    private var team: Bool { request.team != nil }
    private var roles: [(String, String)] {
        var values = HostingHubAPI.organizationPermissionRoles(store.hubProvider, team: team)
        if team && store.hubProvider == .gitlab { values = values.filter { (Int($0.0) ?? 0) >= parentFloor } }
        guard request.assigning, store.hubProvider == .gitlab, let permission, !permission.hasDirect, permission.inherited else { return values }
        return values.filter { (Int($0.0) ?? 0) > (Int(permission.role) ?? 0) }
    }
    private var account: String { store.hubAccount.map { "\($0.host) · @\($0.username)" } ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reviewing ? String(localized: "Review access change") : request.assigning ? String(localized: "Add member to team") : String(localized: "Manage access")).font(.title2.weight(.semibold))
            Text(request.team?.name ?? detail.item.title).font(.callout.weight(.medium))
            if let permission {
                LabeledContent("Member", value: "@" + permission.username)
                LabeledContent(permission.inherited ? String(localized: "Inherited access") : String(localized: "Current role"), value: HostingHubAPI.organizationPermissionTitle(store.hubProvider, role: permission.role, team: team))
                if reviewing {
                    LabeledContent("Organization", value: detail.item.title)
                    LabeledContent("Account", value: account)
                    LabeledContent("New role", value: roles.first { $0.0 == role }?.1 ?? role)
                } else if reason == nil {
                    Picker(request.assigning && !permission.hasDirect ? String(localized: "Grant direct access") : String(localized: "New role"), selection: $role) { ForEach(roles, id: \.0) { value, label in Text(label).tag(value) } }
                    if permission.inherited { Text("Choose a direct role higher than the inherited access. Inherited permissions stay unchanged.").font(.caption).foregroundStyle(.secondary) }
                }
                if let reason { Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                else { Text(HostingHubAPI.organizationRoleMeaning(store.hubProvider, role: role, team: team)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !reviewing { Button("Choose another member") { self.permission = nil; error = nil; reason = nil }.disabled(loading || saving) }
            } else {
                Text("Choose an existing organization member. This changes access without sending a new organization invitation.").font(.callout).foregroundStyle(.secondary)
                TextField("Username", text: $username).textFieldStyle(.roundedBorder)
                if !detail.members.isEmpty { Menu("Choose loaded member") { ForEach(detail.members) { member in Button("\(member.name) · @\(member.username)") { username = member.username; Task { await load(userID: member.id) } } } } }
                Button("Load current access") { Task { await load() } }.disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
            }
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if reviewing { Button("Back") { reviewing = false }.disabled(saving) }
                if permission != nil && reason == nil {
                    Button(reviewing ? String(localized: "Apply access") : String(localized: "Review access change")) {
                        if reviewing { save() } else { reviewing = true; error = nil }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(saving || loading || store.hostingHub.uncertainWrite || !roles.contains(where: { $0.0 == role }) || role == permission?.role && permission?.hasDirect == true)
                }
            }
        }.padding(24).frame(width: 540).interactiveDismissDisabled(saving)
            .task { if let member = request.member, username.isEmpty { username = member.username; await load(userID: member.id) } }
    }
    private func load(userID: String = "") async {
        guard !loading else { return }; loading = true; error = nil; permission = nil; reason = nil
        let item = detail.item, name = username.trimmingCharacters(in: .whitespacesAndNewlines), stamp = store.hubActionStamp
        var access: HubAccess?
        do {
            var c = try await store.hubAccess(); let previous = c.isCurrent; c.isCurrent = { previous?() != false && store.hubActionStamp == stamp }; access = c
            let parent = try await HostingHubAPI.organizationMemberPermission(c, item: item, username: name, userID: userID)
            guard parent.exists && parent.active else { throw HostingHubAPI.fail(String(localized: "This person is not an active member of the organization.")) }
            let value = request.team == nil ? parent : try await HostingHubAPI.organizationMemberPermission(c, item: item, username: parent.username, userID: parent.userID, team: request.team)
            try HostingHubAPI.check(c)
            parentFloor = team ? Int(parent.role) ?? 0 : 0
            permission = value; expected = stamp
            reason = HostingHubAPI.organizationPermissionReason(c, permission: value, assigning: request.assigning)
            role = roles.contains(where: { $0.0 == value.role }) ? value.role : roles.first?.0 ?? ""
            if roles.isEmpty && reason == nil { reason = String(localized: "No higher direct role is available. Inherited access must be changed at its source.") }
        } catch { self.error = HostingHubAPI.error(error, token: access?.token) }
        loading = false
    }
    private func save() {
        guard let previous = permission, !saving else { return }; saving = true; error = nil
        let item = detail.item, role = role, context = expected, team = request.team, assigning = request.assigning
        Task {
            var notice: String?
            let saved = await store.hostingHubAction(expected: context) { c in notice = try await HostingHubAPI.saveOrganizationPermission(c, item: item, previous: previous, role: role, team: team, allowAssignment: assigning) }
            saving = false
            if saved { store.hostingHub.notice = notice ?? String(localized: "Access updated."); dismiss() }
            else { error = store.hostingHub.error ?? String(localized: "The organization or account changed. Reopen this action.") }
        }
    }
}
