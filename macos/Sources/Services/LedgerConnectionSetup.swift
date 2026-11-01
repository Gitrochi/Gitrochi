import Foundation

/// The local clients supported by the Ledger's registration and passive activity setup.
/// (Windows: features/connect-ledger-mcp/lib/setup.ts)
enum LedgerSetupClient: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }

    func registration(binary: String) -> String {
        "\(rawValue) mcp add \(self == .claude ? "--scope user " : "")gitrochi-ledger -- \(quote(binary)) mcp"
    }

    func install(binary: String) -> String { "\(quote(binary)) integrate \(rawValue) --install" }

    func status(binary: String) -> String { "\(quote(binary)) integrate \(rawValue) --status" }

    func remove(binary: String) -> String { "\(quote(binary)) integrate \(rawValue) --remove" }

    func configuration(binary: String) -> String {
        if self == .codex {
            let data = (try? JSONSerialization.data(withJSONObject: [binary], options: [.withoutEscapingSlashes])) ?? Data()
            let encoded = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
            return "[mcp_servers.gitrochi-ledger]\ncommand = \(encoded)\nargs = [\"mcp\"]"
        }
        let values: [String: Any] = ["mcpServers": ["gitrochi-ledger": ["command": binary, "args": ["mcp"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
