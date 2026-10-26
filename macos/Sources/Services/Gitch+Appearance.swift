import Foundation

extension Gitch {
    struct LogoSetting: Decodable {
        let schemaVersion: Int
        let enabled: Bool
    }

    static func logoSetting() async throws -> LogoSetting {
        try await logoSetting(arguments: ["logo", "--json"])
    }

    static func setLogoEnabled(_ enabled: Bool) async throws -> LogoSetting {
        try await logoSetting(arguments: ["logo", enabled ? "on" : "off", "--json"])
    }

    private static func logoSetting(arguments: [String]) async throws -> LogoSetting {
        // The bundled CLI implements this API even before the shell command or an account is installed.
        guard let exe = bundled else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        let result = try await Shell.run("/bin/bash", [exe] + arguments,
                                         cwd: URL(fileURLWithPath: NSHomeDirectory()), env: environment, timeout: 30)
        if result.status == 0,
           let setting = try? JSONDecoder().decode(LogoSetting.self, from: result.data), setting.schemaVersion == 1 {
            return setting
        }
        let output = result.stderr.trimmed.isEmpty ? result.output.trimmed : result.stderr.trimmed
        throw Failure(message: result.status != 0 && !output.isEmpty
                      ? output
                      : String(localized: "Couldn't read the CLI appearance setting. Update Gitrochi and try again."))
    }
}
