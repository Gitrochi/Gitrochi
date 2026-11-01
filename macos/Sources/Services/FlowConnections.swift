import Foundation

extension FlowEngine {
    static func connections(in repo: URL) async throws -> [FlowConnection] {
        struct Response: Decodable { let connections: [FlowConnection] }
        let response: Response = try await json(["connect", "list"], in: repo)
        return response.connections
    }

    static func saveConnection(_ connection: FlowConnection, in repo: URL) async throws {
        if let problem = connection.problem { throw Failure(message: problem) }
        var args = ["connect", "add", connection.kind, "--name", connection.name, "--url", connection.url,
                    "--secret-from", connection.secret, "--allow", connection.allow.joined(separator: ",")]
        if let user = connection.user, !user.isEmpty { args += ["--user", user] }
        if let project = connection.project, !project.isEmpty { args += ["--project", project] }
        let result = try await run(args + ["--json"], in: repo)
        guard result.status == 0 else { throw failure(result) }
    }

    static func testConnection(_ name: String, in repo: URL) async throws -> FlowConnectionTest {
        try await json(["connect", "test", name], in: repo, ok: [0, 1], timeout: 20)
    }

    static func browseConnection(_ name: String, job: String = "", run: String? = nil, in repo: URL) async throws -> FlowRemoteBrowse {
        try await json(["ci", "browse"] + (job.isEmpty ? [] : [job]) + (run.map { [$0] } ?? []) + ["--connection", name], in: repo, timeout: 25)
    }
}
