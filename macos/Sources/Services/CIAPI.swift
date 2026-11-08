import Foundation

/// GitLab 파이프라인 / GitHub Actions
enum CIAPI {
    private struct GLPipeline: Decodable {
        let id: Int; let iid: Int?; let sha: String; let ref: String; let status: String
        let source: String?; let createdAt: String?; let updatedAt: String?; let webUrl: String; let name: String?
        let user: GLUserRef?
    }
    private struct GLUserRef: Decodable { let username: String }
    private struct GLJob: Decodable {
        let id: Int; let name: String; let stage: String; let status: String; let webUrl: String
        let allowFailure: Bool?; let duration: Double?
    }
    private struct GHRuns: Decodable { let workflowRuns: [GHRun] }
    private struct GHRun: Decodable {
        let id: Int; let name: String?; let displayTitle: String?; let runNumber: Int; let headBranch: String?
        let headSha: String; let status: String?; let conclusion: String?; let htmlUrl: String
        let createdAt: String?; let runStartedAt: String?; let updatedAt: String?; let event: String; let actor: GHActor?
        let pullRequests: [GHRunRequest]?
    }
    private struct GHRunRequest: Decodable { let number: Int }
    private struct GHActor: Decodable { let login: String }
    private struct GHJobs: Decodable { let jobs: [GHJob] }
    private struct GHJob: Decodable {
        let id: Int; let name: String; let status: String?; let conclusion: String?; let htmlUrl: String?
        let startedAt: String?; let completedAt: String?
    }
    private struct GHWorkflows: Decodable { let workflows: [GHWorkflow] }
    private struct GHWorkflow: Decodable { let id: Int; let name: String; let path: String; let state: String }
    private struct GHContent: Decodable { let content: String? }
    private struct GHPending: Decodable { let environment: GHEnv; let currentUserCanApprove: Bool? }
    private struct GHEnv: Decodable { let id: Int; let name: String? }

    private static func project(_ t: RepoTarget, _ base: String) -> String {
        base + "/projects/\(Hosting.projectID(t.path))"
    }

    private static func repo(_ t: RepoTarget, _ base: String) -> String {
        base + "/repos/\(t.path)"
    }

