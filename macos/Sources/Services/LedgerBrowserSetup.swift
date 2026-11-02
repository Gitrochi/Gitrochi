import Foundation

/// Browser setup is separate from pairing an individual conversation (Windows: connect-ledger-mcp).
enum LedgerBrowserSetup {
    static var host: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gitrochi-ledger-browser") }
    static var extensionFolder: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/chatgpt-ledger", isDirectory: true) }

    static func validExtensionId(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (97...112).contains($0) }
    }

    /// A source link is navigation only, and can never open a different service or a local file.
    static func sourceURL(_ value: String?) -> URL? {
        guard let value, let parts = URLComponents(string: value), parts.scheme == "https", parts.host == "chatgpt.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0].isEmpty, ["c", "uc"].contains(segments[1]),
              segments[2].count == 36, UUID(uuidString: String(segments[2])) != nil else { return nil }
        return parts.url
    }
}

/// Installed configuration is not proof that the browser is paired or currently syncing.
struct LedgerBrowserStatus: Decodable, Sendable {
    let installed: Bool
    let hostName: String
    let manifestPath: String
    let extensionId: String?
    let hostPath: String?
}
