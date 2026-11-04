import Foundation
import Observation

/// Settings › Ledger › Team hub (docs/ledger/DESIGN.md §14 D4): off until a person turns it on. While it is on, this
/// computer's live Ledger sessions are shared with the team hub the app already reads under Work validation › Team
/// overlap evidence — its URL, and its token in the Keychain. What a session's entry holds is the core's `hub_share`;
/// this only sends it, when `rev` moves and every four minutes, and withdraws entries whose session closed or is
/// archived, or all of them when sharing is turned off. An unreachable hub only changes the status line, and passes wait
/// longer after each failure. The hub's answers carry overlaps with other members' sessions, which the inspector shows
/// under Touches. With it off nothing is read or sent. (Windows: entities/ledger/model/hub-sharing.ts)
@MainActor @Observable
final class LedgerHubSharing {
    static let shared = LedgerHubSharing()
    static let enabledKey = "ledgerHubSharing"
    static let computerKey = "ledgerHubComputer"
    /// Where TeamHubPanel keeps the hub it connected to
    static let endpointKey = "teamHubEndpoint"

    enum Status: Equatable {
        case off
        /// The demo backend: its sessions are not real work
        case demo
        /// No hub connected under Work validation
        case noHub
        case connecting(host: String)
        case sharing(host: String, count: Int, unshared: Int, plain: Bool)
        case unreachable(host: String)
        case rejected(host: String)
    }

    private(set) var status: Status = .off
    /// This computer's session → other computers' sessions touching the same things
    private(set) var overlaps: [String: [LedgerHubOverlap]] = [:]

    private let defaults: UserDefaults
    private let ledger: @MainActor () -> LedgerClient
    private var loop: Task<Void, Never>?
    private var busy = false
    /// Moves when sharing stops or the hub changes, so a pass that was under way drops its results
    private var generation = 0
    private var endpoint: String?
    private var token: String?
    private var member: String?
    private var published: [String: LedgerHubShare.Published] = [:]
    private var overlapsByRepo: [String: [TeamHub.Overlap]] = [:]
    /// The hub predates the `ledger` field
    private var plain = false
    private var lastRev = -1
    private var lastFull: LedgerMs = 0
    private var failures = 0
    private var retryAt: LedgerMs = 0

    init(defaults: UserDefaults = .standard, ledger: @escaping @MainActor () -> LedgerClient = { LedgerStore.shared.client }) {
        self.defaults = defaults
        self.ledger = ledger
    }

    var isOn: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The connected hub's URL, when there is a valid one
    var hubEndpoint: String? {
        guard let value = defaults.string(forKey: Self.endpointKey), !value.isEmpty else { return nil }
        return (try? TeamHub.endpoint(value))?.absoluteString
    }

    /// The person turned sharing on or off. Turning it on reads the hub token now, while the person can allow it.
    func setOn(_ on: Bool) async {
        defaults.set(on, forKey: Self.enabledKey)
        if on, let url = hubEndpoint {
            if url != endpoint { reset() }
            endpoint = url
            token = await Keychain.get(Self.secret(url))
        }
        refresh()
    }

