#!/usr/bin/env bash
# Exercise the production hub store and cache without Keychain, accounts or network access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tools/project-backend-test-sources.sh"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct HostAccount: Equatable {
    let id: String
    let username: String
    var provider: Provider { .github }
    var host: String { "github.com" }
    var apiBase: String { "https://api.github.com" }
}
struct HostingError: LocalizedError { let status: Int; var errorDescription: String? { "HTTP \(status)" } }
enum FixtureFailure: Error { case denied }
enum AccountConnectionFailure {
    static func message(for error: Error) -> String { "Fixture approval failed" }
}

@MainActor final class AccountStore {
    static let shared = AccountStore()
    var accounts: [HostAccount] = []
    var revision = 0
    private var cache = CredentialCache { _ in fatalError("Unexpected credential reader") }
    private var approvals: [String: CheckedContinuation<Void, Error>] = [:]
    private(set) var approvedAccounts: [String] = []
    var holdTokenLoads = false
    private(set) var tokenLoadsCount = 0
    private var tokenLoads: [String: CheckedContinuation<String?, Never>] = [:]

    func reset(_ accounts: [HostAccount]) {
        precondition(approvals.isEmpty && tokenLoads.isEmpty, "An approval fixture was left suspended")
        holdTokenLoads = false; tokenLoadsCount = 0
        self.accounts = accounts; revision = 0; approvedAccounts = []
        cache = CredentialCache { _ in fatalError("Unexpected credential reader") }
        cache.onChange = { [weak self] in self?.revision += 1 }
        for account in accounts { set(.loading, for: account) }
    }
    func set(_ state: CredentialCache.State, for account: HostAccount) {
        let attempt = cache.begin(account.id)
        guard state != .loading else { return }
        let status: Int32 = state == .authorizationRequired ? -25308 : state == .unavailable ? -25300 : 0
        cache.complete(account.id, attempt: attempt, result: CredentialReadResult(value: state == .ready ? "fixture-" + account.id : nil, status: status))
    }
    func token(for account: HostAccount) -> String? { cache.value(account.id) }
    func loadToken(for account: HostAccount) async -> String? {
        tokenLoadsCount += 1
        if holdTokenLoads { return await withCheckedContinuation { tokenLoads[account.id] = $0 } }
        return cache.value(account.id)
    }
    func awaitsAccess(_ account: HostAccount) -> Bool { [.loading, .authorizationRequired].contains(credentialState(for: account)) }
    func pendingToken(_ account: HostAccount) -> Bool { tokenLoads[account.id] != nil }
    func finishToken(_ account: HostAccount) {
        guard let continuation = tokenLoads.removeValue(forKey: account.id) else { fatalError("No pending fixture token load") }
        set(.ready, for: account)
        continuation.resume(returning: "fixture-" + account.id)
    }
    func credentialState(for account: HostAccount) -> CredentialCache.State { cache.state(account.id) }
    func savedAccessMessage(for account: HostAccount) -> String {
        switch credentialState(for: account) {
        case .loading: return String(localized: "Restoring your saved account…")
        case .authorizationRequired: return String(localized: "Your account is still connected. Allow access to its saved credentials to continue.")
        case .unavailable: return String(localized: "Saved credentials are unavailable. Retry access or reconnect this account in Settings.")
        case .ready: return String(localized: "Your account is connected.")
        }
    }
    func savedAccessErrorMessage(for account: HostAccount, error: Error) -> String { AccountConnectionFailure.message(for: error) }
    func candidates(for target: RepoTarget) -> [HostAccount] { accounts.filter { $0.provider == target.provider && $0.host == target.host } }
    func allowStoredAccess(for account: HostAccount) async throws {
        approvedAccounts.append(account.id)
        set(.loading, for: account)
        try await withCheckedThrowingContinuation { approvals[account.id] = $0 }
    }
    func pending(_ account: HostAccount) -> Bool { approvals[account.id] != nil }
    func finish(_ account: HostAccount, success: Bool = true) {
        guard let continuation = approvals.removeValue(forKey: account.id) else { fatalError("No pending fixture approval") }
        set(success ? .ready : .authorizationRequired, for: account)
        if success { continuation.resume() } else { continuation.resume(throwing: FixtureFailure.denied) }
    }
}

@MainActor final class RepoStore {
    var url: URL?
    var target: RepoTarget?
    var hostingAccount: HostAccount?
    var hostingHub = HostingHubState()
}

