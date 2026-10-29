import Foundation

/// Issue handoffs stay on the current repository (Windows: entities/hosting/model/issue-workflow.ts).
enum IssueWorkflow {
    static func task(target: RepoTarget?, number: Int, title: String, url: String, isIssue: Bool = true) -> ProjectTaskReference? {
        guard let target, isIssue, number > 0,
              let expected = URL(string: target.webURL + (target.provider == .gitlab ? "/-/issues/" : "/issues/") + String(number)),
              let actual = URL(string: url), actual.scheme == expected.scheme, actual.host == expected.host, actual.port == expected.port,
              actual.user == nil, actual.password == nil, (target.provider == .github ? actual.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) : actual.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else { return nil }
        return ProjectTaskReference(id: "issue:\(target.provider.rawValue):\(target.host)/\(target.path)#\(number)", title: title, url: expected.absoluteString, number: number, repository: target.path, host: target.host)
    }
    static func branchName(_ task: ProjectTaskReference) -> String {
        let slug = String(task.title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "feature/\(task.number ?? 0)-\(slug.isEmpty ? "issue" : slug)"
    }
    static func requestBody(_ task: ProjectTaskReference) -> String { "Closes #\(task.number ?? 0)\n\n\(task.url)" }
    static func quote(author: String, body: String) -> String { "@\(author)\n\n" + body.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n\n" }
}