    private static func q(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 최근 파이프라인·실행(ref 가 있으면 그 브랜치만)
    static func pipelines(_ t: RepoTarget, token: String, apiBase: String, ref: String?) async throws -> [CIPipeline] {
        switch t.provider {
        case .gitlab:
            let filter = ref.map { "&ref=\(q($0))" } ?? ""
            let req = try Hosting.request(.gitlab, project(t, apiBase) + "/pipelines?per_page=30\(filter)", token: token)
            return try await Hosting.send([GLPipeline].self, req).map {
                CIPipeline(id: $0.id, number: $0.iid ?? $0.id, name: $0.name ?? "", title: "", ref: $0.ref, sha: $0.sha,
                           status: CIStatus(gitlab: $0.status), url: $0.webUrl, created: Hosting.date($0.createdAt),
                           event: $0.source ?? "", actor: $0.user?.username, started: Hosting.date($0.createdAt),
                           updated: Hosting.date($0.updatedAt))
            }
        case .github:
            let filter = ref.map { "&branch=\(q($0))" } ?? ""
            let req = try Hosting.request(.github, repo(t, apiBase) + "/actions/runs?per_page=30\(filter)", token: token)
            return try await Hosting.send(GHRuns.self, req).workflowRuns.map {
                CIPipeline(id: $0.id, number: $0.runNumber, name: $0.name ?? "", title: $0.displayTitle ?? "",
                           ref: $0.headBranch ?? "", sha: $0.headSha, status: CIStatus(github: $0.status, conclusion: $0.conclusion),
                           url: $0.htmlUrl, created: Hosting.date($0.createdAt), event: $0.event, actor: $0.actor?.login,
                           started: Hosting.date($0.runStartedAt ?? $0.createdAt), updated: Hosting.date($0.updatedAt),
                           request: $0.pullRequests?.first?.number)
            }
        }
    }

    static func jobs(_ t: RepoTarget, token: String, apiBase: String, pipeline id: Int) async throws -> [CIJob] {
        switch t.provider {
        case .gitlab:
            let req = try Hosting.request(.gitlab, project(t, apiBase) + "/pipelines/\(id)/jobs?per_page=100", token: token)
            // 단계 순서 = 먼저 만들어진 작업 순서
            return try await Hosting.send([GLJob].self, req).sorted { $0.id < $1.id }.map {
                CIJob(id: $0.id, name: $0.name, stage: $0.stage, status: CIStatus(gitlab: $0.status), url: $0.webUrl,
                      allowFailure: $0.allowFailure ?? false, duration: $0.duration)
            }
        case .github:
            let req = try Hosting.request(.github, repo(t, apiBase) + "/actions/runs/\(id)/jobs?per_page=100&filter=latest", token: token)
            return try await Hosting.send(GHJobs.self, req).jobs.map { j in
                let start = Hosting.date(j.startedAt), end = Hosting.date(j.completedAt)
                return CIJob(id: j.id, name: j.name, stage: "", status: CIStatus(github: j.status, conclusion: j.conclusion),
                             url: j.htmlUrl ?? "", allowFailure: false,
                             duration: start.flatMap { s in end.map { $0.timeIntervalSince(s) } })
            }
        }
    }

    // MARK: 작업

    static func play(_ t: RepoTarget, token: String, apiBase: String, job: Int) async throws {
        try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/jobs/\(job)/play", token: token, method: "POST"))
    }

    static func retry(_ t: RepoTarget, token: String, apiBase: String, job: Int) async throws {
        switch t.provider {
        case .gitlab:
            try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/jobs/\(job)/retry", token: token, method: "POST"))
        case .github:
            try await Hosting.data(Hosting.request(.github, repo(t, apiBase) + "/actions/jobs/\(job)/rerun", token: token, method: "POST"))
        }
    }

    static func cancel(_ t: RepoTarget, token: String, apiBase: String, job: Int) async throws {
        try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/jobs/\(job)/cancel", token: token, method: "POST"))
    }

    // MARK: 파이프라인

    static func retry(_ t: RepoTarget, token: String, apiBase: String, pipeline id: Int, failedOnly: Bool) async throws {
        switch t.provider {
        case .gitlab:
            // GitLab 은 실패·취소된 작업만 다시 실행한다
            try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/pipelines/\(id)/retry", token: token, method: "POST"))
        case .github:
            let path = failedOnly ? "rerun-failed-jobs" : "rerun"
            try await Hosting.data(Hosting.request(.github, repo(t, apiBase) + "/actions/runs/\(id)/\(path)", token: token, method: "POST"))
        }
    }

    static func cancel(_ t: RepoTarget, token: String, apiBase: String, pipeline id: Int) async throws {
        switch t.provider {
        case .gitlab:
            try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/pipelines/\(id)/cancel", token: token, method: "POST"))
        case .github:
            try await Hosting.data(Hosting.request(.github, repo(t, apiBase) + "/actions/runs/\(id)/cancel", token: token, method: "POST"))
        }
    }

    /// GitLab: 브랜치·변수로 새 파이프라인
    static func runPipeline(_ t: RepoTarget, token: String, apiBase: String, ref: String, variables: [(String, String)]) async throws {
        let vars = variables.map { ["key": $0.0, "value": $0.1, "variable_type": "env_var"] }
        try await Hosting.data(Hosting.request(.gitlab, project(t, apiBase) + "/pipeline", token: token, method: "POST",
                                               body: ["ref": ref, "variables": vars]))
    }

    /// GitHub: workflow_dispatch 가 있는 워크플로(입력값 포함). 파일은 ref 의 것을 읽는다.
    static func workflows(_ t: RepoTarget, token: String, apiBase: String, ref: String) async throws -> [CIWorkflow] {
        let req = try Hosting.request(.github, repo(t, apiBase) + "/actions/workflows?per_page=100", token: token)
        let list = try await Hosting.send(GHWorkflows.self, req).workflows
            .filter { $0.state == "active" && $0.path.hasPrefix(".github/workflows/") }
        return await withTaskGroup(of: (Int, CIWorkflow?).self) { group in
            for (n, w) in list.enumerated() {
                group.addTask {
                    guard let r = try? Hosting.request(.github, repo(t, apiBase) + "/contents/\(w.path)?ref=\(q(ref))", token: token),
                          let c = try? await Hosting.send(GHContent.self, r), let b64 = c.content,
                          let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                          let inputs = MiniYAML.dispatchInputs(String(decoding: data, as: UTF8.self)) else { return (n, nil) }
                    return (n, CIWorkflow(id: w.id, name: w.name, path: w.path, inputs: inputs))
                }
            }
            var out: [(Int, CIWorkflow)] = []
            for await (n, w) in group { if let w { out.append((n, w)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func dispatch(_ t: RepoTarget, token: String, apiBase: String, workflow: Int, ref: String, inputs: [String: String]) async throws {
        try await Hosting.data(Hosting.request(.github, repo(t, apiBase) + "/actions/workflows/\(workflow)/dispatches", token: token,
                                               method: "POST", body: ["ref": ref, "inputs": inputs]))
    }

    static func pendingDeployments(_ t: RepoTarget, token: String, apiBase: String, run: Int) async throws -> [CIDeployment] {
        let req = try Hosting.request(.github, repo(t, apiBase) + "/actions/runs/\(run)/pending_deployments", token: token)
        return try await Hosting.send([GHPending].self, req).map {
            CIDeployment(environmentID: $0.environment.id, environment: $0.environment.name ?? String(localized: "Environment \($0.environment.id)"),
                         canApprove: $0.currentUserCanApprove ?? false)
        }
    }

    static func review(_ t: RepoTarget, token: String, apiBase: String, run: Int, environments: [Int], approve: Bool) async throws {
        try await Hosting.data(Hosting.request(.github, repo(t, apiBase) + "/actions/runs/\(run)/pending_deployments", token: token,
                                               method: "POST", body: ["environment_ids": environments,
                                                                      "state": approve ? "approved" : "rejected",
                                                                      "comment": "Gitrochi"]))
    }
}
