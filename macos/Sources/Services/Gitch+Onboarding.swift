import Foundation

extension Gitch {
    /// The setup API returns public connection details; private keys and tokens never enter the UI.
    struct AccountSetup: Decodable {
        let schemaVersion: Int
        let id: String
        let email: String
        let host: String
        let port: Int
        let alias: String
        let keyExists: Bool
        let aliasConfigured: Bool?
        let publicKey: String
        let registrationURL: String
        let authenticated: Bool?
        let keyProtection: String
        let message: String
    }

    struct Doctor: Decodable {
        struct Item: Decodable {
            let section: String
            let level: String
            let message: String
        }
        let schemaVersion: Int
        let version: String
        let problems: Int
        let items: [Item]
    }

    enum SetupAction: String { case inspect, generate, check }

    struct BrowserLogin: Decodable {
        enum State: String, Decodable { case pending, complete, failed, cancelled }
        let schemaVersion: Int
        let session: String
        let state: State
        let deviceCode: String?
        let phase: String?
        let verificationURL: String
        let login: String?
        let email: String?
        let message: String
    }

    enum GitHubLoginCapability: String { case standard, projects }

    static func startGitHubLogin(capability: GitHubLoginCapability = .standard, expectedLogin: String? = nil) async throws -> BrowserLogin {
        let expected = expectedLogin?.trimmingCharacters(in: .whitespacesAndNewlines)
        if capability == .projects && expected?.isEmpty != false {
            throw Failure(message: String(localized: "Select the GitHub account to connect project access."))
        }
        var args = ["login", "github", "--start", "--json", "--yes"]
        if capability == .projects { args += ["--capability", "projects"] }
        if let expected, !expected.isEmpty { args += ["--expected-login", expected] }
        return try await onboardingJSON(args)
    }

    static func gitHubLogin(_ session: String, cancel: Bool = false) async throws -> BrowserLogin {
        try await onboardingJSON(["login", "github", cancel ? "--cancel" : "--status", session, "--json"], allowed: [0, 1])
    }

    private struct SetupAPIError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    static func addAccount(id: String, email: String, host: String, port: Int, folder: String?, via: String?) async throws -> AccountSetup {
        var args = ["add", "--id", id, "--email", email, "--host", host, "--port", String(port), "--no-setup", "--json", "--yes"]
        args += folder.map { ["--folder", $0] } ?? ["--no-folder"]
        if let via, !via.isEmpty { args += ["--via", via] }
        return try await onboardingJSON(args)
    }

    static func setupAccount(_ id: String, action: SetupAction) async throws -> AccountSetup {
        let args = ["setup", id, "--" + action.rawValue, "--json"] + (action == .generate ? ["--yes"] : [])
        return try await onboardingJSON(args, allowed: action == .check ? [0, 1] : [0])
    }

    static func doctor() async throws -> Doctor {
        try await onboardingJSON(["doctor", "--no-net", "--json"], allowed: [0, 1])
    }

    static func commandHelp() async throws -> String {
        guard let exe = bundled else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        let result = try await Shell.run("/bin/bash", [exe, "help"], cwd: URL(fileURLWithPath: NSHomeDirectory()), env: environment, timeout: 30)
        guard result.status == 0 else { throw Failure(message: String(localized: "Couldn't read the command help. Update Gitrochi and try again.")) }
        return result.output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression).trimmed
    }

    private static func onboardingJSON<T: Decodable>(_ args: [String], allowed: [Int32] = [0]) async throws -> T {
        // Use this app's bundled CLI: an independently installed copy may not have this API.
        guard let exe = bundled else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        var env = environment
        if let gh = ToolPaths.shared.get(.gh) {
            env["PATH"] = (gh as NSString).deletingLastPathComponent + ":" + (env["PATH"] ?? "")
            env["GITCH_GH"] = gh
        }
        if args.first == "login" {
            for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] { env.removeValue(forKey: key) }
        }
        let result = try await Shell.run("/bin/bash", [exe] + args, cwd: URL(fileURLWithPath: NSHomeDirectory()), env: env, timeout: 60)
        if allowed.contains(result.status), let value = try? JSONDecoder().decode(T.self, from: result.data) { return value }
        let message = [result.data, Data(result.stderr.utf8)].compactMap {
            (try? JSONDecoder().decode(SetupAPIError.self, from: $0))?.error.message
        }.first
        let output = result.stderr.trimmed.isEmpty ? result.output.trimmed : result.stderr.trimmed
        throw Failure(message: message ?? (output.isEmpty ? String(localized: "Couldn't read the setup result. Update Gitrochi and try again.") : output))
    }
}