    /// Starts or stops as the switch says; the app calls it at launch
    func refresh() {
        guard isOn else {
            loop?.cancel()
            loop = nil
            if !published.isEmpty || status != .off { Task { await stop() } }
            return
        }
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pass()
                    try? await Task.sleep(for: LedgerHubShare.tick)
                }
            }
        } else {
            lastRev = -1
            retryAt = 0
        }
    }

    /// One pass: read `rev`; when it moved or a refresh is due, report what changed and withdraw what went away
    private func pass() async {
        guard isOn, !busy else { return }
        busy = true
        defer { busy = false }
        let client = ledger()
        guard client.backend is NativeLedgerBackend else { return setStatus(.demo) }
        guard let url = hubEndpoint else {
            reset()
            return setStatus(.noHub)
        }
        if url != endpoint {
            reset()
            endpoint = url
        }
        let mine = generation
        let host = URL(string: url)?.host ?? url
        let now = LedgerStore.localNow()
        guard now >= retryAt else { return }
        if token == nil {
            // a silent read: in the background the Keychain never asks; turning sharing on again asks
            token = await Keychain.read(Self.secret(url)).value
            guard mine == generation, isOn else { return }
        }
        guard let token, !token.isEmpty else {
            retryAt = now + 600_000
            return setStatus(.rejected(host: host))
        }
        if case .sharing = status {} else if case .connecting = status {} else { setStatus(.connecting(host: host)) }
        let full = now - lastFull >= LedgerHubShare.refreshMs
        guard let rev = try? await client.rev(), rev != lastRev || full,
              let share = try? await client.hubShare(computer: computer()),
              mine == generation, isOn else { return }
        let plan = LedgerHubShare.plan(share.sessions, published: published, plain: plain, full: full)
        for post in plan.post {
            guard let answer = try? await TeamHub.publish(endpoint: url, body: post.body, token: token) else { return fail(host) }
            guard mine == generation, isOn else { return }
            switch answer.outcome {
            case .accepted:
                published[post.client] = .init(repo: post.repo, body: post.body, accepted: true)
                member = answer.member ?? member
                overlapsByRepo[post.repo] = answer.overlaps
            case .skipped:
                published[post.client] = .init(repo: post.repo, body: post.body, accepted: false)
            case .plainBodyNeeded:
                // the next pass sends the same sessions without `ledger`
                plain = true
                lastRev = -1
                return
            case .rejected:
                self.token = nil
                retryAt = now + 600_000
                return setStatus(.rejected(host: host))
            case .limited, .unreachable:
                return fail(host)
            }
        }
        for gone in plan.withdraw {
            guard let outcome = try? await TeamHub.withdraw(endpoint: url, repo: gone.repo, client: gone.client, token: token) else { return fail(host) }
            guard mine == generation, isOn else { return }
            switch outcome {
            case .accepted, .skipped, .plainBodyNeeded:
                if published[gone.client]?.repo == gone.repo { published[gone.client] = nil }
            case .rejected:
                self.token = nil
                retryAt = now + 600_000
                return setStatus(.rejected(host: host))
            case .limited, .unreachable:
                return fail(host)
            }
        }
        let repos = Set(published.values.map(\.repo))
        overlapsByRepo = overlapsByRepo.filter { repos.contains($0.key) }
        failures = 0
        lastRev = rev
        if full { lastFull = now }
        setStatus(.sharing(host: host, count: published.values.filter(\.accepted).count, unshared: share.unshared.filter { $0.reason == "no_remote" }.count, plain: plain))
        updateOverlaps()
    }

    /// Sharing was turned off: withdraws every entry this app reported (once; the hub forgets the rest within minutes)
    private func stop() async {
        let entries = published, url = endpoint, token = token
        reset()
        setStatus(.off)
        guard let url, let token else { return }
        for (client, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard (try? await TeamHub.withdraw(endpoint: url, repo: entry.repo, client: client, token: token)) != nil else { return }
        }
    }

    /// Forgets the hub's state: a new hub or token, or sharing turned off
    private func reset() {
        generation += 1
        published = [:]
        overlapsByRepo = [:]
        member = nil
        plain = false
        lastRev = -1
        lastFull = 0
        failures = 0
        retryAt = 0
        endpoint = nil
        token = nil
        if !overlaps.isEmpty { overlaps = [:] }
    }

    private func fail(_ host: String) {
        failures += 1
        retryAt = LedgerStore.localNow() + LedgerHubShare.backoff(failures: failures)
        setStatus(.unreachable(host: host))
    }

    private func updateOverlaps() {
        let rows = overlapsByRepo.values.flatMap { $0 }.map { row in
            LedgerHubShare.Pair(a: .init(member: row.a.member, client: row.a.client, branch: row.a.branch),
                                b: .init(member: row.b.member, client: row.b.client, branch: row.b.branch), paths: row.paths)
        }
        let next = member.map { LedgerHubShare.overlaps(rows, member: $0, computer: computer()) } ?? [:]
        if next != overlaps { overlaps = next }
    }

    private func setStatus(_ value: Status) {
        if status != value { status = value }
    }

    /// This computer's random name on the hub, made once
    private func computer() -> String {
        if let name = defaults.string(forKey: Self.computerKey), !name.isEmpty { return name }
        let name = LedgerHubShare.newComputer()
        defaults.set(name, forKey: Self.computerKey)
        return name
    }

    /// The Keychain item TeamHubPanel keeps the hub's token in
    static func secret(_ endpoint: String) -> String { "teamHub:" + endpoint }
}
