#!/usr/bin/env bash
# Exercise the production hub store and cache without Keychain, accounts or network access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

    func reset(_ accounts: [HostAccount]) {
        precondition(approvals.isEmpty, "An approval fixture was left suspended")
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
    func credentialState(for account: HostAccount) -> CredentialCache.State { cache.state(account.id) }
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
        precondition(request.url?.host == "api.github.com" && request.url?.path == "/graphql", "Unexpected fixture request")
        requests.append(request)
        if let handler { return try handler(request) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let owner = (body["variables"] as! [String: Any])["owner"] as! String
        return try JSONSerialization.data(withJSONObject: ["data": ["user": ["projectsV2": ["nodes": [["id": owner, "title": "Fixture project"]], "pageInfo": ["hasNextPage": false]]]]])
    }
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
        precondition(denied.hubCredentialState == .authorizationRequired && denied.hostingHub.error == String(localized: "Allow access to the saved account to use repository services."), "Denied saved access was reported as a missing token")
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
        precondition(unavailable.hubCredentialState == .unavailable && unavailable.hostingHub.error == String(localized: "The selected account has no token. Reconnect it from Settings → Accounts."), "A genuinely missing credential lost its reconnect guidance")
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
        print("Hosting hub credentials: pending reads, silent denial, explicit selected-account recovery, missing credentials, stale approvals, project-bound confirmations and uncertain-write recovery passed (fake credentials and HTTP only)")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
    "$ROOT/Sources/Core/CredentialCache.swift" \
    "$ROOT/Sources/Services/HostingHub.swift" \
    "$ROOT/Sources/Store/RepoStore+HostingHub.swift" \
    "$TASK_TMP/main.swift" -o "$TASK_TMP/test-hosting-hub-credentials"
"$TASK_TMP/test-hosting-hub-credentials"