@MainActor enum Hosting {
    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) throws -> Data)?
    static func projectID(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~")))!
    }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Fixture-Account")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    static func data(_ request: URLRequest) async throws -> Data {
        precondition(request.url?.host == "api.github.com", "Unexpected fixture server")
        requests.append(request)
        if let handler { return try handler(request) }
        precondition(request.url?.path == "/graphql", "Unexpected fixture request")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let owner = (body["variables"] as! [String: Any])["owner"] as! String
        return try JSONSerialization.data(withJSONObject: ["data": ["user": ["projectsV2": ["nodes": [["id": owner, "title": "Fixture project"]], "pageInfo": ["hasNextPage": false]]]]])
    }
}

actor LocalHubMemory: LocalProjectPersistence {
    var content: String?
    func read() -> String? { content }
    func write(expected: String?, content: String) throws { precondition(expected == self.content); self.content = content }
}

@main struct HostingHubCredentialTests {
    @MainActor static func until(_ check: () -> Bool) async {
        for _ in 0..<200 {
            if check() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Fixture did not advance")
    }
    @MainActor static func main() async {
        let accounts = AccountStore.shared
        let first = HostAccount(id: "first", username: "fixture-first")
        let second = HostAccount(id: "second", username: "fixture-second")
        func fixture() -> RepoStore {
            accounts.reset([first, second]); Hosting.requests = []; Hosting.handler = nil
            let store = RepoStore(); store.hostingHub.selectedAccountID = first.id
            return store
        }

        let loading = fixture()
        await loading.activateHostingHub(.projects)
        precondition(loading.hubCredentialState == .loading && loading.hostingHub.error == nil, "A pending credential was reported as missing")
        precondition(Hosting.requests.isEmpty && accounts.approvedAccounts.isEmpty, "Pending access sent HTTP or requested approval")
        accounts.set(.ready, for: first)
        await loading.activateHostingHub(.projects)
        precondition(Hosting.requests.count == 1 && loading.hostingHub.items.first?.id == first.username, "Settled credentials did not load the selected account's projects")

        let denied = fixture()
        accounts.set(.authorizationRequired, for: first)
        await denied.activateHostingHub(.projects)
        for _ in 0..<3 { await denied.loadHostingHub() }
        precondition(denied.hubCredentialState == .authorizationRequired && denied.hostingHub.error == String(localized: "Your account is still connected. Allow access to its saved credentials to continue."), "Denied saved access was reported as a missing token")
        precondition(!denied.hostingHub.projectPermissionRequired, "Keychain access was confused with project OAuth scope")
        precondition(Hosting.requests.isEmpty && accounts.approvedAccounts.isEmpty, "Automatic retries prompted or sent HTTP with denied access")
        let approval = Task { await denied.allowHubStoredAccess() }
        await until { accounts.pending(first) }
        precondition(denied.hostingHub.allowingCredentialAccess && accounts.approvedAccounts == [first.id], "Explicit access did not target the selected hub account once")
        await denied.allowHubStoredAccess()
        precondition(accounts.approvedAccounts == [first.id], "A duplicate click requested approval twice")
        precondition(Hosting.requests.isEmpty, "HTTP ran before stored access was approved")
        accounts.finish(first)
        await approval.value
        precondition(!denied.hostingHub.allowingCredentialAccess && denied.hubCredentialState == .ready, "Approved access stayed pending")
        precondition(Hosting.requests.count == 1 && denied.hostingHub.items.first?.id == first.username, "Approved access did not reload projects")
        precondition(Hosting.requests[0].value(forHTTPHeaderField: "X-Fixture-Account") == "fixture-" + first.id, "Hub requested projects with another account's credential")

        let unavailable = fixture()
        accounts.set(.unavailable, for: first)
        await unavailable.activateHostingHub(.projects)
        precondition(unavailable.hubCredentialState == .unavailable && unavailable.hostingHub.error == String(localized: "Saved credentials are unavailable. Retry access or reconnect this account in Settings."), "A genuinely missing credential lost its reconnect guidance")
        precondition(Hosting.requests.isEmpty && accounts.approvedAccounts.isEmpty)

        let switchedAccount = fixture()
        accounts.set(.authorizationRequired, for: first)
        await switchedAccount.activateHostingHub(.projects)
        let accountApproval = Task { await switchedAccount.allowHubStoredAccess() }
        await until { accounts.pending(first) }
        switchedAccount.hostingHub.selectedAccountID = second.id
        await switchedAccount.activateHostingHub(.projects)
        accounts.set(.ready, for: second)
        accounts.finish(first)
        await accountApproval.value
        precondition(Hosting.requests.isEmpty && switchedAccount.hostingHub.selectedAccountID == second.id, "A late approval loaded a switched account")

        let switchedRepository = fixture()
        accounts.set(.authorizationRequired, for: first)
        switchedRepository.url = URL(fileURLWithPath: "/fixture/old", isDirectory: true)
        await switchedRepository.activateHostingHub(.projects)
        let repositoryApproval = Task { await switchedRepository.allowHubStoredAccess() }
        await until { accounts.pending(first) }
        switchedRepository.url = URL(fileURLWithPath: "/fixture/new", isDirectory: true)
        await switchedRepository.activateHostingHub(.projects)
        accounts.finish(first)
        await repositoryApproval.value
        precondition(Hosting.requests.isEmpty && switchedRepository.hostingHub.page == 0, "A late approval reloaded a switched repository")

        let rejected = fixture()
        accounts.set(.authorizationRequired, for: first)
        await rejected.activateHostingHub(.projects)
        let rejectedApproval = Task { await rejected.allowHubStoredAccess() }
        await until { accounts.pending(first) }
        accounts.finish(first, success: false)
        await rejectedApproval.value
        precondition(!rejected.hostingHub.allowingCredentialAccess && rejected.hostingHub.error == "Fixture approval failed", "Approval failure left the hub blocked or lost recovery guidance")
        precondition(Hosting.requests.isEmpty)
        let guarded = fixture()
        accounts.set(.ready, for: first)
        await guarded.activateHostingHub(.projects)
        let projectA = HubItem(id: "project-a", title: "Project A"), projectB = HubItem(id: "project-b", title: "Project B")
        var mutations = 0, loseNextCreation = false, failNextRead = false
        Hosting.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any], query = body["query"] as! String, variables = body["variables"] as! [String: Any]
            if query.hasPrefix("mutation") {
                mutations += 1
                if loseNextCreation { loseNextCreation = false; throw FixtureFailure.denied }
                return try JSONSerialization.data(withJSONObject: ["data": [:]])
            }
            if failNextRead { failNextRead = false; throw FixtureFailure.denied }
            let projectID = variables["id"] as! String
            return try JSONSerialization.data(withJSONObject: ["data": ["node": ["id": projectID, "title": projectID, "fields": ["nodes": [], "pageInfo": [:]], "items": ["nodes": [], "pageInfo": [:]]]]])
        }
        await guarded.selectHostingHubItem(projectA)
        let capturedConfirmation = guarded.hubActionStamp
        await guarded.selectHostingHubItem(projectB)
        let beforeStaleConfirmation = Hosting.requests.count
        let staleConfirmationRan = await guarded.hostingHubAction(expected: capturedConfirmation) { c in
            try await HostingHubAPI.saveProjectDraft(c, detail: guarded.hostingHub.detail!, title: "Wrong project", body: "")
        }
        precondition(!staleConfirmationRan && mutations == 0 && Hosting.requests.count == beforeStaleConfirmation, "A confirmation captured in one project executed in another")
        let currentConfirmation = guarded.hubActionStamp
        loseNextCreation = true
        let firstCreation = await guarded.hostingHubAction(expected: currentConfirmation) { c in
            try await HostingHubAPI.saveProjectDraft(c, detail: guarded.hostingHub.detail!, title: "Draft", body: "")
        }
        precondition(!firstCreation && guarded.hostingHub.uncertainWrite && !guarded.hostingHub.busy && mutations == 1, "Lost creation did not block duplicate writes")
        let beforeDuplicate = Hosting.requests.count
        let duplicateCreation = await guarded.hostingHubAction(expected: guarded.hubActionStamp) { c in
            try await HostingHubAPI.saveProjectDraft(c, detail: guarded.hostingHub.detail!, title: "Draft", body: "")
        }
        precondition(!duplicateCreation && mutations == 1 && Hosting.requests.count == beforeDuplicate, "An uncertain creation could be repeated without refreshing")
        failNextRead = true
        await guarded.selectHostingHubItem(projectB)
        precondition(guarded.hostingHub.uncertainWrite && guarded.hostingHub.error != nil, "A failed refresh unlocked uncertain writes")
        await guarded.selectHostingHubItem(projectB)
        precondition(!guarded.hostingHub.uncertainWrite && guarded.hostingHub.error == nil, "A successful project refresh did not restore writes")
        let verifiedCreation = await guarded.hostingHubAction(expected: guarded.hubActionStamp) { c in
            try await HostingHubAPI.saveProjectDraft(c, detail: guarded.hostingHub.detail!, title: "Confirmed after refresh", body: "")
        }
        precondition(verifiedCreation && mutations == 2 && !guarded.hostingHub.busy, "A refreshed project remained blocked")
        let delayed = fixture()
        accounts.set(.ready, for: first); accounts.holdTokenLoads = true
        let delayedRead = Task { await delayed.activateHostingHub(.projects) }
        await until { accounts.pendingToken(first) }
        let beforeRevision = accounts.revision
        accounts.finishToken(first)
        await delayedRead.value
        precondition(accounts.revision > beforeRevision && Hosting.requests.count == 1 && delayed.hostingHub.items.first?.id == first.username,
                     "A normal delayed credential read must accept its own completion revision")

