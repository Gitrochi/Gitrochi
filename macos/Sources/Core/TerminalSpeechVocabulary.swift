import Foundation

/// Recognition hints improve spelling; they never replace dictated text or become executable commands.
enum TerminalSpeechVocabulary {
    static let maximumEntries = 100
    static let maximumLength = 80

    private static let common = [
        "Gitrochi", "gitch", "Claude", "Codex", "Gemini", "Swift", "SwiftUI", "TypeScript",
        "JavaScript", "Rust", "Python", "Git", "GitHub", "GitLab", "commit", "pull request", "worktree", "rebase"
    ]

    /// App-language overrides must not hide the user's preferred system speech language.
    static var preferredSystemLanguage: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["AppleLanguages"] as? [String])?.first
            ?? Locale.preferredLanguages.first
            ?? Locale.current.identifier
    }

    static func make(repositoryName: String, branches: [String], paths: [String], custom: String) -> [String] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ","))
        var candidates = common + [repositoryName] + custom.components(separatedBy: separators) + branches
        for path in paths {
            guard !isAbsolutePath(path) else { continue }
            let basename = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
            guard !isPrivateFilename(basename) else { continue }
            candidates.append(basename)
            candidates.append((basename as NSString).deletingPathExtension)
        }
        return bounded(candidates)
    }

    /// The service applies the same bound even when a caller supplies its own hint list.
    static func bounded(_ candidates: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard let term = normalized(candidate) else { continue }
            let key = term.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { continue }
            result.append(term)
            if result.count == maximumEntries { break }
        }
        return result
    }

    /// Automatic follows an explicit app language before the preferred system language.
    static func localeIdentifier(saved: String, appLanguage: String, systemLanguage: String) -> String {
        let saved = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty, saved != "system", let locale = locale(saved) { return locale }
        if !appLanguage.isEmpty, appLanguage != "system" {
            let appBase = language(appLanguage)
            if appBase != "ko", appBase != "en", appBase == language(systemLanguage), let system = locale(systemLanguage) {
                return system
            }
            if let app = locale(appLanguage) { return app }
        }
        return locale(systemLanguage) ?? "en-US"
    }

    private static func normalized(_ candidate: String) -> String? {
        guard !candidate.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let term = candidate.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !term.isEmpty, term.count <= maximumLength, !isAbsolutePath(term) else { return nil }
        let lower = term.lowercased()
        guard !lower.contains("://"), !lower.hasPrefix("www."), !lower.contains("@"),
              !lower.hasPrefix("mailto:"), !lower.hasPrefix("file:"), !lower.hasPrefix("http:") && !lower.hasPrefix("https:") else { return nil }
        let secretPrefixes = ["sk-", "sk_", "ghp_", "gho_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "aiza", "bearer ", "basic ", "-----begin"]
        guard !secretPrefixes.contains(where: lower.hasPrefix) else { return nil }
        guard lower.range(of: #"(?:token|password|secret|api[_-]?key)\s*[:=]"#, options: .regularExpression) == nil else { return nil }
        guard term.range(of: #"^[A-Fa-f0-9]{32,}$|^[A-Za-z0-9_+/=-]{40,}$|^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.|^(?:AKIA|ASIA)[A-Z0-9]{12,}$"#, options: .regularExpression) == nil else { return nil }
        return term
    }

    private static func isAbsolutePath(_ text: String) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("\\")
            || text.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    private static func isPrivateFilename(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.isEmpty || lower.hasPrefix(".") || ["id_rsa", "id_ed25519", "credentials.json", "credentials", "secrets.json"].contains(lower)
            || ["key", "pem", "p12", "pfx"].contains((lower as NSString).pathExtension)
    }

    private static func language(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)?.lowercased() ?? ""
    }

    private static func locale(_ identifier: String) -> String? {
        let identifier = identifier.split(separator: "@").first.map(String.init) ?? ""
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let first = parts.first, first.range(of: #"^[A-Za-z]{2,3}$"#, options: .regularExpression) != nil else { return nil }
        if first.lowercased() == "ko" { return "ko-KR" }
        if first.lowercased() == "en" { return "en-US" }
        guard parts.dropFirst().allSatisfy({ $0.range(of: #"^[A-Za-z0-9]{2,8}$"#, options: .regularExpression) != nil }) else { return nil }
        return Locale.identifier(.bcp47, from: normalized)
    }
}
