import Foundation

/// Pinned, bounded reads of the existing team hub v1 API.
enum TeamHub {
    struct Participant: Codable { let member: String; let client: String; let branch: String; let head: String }
    struct Presence: Codable, Identifiable {
        let member: String; let client: String; let branch: String; let head: String
        let changed: [String]?; let related: [String]?; let updated: String; let expires: String
        var id: String { member + ":" + client }
    }
    struct Overlap: Codable, Identifiable {
        let kind: String; let a: Participant; let b: Participant; let paths: [String]
        var id: String { kind + ":" + a.member + ":" + a.client + ":" + b.member + ":" + b.client + ":" + paths.joined(separator: "|") }
    }
    struct Snapshot { let repo: String; let presence: [Presence]; let overlaps: [Overlap]; let observedAt: String }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func endpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw Failure(message: String(localized: "Use an HTTPS hub URL, or HTTP on loopback, without credentials or query parameters."))
        }
        return URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
    }

    static func repoKey(_ value: String) throws -> String {
        var key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix(".git") { key.removeLast(4) }
        if key.contains("://"), let url = URL(string: key), let host = url.host, url.scheme != "file" {
            key = host.lowercased() + url.path
        } else if let at = key.firstIndex(of: "@"), let colon = key[at...].firstIndex(of: ":") {
            key = String(key[key.index(after: at)..<colon]).lowercased() + "/" + key[key.index(after: colon)...]
        }
        guard let slash = key.firstIndex(of: "/"), slash != key.startIndex, WorkValidation.safePath(key),
              key[..<slash].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw Failure(message: String(localized: "Enter the repository key as host/owner/repository."))
        }
        return key[..<slash].lowercased() + key[slash...]
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    static func read(endpoint: String, repo: String, token: String) async throws -> Snapshot {
        struct PresenceList: Decodable { let repo: String; let presence: [Presence]? }
        struct OverlapList: Decodable { let repo: String; let overlaps: [Overlap]? }
        let base = try self.endpoint(endpoint), key = try repoKey(repo)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        @Sendable func fetch(_ resource: String) async throws -> Data {
            let url = base.appendingPathComponent("api/v1/repos").appendingPathComponent(key).appendingPathComponent(resource)
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: String(localized: "The team hub request was rejected. Check the URL and token.")) }
            var data = Data()
            for try await byte in bytes { guard data.count < 2_000_000 else { throw Failure(message: String(localized: "The team hub response is too large.")) }; data.append(byte) }
            return data
        }
        async let presenceData = fetch("presence")
        async let overlapData = fetch("overlaps")
        let p = try JSONDecoder().decode(PresenceList.self, from: await presenceData)
        let o = try JSONDecoder().decode(OverlapList.self, from: await overlapData)
        guard p.repo == key, o.repo == key, (p.presence?.count ?? 0) <= 1000, (o.overlaps?.count ?? 0) <= 5000 else { throw Failure(message: String(localized: "The team hub returned an invalid repository snapshot.")) }
        let formatter = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(), now = Date()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: String) -> Date? { fractional.date(from: value) ?? formatter.date(from: value) }
        let presence = (p.presence ?? []).filter { (date($0.expires) ?? .distantPast) > now && date($0.updated) != nil }
        let active = Set(presence.map { $0.member + "\0" + $0.client })
        var seen = Set<String>()
        let overlaps = (o.overlaps ?? []).filter { row in
            ["same-file", "related-file"].contains(row.kind) && row.a.member != row.b.member && active.contains(row.a.member + "\0" + row.a.client) && active.contains(row.b.member + "\0" + row.b.client) && presence.contains { $0.member == row.a.member && $0.client == row.a.client && $0.head == row.a.head && $0.branch == row.a.branch } && presence.contains { $0.member == row.b.member && $0.client == row.b.client && $0.head == row.b.head && $0.branch == row.b.branch } && !row.paths.isEmpty && row.paths.allSatisfy(WorkValidation.safePath) && seen.insert(row.id).inserted
        }
        return Snapshot(repo: key, presence: presence, overlaps: overlaps, observedAt: formatter.string(from: now))
    }
}
