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
struct PullRequest { let number: Int; let title: String; let author: String; let source: String; let target: String; let url: String; let isDraft: Bool; let updated: Date?; let body: String; let headSHA: String?; let fromFork: Bool; var comments: Int? = nil; var reviewRequested = false; var authorAvatarURL: String? = nil }
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
        // the Actions page reads the same run and job models
        func run(_ id: Int, _ status: CIStatus, ref: String = "topic", name: String = "CI", title: String = "Run") -> CIPipeline {
            CIPipeline(id: id, number: id, name: name, title: title, ref: ref, sha: "s\(id)", status: status, url: "", created: Date(timeIntervalSince1970: Double(id)), event: "push", actor: nil)
        }
        let runs = [run(9, .running, ref: "other"), run(8, .waiting, ref: "main", name: "Deploy"), run(7, .success, ref: "main"), run(6, .success), run(5, .failed, ref: "fix", title: "Rework focus"), run(4, .success), run(3, .success), run(2, .canceled, ref: "x")]
        precondition(ActionsPage.Segment.allCases.map { ActionsPage.count(runs, $0) } == [8, 1, 1, 1], "Failed, Running and Waiting count their runs; a cancelled or passed run is only under All")
        precondition(ActionsPage.visible(runs, segment: .failed, search: "", oldestFirst: false) { $0.title }.map(\.id) == [5] && ActionsPage.visible(runs, segment: .all, search: " MAIN ", oldestFirst: true) { $0.title }.map(\.id) == [7, 8], "A segment filters, the search matches the branch and the order can be reversed")
        precondition(ActionsPage.visible(runs, segment: .all, search: "focus", oldestFirst: false) { $0.title }.map(\.id) == [5] && ActionsPage.visible(runs, segment: .all, search: "#4", oldestFirst: false) { $0.title }.map(\.id) == [4] && ActionsPage.visible(runs, segment: .all, search: "deploy", oldestFirst: false) { $0.title }.map(\.id) == [8], "The search matches the title, the number and the workflow")
        precondition(ActionsPage.commonWorkflow(runs) == "CI" && ActionsPage.commonWorkflow([]) == nil, "The workflow most runs belong to goes without saying")
        precondition(ActionsPage.history([run(20, .success, ref: "mixed", name: "Windows"), run(19, .failed, ref: "mixed", name: "macOS"), run(18, .success, ref: "mixed", name: "Windows")], ref: "mixed").map(\.id) == [18, 20], "The summary follows one workflow")
        precondition(ActionsPage.history(runs, ref: "topic").map(\.id) == [3, 4, 6] && ActionsPage.history(runs, ref: "topic", limit: 2).map(\.id) == [4, 6] && ActionsPage.history(runs, ref: nil).isEmpty, "This branch's latest runs, oldest first")
        precondition(ActionsPage.streak(ActionsPage.history(runs, ref: "topic")) == .passing(3) && ActionsPage.streak([run(1, .failed), run(2, .success)]) == .passing(1), "A streak counts the runs that passed in a row, newest back")
        precondition(ActionsPage.streak([run(1, .success), run(2, .failed)]) == .failed(run(2, .failed)) && ActionsPage.streak([run(1, .success), run(2, .pending)]) == .running(run(2, .pending)) && ActionsPage.streak([run(2, .manual)]) == .waiting(run(2, .manual)) && ActionsPage.streak([run(2, .canceled)]) == .none && ActionsPage.streak([]) == .none, "The newest run decides what the summary says")
        var timed = run(1, .success), going = run(2, .running)
        timed.started = Date(timeIntervalSince1970: 100); timed.updated = Date(timeIntervalSince1970: 448)
        going.started = Date(timeIntervalSince1970: 100); going.updated = Date(timeIntervalSince1970: 448)
        precondition(ActionsPage.took(timed) == 348 && ActionsPage.took(going) == nil && ActionsPage.took(run(3, .success)) == nil, "Only a finished run with both times says how long it took")
        precondition(ActionsPage.baseRef(["topic", "master", "main"]) == "main" && ActionsPage.baseRef(["topic", "master"]) == "master" && ActionsPage.baseRef(["topic"]) == nil, "Runs are compared with main, or master where there is no main")
        func job(_ id: Int, _ status: CIStatus) -> CIJob { CIJob(id: id, name: "job\(id)", stage: "", status: status, url: "", allowFailure: false, duration: nil) }
        let groups = ActionsPage.groups([job(1, .success), job(2, .failed), job(3, .skipped), job(4, .manual), job(5, .running), job(6, .success)])
        precondition(groups.map(\.group) == [.failed, .running, .waiting, .passed, .other] && groups.map { $0.jobs.map(\.id) } == [[2], [5], [4], [1, 6], [3]], "Jobs are grouped by result, what failed first")
        precondition(JobLog.isError("TerminalFocusTests.swift:58: error: XCTAssertTrue failed") && JobLog.isError("Error: Process completed with exit code 1.") && JobLog.isError("FAIL: Update the dependency lockfile") && JobLog.isError("##[error]boom") && JobLog.isError("fatal: not a git repository"), "A line that names an error is marked")
        precondition(!JobLog.isError("Test Suite 'TerminalFocusTests' started.") && !JobLog.isError("Checked 12 terrors, errorless") && !JobLog.isError("Executed 231 tests, with 1 failure"), "Words that only contain one are not")
        precondition(!JobLog.isError("curl --retry 10 --show-error --fail https://example.test") && !JobLog.isError("CACHE_ON_FAILURE: false"))
        precondition(JobLog.lines("2026-11-06T00:45:22.6820373Z ##[group]Run tests\r\n2026-11-06T00:45:22.68Z \u{1B}[36;1mmake\u{1B}[0m\n##[endgroup]\n##[error]Process completed\n##[start-action id=1]") == ["Run tests", "make", "Error: Process completed"])
        precondition(JobLog.firstShown(JobLog.numbered((1...46).map { $0 == 41 ? "x.swift:58: error: failed" : "line \($0)" })) == 37 && JobLog.firstShown(JobLog.numbered((1...500).map { "line \($0)" })) == 300 && JobLog.firstShown(JobLog.numbered(["one"])) == 0, "A log opens a few lines before its first error, or on its last two hundred lines")
        print("Request checks: GitHub check/status pagination and latest deduplication, partial failures/redaction, GitLab merged-result pipeline/job routing, stale context and cancellation, and the Actions page's segments, search, branch history, job groups and log errors passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
    "$ROOT/Sources/Services/CIModels.swift" \
    "$ROOT/Sources/Core/ActionsPage.swift" "$ROOT/Sources/Core/JobLog.swift" \
    "$ROOT/Sources/Services/Collaboration.swift" \
    "$ROOT/Sources/Services/WorkspaceCILog.swift" \
    "$ROOT/Sources/Services/RequestChecks.swift" \
    "$TASK_TMP/main.swift" -o "$TASK_TMP/test-request-checks"
"$TASK_TMP/test-request-checks"
