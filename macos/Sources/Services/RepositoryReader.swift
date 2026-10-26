import Foundation

struct RepositoryReadResult: Decodable {
    let repository: String
    let tool: String
    let text: String
    let truncated: Bool
    let readOnly: Bool
    let head: String?
    let observedAt: String?
}

/// 앱 질문과 외부 MCP가 같은 읽기 도구와 경로 제한을 사용한다.
struct RepositoryReader {
    let node: String
    let arguments: [String]
    let repository: URL

    @MainActor static func prepare(in repository: URL) async throws -> RepositoryReader {
        guard let node = ToolStore.shared.path(.node) else { throw Failure.message(String(localized: "Install Node.js 22 or later, then locate it in Settings > Tools.")) }
        let version = try await Shell.run(node, ["--version"], cwd: FileManager.default.temporaryDirectory, timeout: 10)
        guard version.status == 0, let major = Int(version.output.trimmed.dropFirst().split(separator: ".").first ?? "0"), major >= 22 else {
            throw Failure.message(String(localized: "Install Node.js 22 or later, then locate it in Settings > Tools."))
        }
        guard let script = Bundle.main.path(forResource: "gitrochi-mcp", ofType: "mjs") else {
            throw Failure.message(String(localized: "The bundled repository reader is missing. Reinstall or rebuild Gitrochi."))
        }
        var args = [script, "--repo", repository.path, "--git", ToolStore.shared.path(.git) ?? "/usr/bin/git"]
        if let gitch = Gitch.executable { args += ["--gitch", gitch, "--bash", "/bin/bash"] }
        return RepositoryReader(node: node, arguments: args, repository: repository)
    }

    var configuration: String {
        let value: [String: Any] = ["mcpServers": ["gitrochi": ["command": node, "args": arguments]]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func catalog() async throws -> String {
        let result = try await Shell.run(node, [arguments[0], "--tools"], cwd: repository, timeout: 10)
        guard result.status == 0 else { throw Failure.message(result.stderr) }
        return result.output
    }

    func call(_ name: String, arguments values: [String: Any] = [:]) async throws -> RepositoryReadResult {
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": values], options: [.sortedKeys])
        let result = try await Shell.run(node, arguments + ["--call", String(decoding: data, as: UTF8.self)], cwd: repository, timeout: 30)
        guard result.status == 0 else { throw Failure.message(result.stderr.trimmed) }
        let value = try JSONDecoder().decode(RepositoryReadResult.self, from: result.data)
        guard value.readOnly else { throw Failure.message(String(localized: "The repository reader returned an invalid result.")) }
        return value
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let value): return value } }
    }
}
