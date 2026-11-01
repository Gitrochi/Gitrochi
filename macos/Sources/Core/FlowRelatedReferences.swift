import Foundation

/// Literal file hints never evaluate shell expressions; every selected path is checked again by the source bridge.
enum FlowRelatedReferences {
    static func paths(node: FlowJSON, suite: FlowJSON = .null) -> [String] {
        let cwd = node["cwd"].string ?? suite["cwd"].string ?? ""
        var result: [String] = []
        for value in [node["with"]["file"], node["file"], suite["with"]["file"]] {
            if let value = value.string, let path = relative(value, cwd: cwd) { result.append(path) }
        }
        let scripts = [node.string, node["run"].string, node["undo"].string, node["with"]["run"].string, suite["with"]["run"].string].compactMap { $0 }
        for script in scripts {
            let tokens = words(script)
            for token in tokens {
                let ext = (token as NSString).pathExtension.lowercased()
                let name = (token as NSString).lastPathComponent.lowercased()
                if ["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "ts", "ps1", "rb", "pl", "yml", "yaml"].contains(ext) || ["dockerfile", "jenkinsfile"].contains(name) {
                    if let path = relative(token, cwd: cwd) { result.append(path) }
                }
            }
            if tokens.contains(where: { ["npm", "pnpm", "yarn", "bun"].contains($0) }), let path = relative("package.json", cwd: cwd) { result.append(path) }
        }
        return Array(Set(result)).sorted()
    }

    private static func relative(_ path: String, cwd: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !cwd.hasPrefix("/"), !(path + cwd).contains(where: { "\\:$`\n\r\0".contains($0) }) else { return nil }
        var parts: [String] = []
        for part in (cwd + "/" + path).split(separator: "/").map(String.init) {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { guard part.lowercased() != ".git" else { return nil }; parts.append(part) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static func words(_ source: String) -> [String] {
        var result: [String] = [], word = ""
        var quote: Character?
        for character in source {
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character.isWhitespace || ";|&".contains(character) {
                if !word.isEmpty { result.append(word); word = "" }
            } else { word.append(character) }
        }
        if !word.isEmpty, quote == nil { result.append(word) }
        return result
    }
}
