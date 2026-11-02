import Foundation

/// Account labels can include an SSH port description; it is not another server (Windows: account-presentation.ts).
enum GitAccountPresentation {
    static func host(_ label: String) -> String {
        String(label.split(whereSeparator: { $0 == "(" || $0 == "," || $0.isWhitespace }).first ?? "").lowercased()
    }

    static func key(host: String, username: String) -> String { self.host(host) + "/" + username.lowercased() }

    static func avatarURL(host: String, username: String) -> URL? {
        guard self.host(host) == "github.com",
              username.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://github.com/\(username).png?size=64")
    }
}
