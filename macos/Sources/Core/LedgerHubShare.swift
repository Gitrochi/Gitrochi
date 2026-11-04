import Foundation

/// What the core's `hub_share` answers: one team hub presence body per shared session. The core decides what is in a
/// body (crates/gitrochi-ledger CONTRACT.md, Sharing with the team hub); the app posts it as it is.
/// (Windows: entities/ledger/lib/hub-share.ts)
struct LedgerHubShareResult: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let sessionId: String
        let repo: String
        let client: String
        let presence: LedgerJSON
    }
    struct Unshared: Decodable, Sendable {
        let sessionId: String
        let reason: String
    }
    let rev: Int
    let sessions: [Item]
    let unshared: [Unshared]
}

/// Another computer's Ledger session that touches what one of this computer's sessions touches, as the hub found it
struct LedgerHubOverlap: Hashable, Identifiable, Sendable {
    let session: String
    let member: String
    let branch: String
    let paths: [String]
    var id: String { member + "\u{0}" + session }
}

/// The pure parts of sharing Ledger sessions with the team hub, kept apart so they mirror the tested Windows twin.
/// (Windows: entities/ledger/lib/hub-share.ts)
enum LedgerHubShare {
    /// Every entry is sent again this often, below the hub's 10-minute presence lifetime, which also refreshes overlaps
    static let refreshMs: LedgerMs = 240_000
    /// How often `rev` is read while sharing is on
    static let tick: Duration = .seconds(15)
    static let prefix = "ledger/"

    /// How the hub answered one report or withdrawal
    enum Outcome: Equatable, Sendable {
        case accepted
        /// A hub older than the `ledger` field: send the same body without it
        case plainBodyNeeded
        /// This one entry was refused; it is not sent again until it changes
        case skipped
        /// The token was not accepted
        case rejected
        case limited
        case unreachable
    }

    static func outcome(status: Int, body: String) -> Outcome {
        switch status {
        case 200..<300: return .accepted
        // the hub's JSON error message quotes the field: unknown field \"ledger\"
        case 400 where body.contains("unknown field \\\"ledger\\\""): return .plainBodyNeeded
        case 401, 403: return .rejected
        case 429: return .limited
        case 400..<500: return .skipped
        default: return .unreachable
        }
    }

    /// The wait after `failures` failed passes in a row: 30 s, doubling, at most 10 minutes
    static func backoff(failures: Int) -> LedgerMs {
        min(600_000, 30_000 << min(max(failures - 1, 0), 5))
    }

    /// A random name for this computer on the hub: says nothing about it, only stays the same
    static func newComputer() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// `ledger/<computer>/<session>` → its parts; nil for anything else, such as a monitor's entry
    static func parseClient(_ client: String) -> (computer: String, session: String)? {
        guard client.hasPrefix(prefix) else { return nil }
        let parts = client.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The body to post: the core's presence with sorted keys, so an unchanged session is recognised, and without
    /// `ledger` for a hub that predates it
    static func body(_ presence: LedgerJSON, plain: Bool) -> Data {
        var value = presence
        if plain, case .object(var object) = value {
            object["ledger"] = nil
            value = .object(object)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// One entry as the hub last accepted it
    struct Published: Equatable, Sendable {
        let repo: String
        let body: Data
        /// false when the hub refused this body; it is kept so it is not sent again until it changes
        let accepted: Bool
    }

    struct Post: Equatable, Sendable {
        let client: String
        let repo: String
        let body: Data
    }

    struct Withdrawal: Equatable, Sendable {
        let client: String
        let repo: String
    }

    /// What to send: new and changed sessions (all of them on a full refresh), and the entries of sessions that are no
    /// longer shared, to withdraw
    static func plan(_ items: [LedgerHubShareResult.Item], published: [String: Published], plain: Bool, full: Bool) -> (post: [Post], withdraw: [Withdrawal]) {
        var post: [Post] = []
        var wanted = Set<String>()
        for item in items {
            wanted.insert(item.client)
            let body = body(item.presence, plain: plain)
            let before = published[item.client]
            if full || before == nil || before?.body != body || before?.repo != item.repo {
                post.append(Post(client: item.client, repo: item.repo, body: body))
            }
        }
        let withdraw = published.filter { !wanted.contains($0.key) }
            .map { Withdrawal(client: $0.key, repo: $0.value.repo) }
            .sorted { $0.client < $1.client }
        // an entry that moved to another repository leaves the old one
        let moved = items.compactMap { item in
            published[item.client].flatMap { $0.repo != item.repo ? Withdrawal(client: item.client, repo: $0.repo) : nil }
        }
        return (post, withdraw + moved)
    }

    /// One side of an overlap the hub reported (TeamHub.Participant without the commit)
    struct Side: Equatable, Sendable {
        let member: String
        let client: String
        let branch: String
    }

    /// An overlap the hub reported, as the pure rules read it
    struct Pair: Equatable, Sendable {
        let a: Side
        let b: Side
        let paths: [String]
    }

    /// This computer's sessions → other computers' sessions touching the same things. The hub never overlaps one
    /// member's own entries; entries that are not Ledger sessions (a monitor's) are left out.
    static func overlaps(_ rows: [Pair], member: String, computer: String) -> [String: [LedgerHubOverlap]] {
        var out: [String: [LedgerHubOverlap]] = [:]
        for row in rows {
            for (mine, other) in [(row.a, row.b), (row.b, row.a)] {
                guard mine.member == member, other.member != member,
                      let own = parseClient(mine.client), own.computer == computer,
                      let theirs = parseClient(other.client) else { continue }
                var list = out[own.session] ?? []
                if let i = list.firstIndex(where: { $0.member == other.member && $0.session == theirs.session }) {
                    let paths = list[i].paths + row.paths.filter { !list[i].paths.contains($0) }
                    list[i] = LedgerHubOverlap(session: theirs.session, member: other.member, branch: list[i].branch, paths: paths)
                } else {
                    list.append(LedgerHubOverlap(session: theirs.session, member: other.member, branch: other.branch, paths: row.paths))
                }
                out[own.session] = list.sorted { ($0.member, $0.session) < ($1.member, $1.session) }
            }
        }
        return out
    }
}
