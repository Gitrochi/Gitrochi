import Foundation

extension RepoStore {
    var hubAccount: HostAccount? { AccountStore.shared.accounts.first { $0.id == hostingHub.selectedAccountID } ?? hostingAccount ?? AccountStore.shared.accounts.first }
    private var hubSelectionStamp: String { [url?.path ?? "", target?.provider.rawValue ?? "", target?.host ?? "", target?.path ?? "", hubAccount?.id ?? "", hostingHub.projectScope].joined(separator: "\0") }
    var hubContextStamp: String { hubSelectionStamp + "\0" + String(AccountStore.shared.revision) }
    var hubActionStamp: String { hubContextStamp + "|" + hostingHub.generation.uuidString + "|" + hostingHub.section.rawValue + "|" + (hostingHub.detail?.item.id ?? "") + "|" + hostingHub.detailID.uuidString }
    var hubProvider: Provider { hubAccount?.provider ?? target?.provider ?? .github }
    var hubCredentialState: CredentialCache.State? { hubAccount.map { AccountStore.shared.credentialState(for: $0) } }
    /// The selected hub account whose saved credential is pending or requires approval.
    var pendingHubCredentialAccount: HostAccount? { hubAccount.flatMap { AccountStore.shared.awaitsAccess($0) ? $0 : nil } }
    var hubProjectRepositoryOwner: String? {
        guard let account = hubAccount, let target, AccountStore.shared.candidates(for: target).contains(where: { $0.id == account.id }) else { return nil }
        return target.path.split(separator: "/").first.map(String.init)
    }
    var hubProjectEffectiveScope: String { hubProjectRepositoryOwner == nil ? "personal" : hostingHub.projectScope }
    var hubProjectOwner: String { hubProjectEffectiveScope == "personal" ? hubAccount?.username ?? "" : hubProjectRepositoryOwner ?? "" }
    func selectHubProjectScope(_ scope: String) async {
        guard !hostingHub.busy, ["repository", "personal"].contains(scope) else { return }
        hostingHub.projectScope = scope; await activateHostingHub(hostingHub.section)
    }
    func activateHostingHub(_ section: HostingHubSection) async {
        let stamp = hubContextStamp
        if hostingHub.section != section || hostingHub.context != stamp { let selected = hostingHub.selectedAccountID, projectScope = hostingHub.projectScope; hostingHub = HostingHubState(); hostingHub.selectedAccountID = selected; hostingHub.projectScope = projectScope; hostingHub.section = section; hostingHub.context = stamp }
        if hostingHub.page == 0 && !hostingHub.loading { await loadHostingHub() }
    }
    func selectHubAccount(_ id: String) async { guard !hostingHub.busy else { return }; hostingHub.selectedAccountID = id; await activateHostingHub(hostingHub.section) }
    /// Saved credentials stay silent until the user explicitly requests Keychain access.
    func allowHubStoredAccess() async {
        guard let account = hubAccount, hubCredentialState == .authorizationRequired, !hostingHub.busy, !hostingHub.allowingCredentialAccess else { return }
        let generation = hostingHub.generation, path = url?.path, section = hostingHub.section
        hostingHub.allowingCredentialAccess = true; hostingHub.error = nil
        let current = { self.hostingHub.generation == generation && self.hubAccount?.id == account.id && self.url?.path == path && self.hostingHub.section == section }
        defer { if current() { hostingHub.allowingCredentialAccess = false } }
        do {
            try await AccountStore.shared.allowStoredAccess(for: account)
            guard current() else { return }
            hostingHub.allowingCredentialAccess = false
            await activateHostingHub(hostingHub.section)
        } catch {
            if current() { hostingHub.error = AccountConnectionFailure.message(for: error) }
        }
    }
    func hubAccess() async throws -> HubAccess {
        guard let account = hubAccount else { throw HostingHubAPI.fail(String(localized: "Connect a GitHub or GitLab account to use this workspace.")) }
        let generation = hostingHub.generation, selection = hubSelectionStamp, section = hostingHub.section
        let actual = target, candidates = actual.map { AccountStore.shared.candidates(for: $0) } ?? []
        if hostingHub.section == .releases && (actual == nil || !candidates.contains(where: { $0.id == account.id })) { throw HostingHubAPI.fail(String(localized: "Open a repository on the selected account's server to use releases and projects.")) }
        let selectedTarget: RepoTarget
        let matchingTarget = actual.flatMap { value in candidates.contains(where: { $0.id == account.id }) ? value : nil }
        selectedTarget = HostingHubAPI.projectTarget(matchingTarget, provider: account.provider, host: account.host, username: account.username, personal: hostingHub.section == .projects && account.provider == .github && hostingHub.projectScope == "personal")
        let token = await AccountStore.shared.loadToken(for: account)
        guard hostingHub.generation == generation, hubSelectionStamp == selection, hostingHub.section == section else {
            throw HostingHubAPI.fail(String(localized: "The repository or account changed. Reopen this action."))
        }
        guard let token else {
            let message = hubCredentialState == .authorizationRequired
                ? String(localized: "Allow access to the saved account to use repository services.")
                : String(localized: "The selected account has no token. Reconnect it from Settings → Accounts.")
            throw HostingHubAPI.fail(message)
        }
        let stamp = hubContextStamp
        return HubAccess(target: selectedTarget, token: token, apiBase: account.apiBase, me: account.username, isCurrent: { [weak self] in guard let self else { return false }; return self.hostingHub.generation == generation && self.hubContextStamp == stamp })
    }
    func loadHostingHub(append: Bool = false) async {
        guard !hostingHub.loading, !hostingHub.busy else { return }
        // AccountStore's revision reloads this workspace after the silent read settles.
        if hubCredentialState == .loading { hostingHub.error = nil; hostingHub.projectPermissionRequired = false; return }
        let generation = hostingHub.generation, loadID = UUID(); hostingHub.listID = loadID; hostingHub.loading = true; hostingHub.error = nil; hostingHub.projectPermissionRequired = false
        if !append { hostingHub.detail = nil; hostingHub.detailID = UUID() }
        let current = { self.hostingHub.generation == generation && self.hostingHub.listID == loadID }
        defer { if current() { hostingHub.loading = false } }
        var access: HubAccess?
        do { let c = try await hubAccess(); access = c; let result = try await HostingHubAPI.page(c, section: hostingHub.section, page: append ? hostingHub.page + 1 : 1, cursor: append ? hostingHub.cursor : nil); guard current(), c.isCurrent?() != false else { return }; hostingHub.items = append ? hostingHub.items + result.items.filter { item in !hostingHub.items.contains(where: { $0.id == item.id }) } : result.items; hostingHub.page = append ? hostingHub.page + 1 : 1; hostingHub.more = result.more; hostingHub.cursor = result.cursor; hostingHub.notice = result.notice; hostingHub.uncertainWrite = false }
        catch { if current() { hostingHub.error = HostingHubAPI.error(error, token: access?.token); hostingHub.projectPermissionRequired = error is HubProjectPermissionError } }
    }
    func selectHostingHubItem(_ item: HubItem, append: Bool = false, tab: String? = nil) async {
        guard !hostingHub.busy, hubCredentialState != .loading else { return }
        let generation = hostingHub.generation, loadID = UUID(); hostingHub.detailID = loadID; hostingHub.detailLoading = true; hostingHub.error = nil; hostingHub.projectPermissionRequired = false
        if let tab { hostingHub.tab = tab }; if !append && hostingHub.detail?.item.id != item.id { hostingHub.detail = nil }
        let current = { self.hostingHub.generation == generation && self.hostingHub.detailID == loadID }
        defer { if current() { hostingHub.detailLoading = false } }
        var access: HubAccess?
        do { let c = try await hubAccess(); access = c; var result = try await HostingHubAPI.detail(c, section: hostingHub.section, item: item, page: append ? hostingHub.detailPage + 1 : 1, cursor: append ? hostingHub.detailCursor : nil, tab: hostingHub.tab); guard current(), c.isCurrent?() != false else { return }; if append, let old = hostingHub.detail { result.rows = old.rows + result.rows.filter { row in !old.rows.contains(where: { $0.id == row.id }) }; result.repositories = old.repositories + result.repositories.filter { row in !old.repositories.contains(where: { $0.id == row.id }) }; result.members = old.members + result.members.filter { row in !old.members.contains(where: { $0.id == row.id }) } }; hostingHub.detail = result; hostingHub.detailPage = append ? hostingHub.detailPage + 1 : 1; hostingHub.detailCursor = result.cursor; hostingHub.uncertainWrite = false }
        catch { if current() { hostingHub.error = HostingHubAPI.error(error, token: access?.token); hostingHub.projectPermissionRequired = error is HubProjectPermissionError } }
    }
    @discardableResult
    func hostingHubAction(expected: String, refreshList: Bool = false, action: (HubAccess) async throws -> Void) async -> Bool {
        guard hubActionStamp == expected, !hostingHub.busy, !hostingHub.loading, !hostingHub.detailLoading, !hostingHub.uncertainWrite, hubCredentialState != .loading else { return false }
        let generation = hostingHub.generation, item = hostingHub.detail?.item
        hostingHub.busy = true; hostingHub.error = nil; hostingHub.projectPermissionRequired = false; var access: HubAccess?
        let current = { self.hostingHub.generation == generation && self.hubActionStamp == expected }
        do { var c = try await hubAccess(); let baseCurrent = c.isCurrent; c.isCurrent = { baseCurrent?() != false && current() }; access = c; guard current() else { return false }; try await action(c); guard current() else { return false }; hostingHub.busy = false; if let item, !refreshList { await selectHostingHubItem(item) } else { await loadHostingHub() }; return true }
        catch { if current() { hostingHub.busy = false; hostingHub.error = HostingHubAPI.error(error, token: access?.token); hostingHub.projectPermissionRequired = error is HubProjectPermissionError; hostingHub.uncertainWrite = error is HubUncertainWriteError }; return false }
    }
}
