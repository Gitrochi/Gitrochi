import Foundation
import Observation

/// A bounded memory cache isolates accounts and checks at most two repositories at once.
@MainActor @Observable final class ReleasePortfolio {
    static let shared = ReleasePortfolio()
    struct Summary {
        var status = "Not checked"
        var page: HubPage?
        var checkedAt: Date?
        var error: String?
    }
    private var entries: [String: Summary] = [:]
    private var running = 0
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    func key(_ store: RepoStore) -> String {
        [store.url?.path ?? "", store.target?.provider.rawValue ?? "", store.target?.host ?? "", store.target?.path ?? "", store.hostingAccount?.id ?? "", String(AccountStore.shared.revision)].joined(separator: "\0")
    }
    func entry(_ store: RepoStore) -> Summary { entries[key(store)] ?? Summary() }
    func refresh(_ stores: [RepoStore], force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for store in stores { group.addTask { @MainActor in await self.refreshOne(store, force: force) } }
        }
    }
    private func refreshOne(_ store: RepoStore, force: Bool) async {
        let stamp = key(store), previous = entries[stamp]
        if previous?.status == "Checking releases…" { return }
        if !force, let checked = previous?.checkedAt, Date().timeIntervalSince(checked) < 300 { return }
        entries[stamp] = Summary(status: "Checking releases…")
        if running >= 2 { await withCheckedContinuation { waiting.append($0) } } else { running += 1 }
        defer {
            if entries[stamp]?.status == "Checking releases…" { entries.removeValue(forKey: stamp) }
            if !waiting.isEmpty { waiting.removeFirst().resume() } else { running -= 1 }
            if entries.count > 100 { for (key, value) in entries where key != stamp && value.status != "Checking releases…" { if entries.count <= 100 { break }; entries.removeValue(forKey: key) } }
        }
        guard key(store) == stamp else { return }
        guard let target = store.target, let account = store.hostingAccount else { entries[stamp] = Summary(status: "Access required", checkedAt: Date(), error: String(localized: "Connect an account to check releases.")); return }
        guard let token = await AccountStore.shared.loadToken(for: account) else {
            if key(store) == stamp { entries[stamp] = Summary(status: "Access required", checkedAt: Date(), error: AccountStore.shared.savedAccessMessage(for: account)) }
            return
        }
        guard key(store) == stamp else { return }
        let access = HubAccess(target: target, token: token, apiBase: account.apiBase, me: account.username, isCurrent: { self.key(store) == stamp })
        do {
            let page = try await HostingHubAPI.page(access, section: .releases)
            guard key(store) == stamp else { return }
            entries[stamp] = Summary(status: page.items.isEmpty ? "No releases" : "Ready", page: page, checkedAt: Date())
        } catch {
            guard key(store) == stamp else { return }
            let message = HostingHubAPI.error(error, token: token)
            let status: String
            if let network = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(network.code) { status = "Offline" }
            else if let hosting = error as? HostingError, [401, 403].contains(hosting.status) { status = "Access required" }
            else { status = "Check failed" }
            entries[stamp] = Summary(status: status, checkedAt: Date(), error: message)
        }
    }
}
