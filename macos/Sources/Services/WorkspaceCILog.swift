import Foundation

private final class CILogRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let github: Bool
    init(github: Bool) { self.github = github }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
            let host = url.host?.lowercased()
        else { return false }
        return host == "api.github.com" || host == "github.com"
            || host.hasSuffix(".githubusercontent.com") || host.hasSuffix(".blob.core.windows.net")
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard github, let url = request.url, Self.allowed(url) else {
            completionHandler(nil)
            return
        }
        var next = URLRequest(url: url, timeoutInterval: 30)
        next.setValue("Gitrochi", forHTTPHeaderField: "User-Agent")
        completionHandler(next)
    }
}

@MainActor enum WorkspaceCILog {
    struct Result {
        let body: String
        let truncated: Bool
    }
    static func endpoint(_ c: ReviewAccess, job: Int) throws -> URL {
        guard job > 0, let base = URL(string: c.apiBase), base.scheme == "https", base.user == nil,
            base.password == nil, base.query == nil, base.fragment == nil,
            !c.target.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            })
        else { throw CollaborationAPI.fail(String(localized: "Invalid CI log request.")) }
        if c.target.provider == .github {
            guard base.host == "api.github.com", base.port == nil || base.port == 443,
                base.path.isEmpty || base.path == "/"
            else {
                throw CollaborationAPI.fail(String(localized: "Invalid CI log request."))
            }
            return base.appendingPathComponent("repos/\(c.target.path)/actions/jobs/\(job)/logs")
        }
        guard base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("api/v4"),
            let endpoint = URL(
                string: c.apiBase
                    + "/projects/\(Hosting.projectID(c.target.path))/jobs/\(job)/trace")
        else { throw CollaborationAPI.fail(String(localized: "Invalid CI log request.")) }
        return endpoint
    }
    static func redact(_ body: String, token: String = "") -> String {
        let plain = body.replacingOccurrences(
            of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        var value =
            token.isEmpty ? plain : plain.replacingOccurrences(of: token, with: "[redacted]")
        let patterns = [
            (
                #"(?i)-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|$)"#,
                "[redacted private key]"
            ),
            (
                #"(?i)(\b[\w-]*(?:authorization|token|password|secret|api[_-]?key)\b["']?\s*[:=]\s*")(?:\\.|[^"\\\r\n])*(")"#,
                "$1[redacted]$2"
            ),
            (
                #"(?i)(\b[\w-]*(?:authorization|token|password|secret|api[_-]?key)\b["']?\s*[:=]\s*')(?:\\.|[^'\\\r\n])*(')"#,
                "$1[redacted]$2"
            ),
            (
                #"(?i)(\b[\w-]*(?:authorization|token|password|secret|api[_-]?key)\b["']?\s*[:=]\s*)(?:Bearer\s+)?[^"'\s,;}]+"#,
                "$1[redacted]"
            ),
            (
                #"\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|glpat-[A-Za-z0-9_-]{12,})\b"#,
                "[redacted]"
            ),
        ]
        for (pattern, replacement) in patterns {
            value = value.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression)
        }
        return value
    }
    static func load(_ c: ReviewAccess, job: Int) async throws -> Result {
        guard c.isCurrent?() != false else {
            throw CollaborationAPI.fail(
                String(localized: "The repository or account changed. Reopen this action."))
        }
        let url = try endpoint(c, job: job)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = try Hosting.request(c.target.provider, url.absoluteString, token: c.token)
        let (stream, response) = try await session.bytes(
            for: request, delegate: CILogRedirectDelegate(github: c.target.provider == .github))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CollaborationAPI.fail(
                String(
                    localized:
                        "The CI log is not available. Open the job in the browser or try again after it finishes."
                ))
        }
        let limit = 2_000_000
        var bytes = Data()
        bytes.reserveCapacity(2_000_000)
        var truncated = false
        for try await byte in stream {
            if bytes.count == limit {
                truncated = true
                break
            }
            bytes.append(byte)
        }
        guard c.isCurrent?() != false, !Task.isCancelled else { throw CancellationError() }
        return Result(
            body: redact(String(decoding: bytes, as: UTF8.self), token: c.token),
            truncated: truncated)
    }
}
