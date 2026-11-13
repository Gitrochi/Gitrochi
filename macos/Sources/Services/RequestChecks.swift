import Foundation

struct RequestCheck: Identifiable {
    var id: String
    var name: String
    var status: CIStatus
    var detail: String = ""
    var url: String = ""
    var output: String = ""
    var jobID: Int? = nil
    var logProjectID: Int? = nil
}
struct RequestCheckResults {
    var checks: [RequestCheck] = []
    var warnings: [String] = []
}

/// Read checks for the request head, including external check runs and commit statuses.
@MainActor enum RequestChecksAPI {
    static func load(_ c: ReviewAccess, number: Int, headSHA: String) async throws -> RequestCheckResults {
        let base = CollaborationAPI.repo(c)
        var result = RequestCheckResults()
        if c.target.provider == .github {
            let commit = base + "/commits/" + Hosting.projectID(headSHA)
            do {
                var page = 1
                while true {
                    let response = try await CollaborationAPI.object(c, commit + "/check-runs?filter=latest&per_page=100&page=\(page)")
                    guard let rows = response["check_runs"] as? [[String: Any]] else { throw CollaborationAPI.fail(String(localized: "The server returned an unexpected response.")) }
                    result.checks += rows.map { row in
                        let output = CollaborationAPI.obj(row, "output")
                        let text = [CollaborationAPI.text(output, "summary"), CollaborationAPI.text(output, "text")].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        let url = CollaborationAPI.text(row, "html_url")
                        let detailsURL = CollaborationAPI.text(row, "details_url")
                        // Actions check-run id and job id are different; obtain the job id from its canonical URL.
                        let pageURL = URL(string: url)
                        let parts = pageURL?.path.split(separator: "/").map(String.init) ?? []
                        let prefix = c.target.path.split(separator: "/").map(String.init) + ["actions", "runs"]
                        let isJobURL = pageURL?.scheme == "https" && pageURL?.host?.lowercased() == c.target.host.lowercased()
                            && pageURL?.user == nil && pageURL?.password == nil
                            && parts.count == prefix.count + 3 && Array(parts.prefix(prefix.count)).map { $0.lowercased() } == prefix.map { $0.lowercased() }
                            && Int(parts[prefix.count]) != nil && parts[prefix.count + 1] == "job"
                        let jobID = isJobURL ? Int(parts[parts.count - 1]).flatMap { $0 > 0 ? $0 : nil } : nil
                        return RequestCheck(id: "check:\(CollaborationAPI.number(row, "id"))", name: CollaborationAPI.text(row, "name"), status: CIStatus(github: row["status"] as? String, conclusion: row["conclusion"] as? String), detail: CollaborationAPI.text(output, "title"), url: detailsURL.isEmpty ? url : detailsURL, output: text, jobID: jobID)
                    }
                    if rows.count < 100 { break }; page += 1
                }
            } catch { try rethrowCancellation(error); result.warnings.append(String(localized: "Check runs could not be loaded.") + " " + safeError(error, c)) }
            do {
                var seen = Set<String>(), page = 1
                while true {
                    let rows = try await CollaborationAPI.list(c, commit + "/statuses?per_page=100&page=\(page)")
                    for row in rows {
                        let context = CollaborationAPI.text(row, "context")
                        guard seen.insert(context).inserted else { continue }
                        let state = CollaborationAPI.text(row, "state")
                        let status: CIStatus = state == "success" ? .success : ["failure", "error"].contains(state) ? .failed : state == "pending" ? .pending : .unknown
                        result.checks.append(RequestCheck(id: "status:" + context, name: context, status: status, detail: CollaborationAPI.text(row, "description"), url: CollaborationAPI.text(row, "target_url")))
                    }
                    if rows.count < 100 { break }; page += 1
                }
            } catch { try rethrowCancellation(error); result.warnings.append(String(localized: "Commit statuses could not be loaded.") + " " + safeError(error, c)) }
        } else {
            // head_pipeline is authoritative for merged-result/merge-train SHAs too.
            let request = try await CollaborationAPI.object(c, CollaborationAPI.requestURL(c, number))
            let pipeline = CollaborationAPI.obj(request, "head_pipeline")
            let pipelineID = CollaborationAPI.number(pipeline, "id")
            guard c.isCurrent?() != false, !Task.isCancelled else { throw CancellationError() }
            guard pipelineID > 0 else { return result }
            let projectID = CollaborationAPI.number(pipeline, "project_id")
            let pipelineBase = projectID > 0 ? c.apiBase + "/projects/\(projectID)" : base
            result.checks.append(RequestCheck(id: "pipeline:\(pipelineID)", name: String(localized: "Pipeline #\(pipelineID)"), status: CIStatus(gitlab: CollaborationAPI.text(pipeline, "status")), url: CollaborationAPI.text(pipeline, "web_url")))
            var page = 1
            do {
                while true {
                    let rows = try await CollaborationAPI.list(c, pipelineBase + "/pipelines/\(pipelineID)/jobs?include_retried=false&per_page=100&page=\(page)")
                    result.checks += rows.map { row in
                        RequestCheck(id: "job:\(CollaborationAPI.number(row, "id"))", name: CollaborationAPI.text(row, "name"), status: CIStatus(gitlab: CollaborationAPI.text(row, "status")), detail: CollaborationAPI.text(row, "stage") + (row["allow_failure"] as? Bool == true ? " · " + String(localized: "Allowed to fail") : ""), url: CollaborationAPI.text(row, "web_url"), jobID: CollaborationAPI.number(row, "id"), logProjectID: projectID > 0 ? projectID : nil)
                    }
                    if rows.count < 100 { break }; page += 1
                }
            } catch { try rethrowCancellation(error); result.warnings.append(String(localized: "Pipeline jobs could not be loaded.") + " " + safeError(error, c)) }
        }
        guard c.isCurrent?() != false, !Task.isCancelled else { throw CancellationError() }
        // Retain order while guarding against duplicate API entries during pagination.
        var ids = Set<String>()
        result.checks = result.checks.filter { ids.insert($0.id).inserted }
        return result
    }
    private static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
    }
    private static func safeError(_ error: Error, _ c: ReviewAccess) -> String {
        WorkspaceCILog.redact(error.localizedDescription, token: c.token)
    }
}
