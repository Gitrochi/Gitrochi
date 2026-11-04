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

/// The stable ledger command hooks and MCP entries name; the app keeps it equal to its bundled one.
/// (Windows: entities/ledger/model/types.ts LedgerStableCommand)
struct LedgerStableCommand: Decodable, Sendable, Equatable {
    let path: String
    let exists: Bool
    let current: Bool
    let refreshed: Bool
    /// This app is older than the database, so it kept the existing copy
    let held: Bool
}

/// `integration_status` and friends: the passive hooks, the MCP entry and whether they still reach this ledger
/// (crates/gitrochi-ledger/schema/integration-status.schema.json; Windows: LedgerIntegrationStatus)
struct LedgerIntegrationStatus: Decodable, Sendable, Equatable {
    struct Command: Decodable, Sendable, Equatable {
        let path: String
        let exists: Bool
        let executable: Bool
        let writesSchema: Int?
        let canWrite: Bool?
        let sameDatabase: Bool?
    }
    struct Mcp: Decodable, Sendable, Equatable {
        let configPath: String
        let registered: Bool
        let command: Command?
    }
    let client: String
    let installed: Bool
    let ownedHookCount: Int
    let requiresClientTrust: Bool
    let hooksDisabled: Bool
    let hookCommand: Command?
    let mcp: Mcp
    let databaseSchema: Int?
    /// Epoch milliseconds
    let lastObservedAt: Int?
    let lastReportAt: Int?
    /// not_installed | ok | no_data_yet | incomplete | outdated_command | missing_command | other_database
    let health: String
}
