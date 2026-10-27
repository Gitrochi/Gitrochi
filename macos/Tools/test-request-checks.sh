#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum Provider { case github, gitlab }
struct RepoTarget { let provider: Provider; let host: String; let path: String }
struct PullRequest { let number: Int; let title: String; let author: String; let source: String; let target: String; let url: String; let isDraft: Bool; let updated: Date?; let body: String; let headSHA: String?; let fromFork: Bool }
@MainActor enum Hosting {
    static var handler: (URLRequest) async throws -> Data = { _ in fatalError("Unexpected HTTP") }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    static func data(_ request: URLRequest) async throws -> Data { try await handler(request) }
    static func projectID(_ path: String) -> String { path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~")))! }
    static func date(_ value: String?) -> Date? { nil }
}
struct FixtureFailure: LocalizedError {
    var errorDescription: String? { "HTTP 403 fixture-token Authorization: Bearer hidden-secret" }
}

@main struct RequestCheckTests {
    @MainActor static func main() async throws {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func query(_ request: URLRequest, _ key: String) -> String? { URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value }
        let github = ReviewAccess(target: RepoTarget(provider: .github, host: "github.com", path: "team/repo"), token: "fixture-token", apiBase: "https://api.github.com", me: "me")
        let gitlab = ReviewAccess(target: RepoTarget(provider: .gitlab, host: "gitlab.test", path: "team/repo"), token: "fixture-token", apiBase: "https://gitlab.test/api/v4", me: "me")
        var calls: [URLRequest] = []
        Hosting.handler = { request in
            calls.append(request)
            precondition(request.httpMethod == "GET" && request.url!.path.contains("/commits/head-a/"))
            precondition(query(request, "per_page") == "100")
            let page = query(request, "page")!
            if request.url!.path.hasSuffix("/check-runs") {
                precondition(query(request, "filter") == "latest")
                let ids = page == "1" ? Array(1...100) : [100, 101]
                return try json(["check_runs": ids.map { id in
                    ["id": id, "name": "Check \(id)", "status": id == 101 ? "in_progress" : "completed", "conclusion": "success",
                     "html_url": id == 1 ? "https://github.com/team/repo/actions/runs/44/job/9001" : id == 2 ? "https://ci.example/job/99" : id == 3 ? "https://github.com/other/repo/actions/runs/44/job/999" : "https://ci.example/checks/\(id)", "details_url": id == 1 ? "https://ci.example/result/1" : "",
                     "output": ["title": "Result \(id)", "summary": "Summary", "text": "Details"]] as [String: Any]
                }])
            }
            precondition(request.url!.path.hasSuffix("/statuses"))
            let ids = page == "1" ? Array(1...100) : [1, 101]
            return try json(ids.map { id in
                ["id": id, "context": "Status \(id)", "state": page == "1" ? "success" : id == 1 ? "failure" : "pending", "description": page == "1" ? "Latest result" : "Older result", "target_url": "https://ci.example/status/\(id)"]
            })
        }
        let paginated = try await RequestChecksAPI.load(github, number: 7, headSHA: "head-a")
        precondition(calls.count == 4 && paginated.warnings.isEmpty && paginated.checks.count == 202)
        precondition(paginated.checks.filter { $0.id == "check:100" }.count == 1)
        precondition(paginated.checks.first { $0.id == "status:Status 1" }?.status == .success, "An older commit status replaced the latest result")
        precondition(paginated.checks.first { $0.id == "status:Status 101" }?.status == .pending)
        precondition(paginated.checks.first { $0.id == "check:101" }?.status == .running)
        precondition(paginated.checks[0].jobID == 9001 && paginated.checks[1].jobID == nil && paginated.checks[2].jobID == nil, "External or other-repository job paths must not be used as Actions job IDs")
        precondition(paginated.checks[0].url == "https://ci.example/result/1" && paginated.checks[1].url == "https://ci.example/job/99", "Check result links must prefer details_url while logs keep the Actions job ID")
        precondition(paginated.checks[0].output == "Summary\n\nDetails" && paginated.checks[0].detail == "Result 1")

        // One inaccessible source preserves useful results and visibly warns about the missing source.
        Hosting.handler = { request in
            if request.url!.path.hasSuffix("/check-runs") { throw FixtureFailure() }
            return try json([["context": "External CI", "state": "failure", "description": "Build failed"]])
        }
        let partial = try await RequestChecksAPI.load(github, number: 7, headSHA: "head-a")
        precondition(partial.checks.count == 1 && partial.checks[0].status == .failed && partial.warnings.count == 1)
        precondition(!partial.warnings[0].contains("fixture-token") && !partial.warnings[0].contains("hidden-secret"))
        Hosting.handler = { _ in throw FixtureFailure() }
        let unavailable = try await RequestChecksAPI.load(github, number: 7, headSHA: "head-a")
        precondition(unavailable.checks.isEmpty && unavailable.warnings.count == 2, "Unavailable results were presented as an empty successful response")
        Hosting.handler = { request in try json(request.url!.path.hasSuffix("/check-runs") ? ["check_runs": "invalid"] as Any : [] as Any) }
        let malformed = try await RequestChecksAPI.load(github, number: 7, headSHA: "head-a")
        precondition(malformed.checks.isEmpty && malformed.warnings.count == 1, "A malformed check response was presented as an empty successful response")
        Hosting.handler = { request in
            if request.url!.path.hasSuffix("/statuses") { throw FixtureFailure() }
            if query(request, "page") == "2" { throw FixtureFailure() }
            return try json(["check_runs": (1...100).map { ["id": $0, "name": "Check \($0)", "status": "completed", "conclusion": "success"] as [String: Any] }])
        }
        let partialPage = try await RequestChecksAPI.load(github, number: 7, headSHA: "head-a")
        precondition(partialPage.checks.count == 100 && partialPage.warnings.count == 2, "A failed later page hid earlier check results")

        // GitLab merged-result pipelines may have a SHA and project different from the source branch.
        calls = []
        Hosting.handler = { request in
            calls.append(request)
            if request.url!.path.hasSuffix("/merge_requests/7") {
                return try json(["sha": "source-head", "head_pipeline": ["id": 88, "project_id": 999, "sha": "merged-result-head", "status": "running", "web_url": "https://gitlab.test/fork/repo/-/pipelines/88"]])
            }
            precondition(request.url!.path == "/api/v4/projects/999/pipelines/88/jobs")
            precondition(query(request, "include_retried") == "false" && query(request, "per_page") == "100")
            let ids = query(request, "page") == "1" ? Array(1...100) : [100, 101]
            return try json(ids.map { id in ["id": id, "name": "Job \(id)", "stage": "test", "status": id == 101 ? "manual" : "success", "allow_failure": id == 101, "web_url": "https://gitlab.test/fork/repo/-/jobs/\(id)"] as [String: Any] })
        }
        let pipeline = try await RequestChecksAPI.load(gitlab, number: 7, headSHA: "source-head")
        precondition(calls.count == 3 && pipeline.checks.count == 102 && pipeline.warnings.isEmpty)
        precondition(pipeline.checks[0].id == "pipeline:88" && pipeline.checks[0].status == .running)
        precondition(pipeline.checks.last?.id == "job:101" && pipeline.checks.last?.status == .manual && pipeline.checks.last?.logProjectID == 999)
        precondition(pipeline.checks.last?.detail == "test · Allowed to fail" && pipeline.checks.last?.jobID == 101)
        let logAccess = ReviewAccess(target: RepoTarget(provider: .gitlab, host: gitlab.target.host, path: String(pipeline.checks.last!.logProjectID!)), token: gitlab.token, apiBase: gitlab.apiBase, me: gitlab.me)
        let logEndpoint = try WorkspaceCILog.endpoint(logAccess, job: 101)
        precondition(logEndpoint.absoluteString == "https://gitlab.test/api/v4/projects/999/jobs/101/trace")
        precondition(!calls.contains { $0.url!.absoluteString.contains("sha=") }, "An MR's authoritative merged-result pipeline was replaced by a branch SHA search")
        Hosting.handler = { request in
            if request.url!.path.hasSuffix("/merge_requests/7") { return try json(["head_pipeline": ["id": 88, "status": "failed"]]) }
            precondition(request.url!.absoluteString.contains("/projects/team%2Frepo/pipelines/88/jobs"))
            throw FixtureFailure()
        }
        let missingJobs = try await RequestChecksAPI.load(gitlab, number: 7, headSHA: "source-head")
        precondition(missingJobs.checks.count == 1 && missingJobs.checks[0].status == .failed && missingJobs.warnings.count == 1)
        Hosting.handler = { _ in try json(["head_pipeline": NSNull()]) }
        let noPipeline = try await RequestChecksAPI.load(gitlab, number: 7, headSHA: "source-head")
        precondition(noPipeline.checks.isEmpty && noPipeline.warnings.isEmpty)

        // Changed accounts and cancelled loads never publish old or deceptively empty results.
        for provider in [github, gitlab] {
            var stale = provider
            stale.isCurrent = { false }
            var requests = 0
            Hosting.handler = { _ in requests += 1; return try json([:]) }
            do { _ = try await RequestChecksAPI.load(stale, number: 7, headSHA: "head-a"); fatalError("A stale account returned checks") } catch {}
            precondition(requests == 0)
            var current = true, changing = provider
            changing.isCurrent = { current }
            Hosting.handler = { request in
                current = false
                return try json(request.url!.path.hasSuffix("/check-runs") ? ["check_runs": []] : ["head_pipeline": NSNull()])
            }
            do { _ = try await RequestChecksAPI.load(changing, number: 7, headSHA: "head-a"); fatalError("Changed context returned checks") }
            catch is CancellationError {} catch { fatalError("Changed context did not report cancellation: \(error)") }
            Hosting.handler = { _ in throw CancellationError() }
            do { _ = try await RequestChecksAPI.load(provider, number: 7, headSHA: "head-a"); fatalError("Cancellation became a check warning") }
            catch is CancellationError {} catch { fatalError("Cancellation was replaced: \(error)") }
            var cancelled: Task<RequestCheckResults, Error>?
            Hosting.handler = { request in
                cancelled?.cancel()
                return try json(request.url!.path.hasSuffix("/check-runs") ? ["check_runs": []] : ["head_pipeline": NSNull()])
            }
            cancelled = Task { @MainActor in try await RequestChecksAPI.load(provider, number: 7, headSHA: "head-a") }
            do { _ = try await cancelled!.value; fatalError("A cancelled task returned checks") }
            catch is CancellationError {} catch { fatalError("Task cancellation was replaced: \(error)") }
        }
        print("Request checks: GitHub check/status pagination and latest deduplication, partial failures/redaction, GitLab merged-result pipeline/job routing, stale context and cancellation passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
    "$ROOT/Sources/Services/CIModels.swift" \
    "$ROOT/Sources/Services/Collaboration.swift" \
    "$ROOT/Sources/Services/WorkspaceCILog.swift" \
    "$ROOT/Sources/Services/RequestChecks.swift" \
    "$TASK_TMP/main.swift" -o "$TASK_TMP/test-request-checks"
"$TASK_TMP/test-request-checks"
