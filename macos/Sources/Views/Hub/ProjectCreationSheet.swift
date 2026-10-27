import SwiftUI

/// Privacy is a creation decision; billing metadata never substitutes for server permissions.
struct ProjectCreationSheet: View {
    @Bindable var store: RepoStore
    let created: (HubItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var mode = "local"
    @ViewState private var accountID = ""
    @ViewState private var scope = "personal"
    @ViewState private var title = ""
    @ViewState private var summary = ""
    @ViewState private var capabilities: HubProjectCreationCapabilities?
    @ViewState private var probing = false
    @ViewState private var saving = false
    @ViewState private var error: String?
    @ViewState private var review = false
    @ViewState private var uncertain = false
    @ViewState private var recovered: HubItem?
    @ViewState private var active = true
    private var accounts: [HostAccount] { AccountStore.shared.accounts.filter { $0.provider == .github } }
    private var account: HostAccount? { accounts.first { $0.id == accountID } ?? accounts.first }
    private var matchingRepository: RepoTarget? { guard let account, let target = store.target, AccountStore.shared.candidates(for: target).contains(where: { $0.id == account.id }) else { return nil }; return target }
    private var context: String { [mode == "local" ? "local" : "remote", account?.id ?? "", scope, store.url?.path ?? "", store.target?.host ?? "", store.target?.provider.rawValue ?? "", store.target?.path ?? "", String(AccountStore.shared.revision)].joined(separator: "|") }
    private var owner: String { scope == "repository" ? matchingRepository?.path.split(separator: "/").first.map(String.init) ?? "" : account?.username ?? "" }
    private var ready: Bool { (scope != "repository" || matchingRepository != nil || mode == "local") && !title.trimmed.isEmpty && !saving && !probing && !uncertain && (mode == "local" || capabilities?.viewerVerified == true && capabilities?.ownerID.isEmpty == false && capabilities?.canCreate != false && (mode != "public" || capabilities?.canPublish != false)) }
    private var modeTitle: String { mode == "local" ? String(localized: "Local project") : mode == "private" ? String(localized: "Private GitHub project") : String(localized: "Public GitHub project") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: review ? "checklist" : "rectangle.stack.badge.plus")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(review ? String(localized: "Review project creation") : String(localized: "Create a project")).font(.system(size: 19, weight: .semibold))
                    Text(review ? String(localized: "Check the destination and visibility before creating your project.") : String(localized: "Choose where your work lives"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).disabled(saving).help("Close")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if review { creationReview } else { creationForm }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if uncertain {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Refresh and check existing projects before creating another one.").font(.callout)
                            HStack {
                                Button("Refresh projects") { Task { await recover() } }.disabled(saving)
                                if let recovered { Button("Open created project") { Task { await finish(recovered) } }.disabled(saving) }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                Label(modeTitle, systemImage: mode == "local" ? "internaldrive" : mode == "public" ? "globe" : "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                if review {
                    Button("Back") { review = false }.disabled(saving || uncertain).keyboardShortcut(.cancelAction)
                    Button("Create project") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(!ready).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.disabled(saving).keyboardShortcut(.cancelAction)
                    Button("Review creation") { review = true }.buttonStyle(.borderedProminent).disabled(!ready).keyboardShortcut(.defaultAction)
                }
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 760, height: review ? 520 : 680).background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(saving)
        .onAppear { accountID = store.hubAccount?.id ?? accounts.first?.id ?? "" }
        .task(id: context) {
            if scope == "repository", matchingRepository == nil { scope = "personal"; return }
            restoreAttempt()
            await inspect()
        }
        .onDisappear { active = false }
        .accessibilityElement(children: .contain).accessibilityLabel("Project creation")
    }
    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                choice("local", "Local project", symbol: "internaldrive", description: "Private to this device. No GitHub account required.")
                choice("private", "Private GitHub project", symbol: "lock", description: "Plan with invited collaborators on GitHub.")
                choice("public", "Public GitHub project", symbol: "globe", description: "Share your project with everyone on GitHub.")
            }.disabled(saving || uncertain)
            if mode == "local" {
                Label("Saved on this device. Local projects do not sync with GitHub.", systemImage: "internaldrive")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else { remoteAccess }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project name").font(.callout.weight(.semibold))
                    TextField("Project name", text: $title).textFieldStyle(.roundedBorder).controlSize(.large).accessibilityIdentifier("project-create-name")
                }
                if mode == "local" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Short description").font(.callout.weight(.semibold))
                        TextField("What are you working toward?", text: $summary, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
                    }
                } else { Text("You can add a description, fields and shared views after creation.").font(.caption).foregroundStyle(.secondary) }
            }.disabled(saving || uncertain)
        }
    }
    private var creationReview: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                reviewRow("Project name", value: title.trimmed)
                Divider()
                reviewRow("Project type", value: modeTitle)
                Divider()
                reviewRow("Destination", value: mode == "local" ? String(localized: "This device") : "@" + owner)
                if mode != "local", let account {
                    Divider()
                    reviewRow("GitHub account", value: "@" + account.username + " · " + account.host)
                }
                if mode == "local", !summary.trimmed.isEmpty {
                    Divider()
                    reviewRow("Short description", value: summary.trimmed)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            if mode == "public" {
                Label("Everyone on GitHub can see this project.", systemImage: "globe").font(.callout.weight(.medium))
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            } else if mode == "local" {
                Label("Saved on this device. Local projects do not sync with GitHub.", systemImage: "internaldrive")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func reviewRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private func choice(_ value: String, _ label: LocalizedStringKey, symbol: String, description: LocalizedStringKey) -> some View {
        Button { mode = value; error = nil } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor); Spacer(); Image(systemName: mode == value ? "checkmark.circle.fill" : "circle").foregroundStyle(mode == value ? Color.accentColor : .secondary) }
                Text(label).font(.callout.weight(.semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading).background(mode == value ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(mode == value ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: mode == value ? 2 : 1))
        }.buttonStyle(.plain).accessibilityIdentifier("project-create-" + value)
    }
    @ViewBuilder private var remoteAccess: some View {
        VStack(alignment: .leading, spacing: 14) {
            if accounts.isEmpty { Label("Connect a GitHub account in Settings → Accounts to create a synced project.", systemImage: "person.crop.circle.badge.exclamationmark").font(.callout) }
            else {
                HStack {
                    Picker("GitHub account", selection: $accountID) { ForEach(accounts) { account in Text("@" + account.username + " · " + account.host).tag(account.id) } }
                    Picker("Project owner", selection: $scope) { Text("My projects").tag("personal"); if let matchingRepository { Text(matchingRepository.path.split(separator: "/").first.map(String.init) ?? "").tag("repository") } }
                }.disabled(saving || uncertain)
                if let account, AccountStore.shared.credentialState(for: account) != .ready {
                    SavedAccountAccessNotice(account: account).disabled(saving || probing || uncertain)
                }
                if probing { HStack { ProgressView().controlSize(.small); Text("Checking account and project capabilities…").font(.callout).foregroundStyle(.secondary) } }
                if let capabilities {
                    HStack(spacing: 22) { plan("Account plan", capabilities.accountPlan); plan("Project owner plan", capabilities.ownerPlan) }
                    HStack(spacing: 24) { Label(String(localized: "Up to {0} fields").replacingOccurrences(of: "{0}", with: String(capabilities.limits.fields)), systemImage: "list.bullet.rectangle"); Label(capabilities.limits.autoAddWorkflows.map { String(localized: "Up to {0} auto-add workflows").replacingOccurrences(of: "{0}", with: String($0)) } ?? String(localized: "Workflow limit unknown"), systemImage: "arrow.triangle.branch") }.font(.caption)
                    if let notice = capabilities.notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    Link("GitHub plan and workflow limits", destination: URL(string: "https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/adding-items-automatically")!).font(.caption)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private func plan(_ label: LocalizedStringKey, _ value: HubProjectPlan) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value.tier == .unknown ? String(localized: "Unknown") : "GitHub " + value.tier.rawValue.capitalized).font(.callout.weight(.semibold)) }
    }
    private func access() throws -> HubAccess {
        guard let account else { throw HostingHubAPI.fail(String(localized: "Connect a GitHub account in Settings → Accounts to create a synced project.")) }
        guard let token = AccountStore.shared.token(for: account) else { throw HostingHubAPI.fail(AccountStore.shared.savedAccessMessage(for: account)) }
        guard scope != "repository" || matchingRepository != nil else { throw HostingHubAPI.fail(String(localized: "The repository or account changed. Reopen this action.")) }
        let expected = context
        let target = HostingHubAPI.projectTarget(scope == "repository" ? matchingRepository : nil, provider: .github, host: account.host, username: account.username, personal: scope != "repository")
        return HubAccess(target: target, token: token, apiBase: account.apiBase, me: account.username, isCurrent: { active && context == expected })
    }
    private func inspect() async {
        capabilities = nil; error = nil
        guard mode != "local", let account, AccountStore.shared.token(for: account) != nil else { probing = false; return }
        let expected = context; probing = true
        defer { if context == expected { probing = false } }
        do { let result = try await HostingHubAPI.inspectProjectCreationCapabilities(access()); guard context == expected, active, !Task.isCancelled else { return }; capabilities = result }
        catch { if context == expected, active, !Task.isCancelled { self.error = HostingHubAPI.error(error) } }
    }
    private func save() async {
        guard ready else { return }; saving = true; error = nil
        let savedAccount = account, savedOwner = owner, savedTitle = title.trimmed
        defer { saving = false }
        do {
            let item: HubItem
            if mode == "local" { item = try await LocalProjectStore.shared.create(title: title, description: summary) }
            else {
                let c = try access()
                if let savedAccount { ProjectCreationRecovery.save(savedAccount, owner: savedOwner, title: savedTitle) }
                item = try await HostingHubAPI.createProject(c, title: title, isPublic: mode == "public")
                if let savedAccount { ProjectCreationRecovery.clear(savedAccount, owner: savedOwner) }
            }
            await finish(item)
        } catch let failure as HubUncertainWriteError {
            uncertain = true; recovered = failure.createdProject; error = HostingHubAPI.error(failure)
            if let savedAccount { ProjectCreationRecovery.save(savedAccount, owner: savedOwner, title: savedTitle, project: failure.createdProject) }
        } catch {
            if mode != "local", let savedAccount { ProjectCreationRecovery.clear(savedAccount, owner: savedOwner) }
            self.error = HostingHubAPI.error(error)
        }
    }
    private func restoreAttempt() {
        guard mode != "local", let account else { uncertain = false; recovered = nil; return }
        let attempt = ProjectCreationRecovery.load(account, owner: owner)
        uncertain = attempt != nil; recovered = attempt?.project
        if let attempt { title = attempt.title }
    }
    private func recover() async {
        saving = true; defer { saving = false }
        do {
            let c = try access()
            var items: [HubItem] = [], cursor: String?, page = 1
            while true {
                let result = try await HostingHubAPI.page(c, section: .projects, page: page, cursor: cursor)
                items += result.items
                guard result.more else { break }
                guard let next = result.cursor, next != cursor else { throw HostingHubAPI.fail(String(localized: "Load all projects before creating another one.")) }
                cursor = next; page += 1
            }
            if let recovered { self.recovered = items.first { $0.id == recovered.id } ?? recovered }
            else { recovered = items.first { $0.title == title.trimmed } }
            if let account { ProjectCreationRecovery.clear(account, owner: owner) }
            uncertain = false; error = nil
        } catch { self.error = HostingHubAPI.error(error) }
    }
    private func finish(_ item: HubItem) async {
        store.hostingHub.projectSource = LocalProjectStore.isLocal(item) ? "local" : "remote"
        if !LocalProjectStore.isLocal(item) { store.hostingHub.selectedAccountID = account?.id; store.hostingHub.projectScope = scope }
        await store.activateHostingHub(.projects)
        await store.loadHostingHub()
        await store.selectHostingHubItem(item)
        created(item); dismiss()
    }
}
