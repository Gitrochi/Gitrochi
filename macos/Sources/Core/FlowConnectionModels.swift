import Foundation

struct FlowConnection: Decodable, Identifiable {
    var name: String
    var kind: String
    var url: String
    var user: String?
    var project: String?
    var secret: String
    var allow: [String]
    var id: String { name }

    static var empty: Self { .init(name: "", kind: "jenkins", url: "", secret: "env:CI_TOKEN", allow: []) }
    var provider: String {
        switch kind {
        case "github": "GitHub Actions"
        case "gitlab": "GitLab CI/CD"
        case "jenkins": "Jenkins"
        case "http": "HTTP CI"
        default: "Webhook"
        }
    }

    var problem: String? {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil else {
            return String(localized: "Use letters, numbers, dots, dashes or underscores for the connection name.")
        }
        let address = url.isEmpty && kind == "github" ? "https://api.github.com" : url
        guard let parts = URLComponents(string: address), ["http", "https"].contains(parts.scheme ?? ""),
              parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            return String(localized: "Enter an HTTP or HTTPS server address without credentials or query parameters.")
        }
        guard secret.range(of: "^(keystore|env:[A-Za-z_][A-Za-z0-9_]*|app:[A-Za-z0-9._-]+|gh:[A-Za-z0-9-]+)$", options: .regularExpression) != nil else {
            return String(localized: "Choose a saved credential reference, such as env:CI_TOKEN. Do not enter a token here.")
        }
        return nil
    }
}

struct FlowConnectionTest: Decodable {
    let ok: Bool
    let message: String
    let action: String?
}

struct FlowRemoteBrowse: Decodable {
    struct Job: Decodable, Identifiable {
        let name: String
        let path: String
        let url: String
        let folder: Bool
        var id: String { path }
    }
    struct Run: Decodable, Identifiable {
        let id: String
        let title: String
        let status: String
        let url: String
        let startedAt: Double
        let durationMs: Double
    }
    let jobs: [Job]
    let runs: [Run]
    let log: String?
    let truncated: Bool
}
