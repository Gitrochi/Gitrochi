import Foundation

/// The embedded renderer receives data only and cannot request network resources.
enum StructureGraphDocument {
    static func prepare(_ html: String, actionsJSON: String? = nil) throws -> String {
        guard html.utf8.count <= 100_000_000, html.contains("id=\"graph-data\""), html.contains("<head>"), html.contains("</body>") else {
            throw Gitch.Failure(message: String(localized: "The generated graph document is invalid."))
        }
        var encoded = "null"
        if let actionsJSON {
            guard actionsJSON.utf8.count <= 65_536, let data = actionsJSON.data(using: .utf8) else {
                throw Gitch.Failure(message: String(localized: "The graph action request is too large."))
            }
            let object = try JSONSerialization.jsonObject(with: data)
            encoded = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
                .replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: ">", with: "\\u003e")
                .replacingOccurrences(of: "&", with: "\\u0026")
        }
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; base-uri 'none'; form-action 'none'\">"
        return html.replacingOccurrences(of: "<head>", with: "<head>\(policy)<script id=\"graph-actions\" type=\"application/json\">\(encoded)</script>")
    }

    static func appLink(_ url: URL, repository: URL) -> Bool {
        guard url.scheme == "gitrochi", url.host == "open", ["", "/"].contains(url.path),
              url.user == nil, url.password == nil, url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems,
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["repo", "view", "file", "line", "commit"].contains($0.name) }) else { return false }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["view"] == "graph", let path = values["repo"], URL(fileURLWithPath: path).standardizedFileURL.path == repository.standardizedFileURL.path else { return false }
        if let file = values["file"] {
            guard !file.isEmpty, !file.hasPrefix("/"), !file.contains(":"), !file.contains("\\"),
                  !file.unicodeScalars.contains(where: { $0.value < 32 }),
                  !file.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", ".."].contains(String($0)) }) else { return false }
        }
        if let line = values["line"], line.range(of: "^[1-9][0-9]{0,7}$", options: .regularExpression) == nil { return false }
        if let commit = values["commit"], commit.range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) == nil { return false }
        return true
    }
}
