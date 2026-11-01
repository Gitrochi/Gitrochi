import Foundation

extension FlowEngine {
    private static func designJSON<T: Decodable>(_ action: String, payload: [String: Any], in repo: URL) async throws -> T {
        guard let executable else { throw Failure(message: String(localized: "The flow engine is unavailable.")) }
        let input = try JSONSerialization.data(withJSONObject: payload)
        let result = try await Shell.run(executable, ["design", action, "--json"], cwd: repo,
                                         env: environment, input: String(decoding: input, as: UTF8.self))
        guard result.status == 0 else { throw failure(result) }
        return try JSONDecoder().decode(T.self, from: result.data)
    }

    static func inspectDesign(_ yaml: String, file: String, in repo: URL) async throws -> FlowDesignInspection {
        try await designJSON("inspect", payload: ["yaml": yaml, "fileName": file], in: repo)
    }

    static func renderDesign(_ document: FlowJSON, original: String?, in repo: URL) async throws -> FlowDesignRendered {
        var payload: [String: Any] = ["document": document.foundationValue]
        if let original { payload["originalYaml"] = original }
        return try await designJSON("render", payload: payload, in: repo)
    }

    static func blockCatalog(in repo: URL) async throws -> FlowBlockCatalog { try await json(["blocks"], in: repo) }

    static func readSource(_ path: String, in repo: URL) async throws -> FlowSourceResult {
        try await designJSON("source", payload: ["operation": "read", "path": path], in: repo)
    }

    static func writeSource(_ path: String, content: String, expected: String?, createParents: Bool = false, in repo: URL) async throws -> FlowSourceResult {
        var payload: [String: Any] = ["operation": "write", "path": path, "content": content, "expected": expected as Any? ?? NSNull()]
        if createParents, expected == nil { payload["createParents"] = true }
        return try await designJSON("source", payload: payload, in: repo)
    }
}