        for switchAccount in [false, true] {
            let waiting = fixture()
            accounts.set(.ready, for: first); accounts.holdTokenLoads = true
            let read = Task { await waiting.activateHostingHub(.projects) }
            await until { accounts.pendingToken(first) }
            if switchAccount { waiting.hostingHub.selectedAccountID = second.id }
            else { waiting.url = URL(fileURLWithPath: "/fixture/changed", isDirectory: true) }
            accounts.finishToken(first)
            await read.value
            precondition(Hosting.requests.isEmpty, "A delayed token loaded a switched repository or hub account")
        }
        let changedProject = fixture()
        accounts.set(.ready, for: first)
        changedProject.hostingHub.section = .projects
        changedProject.hostingHub.detail = HubDetail(item: projectA)
        accounts.holdTokenLoads = true
        var delayedWrites = 0
        let delayedAction = Task { await changedProject.hostingHubAction(expected: changedProject.hubActionStamp) { _ in delayedWrites += 1 } }
        await until { accounts.pendingToken(first) }
        changedProject.hostingHub.detail = HubDetail(item: projectB)
        changedProject.hostingHub.detailID = UUID()
        accounts.finishToken(first)
        let delayedSaved = await delayedAction.value
        precondition(!delayedSaved && delayedWrites == 0 && Hosting.requests.isEmpty, "A changed project reached an action after waiting for credentials")
        let localHub = fixture(), localStore = LocalProjectStore(storage: LocalHubMemory())
        HostingHubAPI.localProjectStore = localStore
        _ = try! await localStore.create(title: "Synthetic local plan")
        localHub.hostingHub.section = .projects; localHub.hostingHub.projectSource = "local"
        let localStamp = localHub.hubContextStamp, tokenCount = accounts.tokenLoadsCount
        let localAccess = try! await localHub.hubAccess()
        accounts.revision += 1
        precondition(localHub.hubContextStamp == localStamp && localAccess.isCurrent?() == true, "Account revisions must not invalidate the credential-free local planner")
        precondition(localHub.hubAccount == nil && localHub.hubCredentialState == nil && localHub.pendingHubCredentialAccount == nil)
        await localHub.activateHostingHub(.projects)
        precondition(localHub.hostingHub.items.count == 1 && localHub.hostingHub.items[0].title == "Synthetic local plan")
        precondition(accounts.tokenLoadsCount == tokenCount && Hosting.requests.isEmpty, "Local hub planning accessed account credentials or HTTP")
        let releases = fixture()
        releases.hostingAccount = second
        let releasesStamp = releases.hubContextStamp(in: .releases)
        precondition(releases.hostingHub.section == .releases && releases.hubAccount?.id == second.id, "Releases must use the repository's account, not the hub's pick")
        releases.hostingHub.section = .projects
        precondition(releases.hubAccount?.id == first.id && releases.hubContextStamp != releasesStamp && releases.hubContextStamp(in: .releases) == releasesStamp, "A page's own stamp must not move while the hub is on another section")
        let organization = fixture()
        accounts.set(.ready, for: first)
        let organizationItem = HubItem(id: "team", title: "Team")
        let previewPeople = (1...12).map { HubMember(id: String($0), name: "Person \($0)", role: "Member", username: "person\($0)") }
        var preview = HubDetail(item: organizationItem, organizationAccess: HubOrganizationAccess(role: "Owner", canInvite: true), members: previewPeople)
        preview.organizationSections["members"] = HubOrganizationSectionState(more: true, loaded: true)
        preview.organizationSections["repositories"] = HubOrganizationSectionState(more: true, loaded: true)
        preview.teams = [HubOrganizationTeam(id: "1", name: "Engineering", description: "", url: "", privacy: "closed", slug: "engineering", members: Array(previewPeople.prefix(6)), memberState: HubOrganizationSectionState(more: true, loaded: true))]
        organization.hostingHub.section = .organizations; organization.hostingHub.tab = "overview"; organization.hostingHub.detail = preview
        Hosting.handler = { request in
            if request.url!.path == "/graphql" { return try JSONSerialization.data(withJSONObject: ["data": [:]]) }
            precondition(request.url!.query!.contains("per_page=30") && request.url!.query!.contains("page=1"), "Preview pagination skipped the beginning of the full page")
            return try JSONSerialization.data(withJSONObject: (1...30).map { ["id": $0, "login": "person\($0)"] })
        }
        let beforeInline = organization.hubActionStamp
        await organization.loadOrganizationSection("members")
        precondition(organization.hostingHub.tab == "overview" && organization.hostingHub.detail!.members.count == 30 && organization.hostingHub.detail!.organizationSections["members"]!.page == 1)
        precondition(beforeInline != organization.hubActionStamp, "An inline read did not invalidate a previously reviewed write")
        await organization.loadOrganizationTeamMembers("1")
        precondition(organization.hostingHub.detail!.teams[0].members.count == 30 && organization.hostingHub.detail!.teams[0].memberState.page == 1)
        Hosting.handler = { request in
            if request.url!.path == "/graphql" { return try JSONSerialization.data(withJSONObject: ["data": [:]]) }
            precondition(request.url!.query!.contains("page=2"))
            return try JSONSerialization.data(withJSONObject: (31...35).map { ["id": $0, "login": "person\($0)"] })
        }
        await organization.loadOrganizationSection("members")
        precondition(organization.hostingHub.detail!.members.count == 35 && !organization.hostingHub.detail!.organizationSections["members"]!.more)
        Hosting.handler = { _ in throw HostingError(status: 403) }
        await organization.loadOrganizationSection("repositories")
        precondition(organization.hostingHub.detail!.organizationSections["repositories"]!.error != nil && organization.hostingHub.detail!.members.count == 35 && organization.hostingHub.error == nil, "One failed section hid the rest of the dashboard")
        organization.hostingHub.detail!.organizationSections["members"]!.more = true
        accounts.holdTokenLoads = true
        let staleInline = Task { await organization.loadOrganizationSection("members") }
        await until { accounts.pendingToken(first) }
        let overlappingWrite = await organization.hostingHubAction(expected: organization.hubActionStamp) { _ in fatalError("Dashboard read overlapped a write") }
        precondition(!overlappingWrite && organization.hubOrganizationLoading)
        organization.hostingHub.detail = HubDetail(item: HubItem(id: "other", title: "Other"))
        organization.hostingHub.detailID = UUID()
        let requestCount = Hosting.requests.count
        accounts.finishToken(first)
        await staleInline.value
        precondition(organization.hostingHub.detail?.item.id == "other" && organization.hostingHub.detail!.members.isEmpty && Hosting.requests.count == requestCount, "A stale dashboard page replaced the selected organization")
        print("Hosting hub credentials: pending reads, silent denial, explicit selected-account recovery, missing credentials, stale approvals, project-bound confirmations, awaited token guards, credential-free local planning, repository-bound releases uncertain-write recovery, dashboard deduplicated preview/full pagination, independent failures, read/write exclusion and stale organization reads passed (fake credentials and HTTP only)")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
    "$ROOT/Sources/Core/CredentialCache.swift" \
    "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" \
    "$ROOT/Sources/Store/RepoStore+HostingHub.swift" "$ROOT/Sources/Store/RepoStore+Organizations.swift" \
    "$TASK_TMP/main.swift" -o "$TASK_TMP/test-hosting-hub-credentials"
"$TASK_TMP/test-hosting-hub-credentials"
