import SwiftUI

/// Invitation composition and review stay in one native sheet while the people dashboard remains visible.
struct OrganizationInvitationSheet: View {
    @Bindable var store: RepoStore
    let detail: HubDetail
    @Environment(\.dismiss) private var dismiss
    @ViewState private var email = ""
    @ViewState private var role = ""
    @ViewState private var expiresAt = ""
    @ViewState private var reviewing = false
    @ViewState private var saving = false
    @ViewState private var error: String?
    @ViewState private var expected = ""
    private var github: Bool { store.hubProvider == .github }
    private var roles: [(String, String)] { HostingHubAPI.organizationRoles(store.hubProvider) }
    private var account: String { store.hubAccount.map { "\($0.host) · @\($0.username)" } ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(reviewing ? String(localized: "Review invitation") : String(localized: "Invite member")).font(.title2.weight(.semibold))
            Text("Invite a colleague by email, then place them in a team and grant the access they need.").font(.callout).foregroundStyle(.secondary)
            if reviewing {
                LabeledContent("Organization", value: detail.item.title)
                LabeledContent("Account", value: account)
                LabeledContent("Email address", value: email.trimmingCharacters(in: .whitespacesAndNewlines))
                LabeledContent("Invitation role", value: roles.first { $0.0 == role }?.1 ?? role)
                if !expiresAt.isEmpty { LabeledContent("Expiration date", value: expiresAt) }
            } else {
                TextField("Email address", text: $email).textFieldStyle(.roundedBorder)
                Picker("Invitation role", selection: $role) { ForEach(roles, id: \.0) { key, title in Text(title).tag(key) } }
                if !github { TextField("Expiration date (YYYY-MM-DD, optional)", text: $expiresAt).textFieldStyle(.roundedBorder) }
            }
            Text(HostingHubAPI.organizationRoleMeaning(store.hubProvider, role: role)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if reviewing { Button("Back") { reviewing = false }.disabled(saving) }
                Button(reviewing ? String(localized: "Send invitation") : String(localized: "Review invitation")) {
                    if reviewing { send() } else { error = nil; reviewing = true }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || store.hostingHub.uncertainWrite || !HostingHubAPI.validOrganizationEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) || !roles.contains(where: { $0.0 == role }))
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(saving)
            .task { if expected.isEmpty { expected = store.hubActionStamp; role = github ? "direct_member" : "30" } }
    }
    private func send() {
        guard !saving else { return }; saving = true; error = nil
        let item = detail.item, address = email.trimmingCharacters(in: .whitespacesAndNewlines), role = role, expires = expiresAt, stamp = expected
        Task {
            var notice: String?
            let saved = await store.hostingHubAction(expected: stamp) { c in notice = try await HostingHubAPI.inviteOrganizationMember(c, item: item, email: address, role: role, expiresAt: expires) }
            saving = false
            if saved { store.hostingHub.notice = notice ?? String(localized: "Invitation sent."); dismiss() }
            else { error = store.hostingHub.error ?? String(localized: "The organization or account changed. Reopen this action.") }
        }
    }
}
