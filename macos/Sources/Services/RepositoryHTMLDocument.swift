import Foundation

struct RepositoryHTMLDocument {
    struct Resource { let data: Data; let mime: String }
    let id = UUID()
    let html: String
    let resources: [String: Resource]
    let missingResources: Bool
    static let scheme = "gitrochi-source"
    static let policy = "default-src 'none'; script-src 'none'; connect-src 'none'; style-src 'unsafe-inline' gitrochi-source:; img-src gitrochi-source:; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'"

    static func inlineRaster(_ reference: String) -> Resource? {
        guard reference.utf8.count <= 10_666_720, let comma = reference.firstIndex(of: ",") else { return nil }
        let header = reference[..<comma].lowercased()
        let types = ["data:image/png;base64": "image/png", "data:image/jpeg;base64": "image/jpeg", "data:image/gif;base64": "image/gif", "data:image/webp;base64": "image/webp"]
        guard let mime = types[header] else { return nil }
        let encoded = String(reference[reference.index(after: comma)...])
        guard encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 47, 61, 10, 13].contains($0) }), let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count <= 8_000_000, RepositoryBrowser.imageMIME(data) == mime else { return nil }
        return Resource(data: data, mime: mime)
    }

    static func load(text: String, path: String, tree: RepositoryTreeSnapshot, repository: URL) async -> RepositoryHTMLDocument {
        let builder = RepositoryHTMLResources(entries: tree.entries, repository: repository)
        let rewritten = await builder.html(text, path: path)
        let limited = rewritten.utf8.count > 8_000_000
        let prefix = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head><body>"
        return RepositoryHTMLDocument(html: prefix + (limited ? text : rewritten) + "</body></html>", resources: builder.resources, missingResources: builder.missing || limited)
    }

    static func localPath(_ reference: String, relativeTo path: String) -> String? {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&")
        guard !value.isEmpty, !value.hasPrefix("//"), !value.hasPrefix("#"), !value.contains("\\"), URLComponents(string: value)?.scheme == nil else { return nil }
        let component = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(component).removingPercentEncoding, !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        var parts = decoded.hasPrefix("/") ? [] : path.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(String(part)) }
        }
        let result = parts.joined(separator: "/")
        return RepositoryBrowser.safePath(result) ? result : nil
    }
}

/// Rewrites only committed CSS and raster assets; the WebView enforces the actual security boundary.
private final class RepositoryHTMLResources {
    private let entries: [String: RepositoryTreeEntry]
    private let repository: URL
    private var paths: [String: String] = [:]
    private var inlinePaths: [Data: String] = [:]
    private var pending = Set<String>()
    private var bytes = 0
    private var outputBytes = 0
    private var count = 0
    private(set) var resources: [String: RepositoryHTMLDocument.Resource] = [:]
    private(set) var missing = false
    init(entries: [RepositoryTreeEntry], repository: URL) {
        self.entries = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.repository = repository
    }

    func html(_ input: String, path: String) async -> String {
        var result = await replace(input, pattern: #"(?is)<(?:link|img)\b[^>]*>"#) { tag in
            let image = tag.lowercased().hasPrefix("<img")
            if !image && tag.range(of: #"\brel\s*=\s*(?:["']stylesheet["']|stylesheet\b)"#, options: [.regularExpression, .caseInsensitive]) == nil { return tag }
            let attribute = image ? "src" : "href"
            return await self.replace(tag, pattern: "(?i)\\b" + attribute + #"\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#) { assignment in
                guard let equals = assignment.firstIndex(of: "=") else { return assignment }
                let reference = assignment[assignment.index(after: equals)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard let url = await self.asset(reference, relativeTo: path, css: !image, depth: 0) else { return attribute + "=\"about:blank\"" }
                return attribute + "=\"" + url + "\""
            }
        }
        result = await replace(result, pattern: #"(?is)<style\b[^>]*>[\s\S]*?</style\s*>"#) { block in
            guard let open = block.firstIndex(of: ">"), let close = block.range(of: "</style", options: [.caseInsensitive, .backwards]) else { return block }
            let content = String(block[block.index(after: open)..<close.lowerBound])
            return String(block[...open]) + (await self.css(content, path: path, depth: 0)) + String(block[close.lowerBound...])
        }
        return result
    }

    private func css(_ input: String, path: String, depth: Int) async -> String {
        var value = await replace(input, pattern: #"(?is)@import\s+(?:url\(\s*)?(?:"[^"]*"|'[^']*')[^;]*;"#) { directive in
            guard let expression = try? NSRegularExpression(pattern: #"["']([^"']+)["']"#), let match = expression.firstMatch(in: directive, range: NSRange(location: 0, length: (directive as NSString).length)) else { return "" }
            let reference = (directive as NSString).substring(with: match.range(at: 1))
            guard let url = await self.asset(reference, relativeTo: path, css: true, depth: depth + 1) else { return "" }
            return "@import url(\"" + url + "\");"
        }
        value = await replace(value, pattern: #"(?is)url\(\s*(?:"[^"]*"|'[^']*'|[^)]*)\s*\)"#) { token in
            guard let start = token.firstIndex(of: "("), let end = token.lastIndex(of: ")") else { return "url(about:blank)" }
            let reference = token[token.index(after: start)..<end].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if reference.hasPrefix(RepositoryHTMLDocument.scheme + "://"), self.resources[reference] != nil { return token }
            let isCSS = reference.split(separator: "?").first?.lowercased().hasSuffix(".css") == true
            guard let url = await self.asset(reference, relativeTo: path, css: isCSS, depth: depth + 1) else { return "url(about:blank)" }
            return "url(\"" + url + "\")"
        }
        return value
    }

    private func asset(_ reference: String, relativeTo path: String, css: Bool, depth: Int) async -> String? {
        if !css && reference.lowercased().hasPrefix("data:") {
            guard let resource = RepositoryHTMLDocument.inlineRaster(reference) else { missing = true; return nil }
            if let cached = inlinePaths[resource.data] { return cached }
            guard count < 20, resource.data.count <= 8_000_000 - bytes, resource.data.count <= 8_000_000 - outputBytes else { missing = true; return nil }
            count += 1; bytes += resource.data.count
            outputBytes += resource.data.count
            let url = RepositoryHTMLDocument.scheme + "://asset/" + String(resources.count)
            resources[url] = resource; inlinePaths[resource.data] = url
            return url
        }
        guard !Task.isCancelled, let resolved = RepositoryHTMLDocument.localPath(reference, relativeTo: path) else { missing = true; return nil }
        if let cached = paths[resolved] { return cached }
        guard depth <= 3, count < 20, !pending.contains(resolved), let entry = entries[resolved], entry.isFile, entry.size <= 8_000_000 - bytes, !css || (resolved as NSString).pathExtension.lowercased() == "css" else { missing = true; return nil }
        pending.insert(resolved); count += 1; bytes += entry.size
        defer { pending.remove(resolved) }
        do {
            let blob = try await RepositoryBrowser.blob(in: repository, entry: entry)
            let resource: RepositoryHTMLDocument.Resource
            if css, let text = blob.text {
                let rewritten = await self.css(text, path: resolved, depth: depth)
                resource = .init(data: Data(rewritten.utf8), mime: "text/css")
            } else if !css, let image = blob.image, let mime = RepositoryBrowser.imageMIME(image) { resource = .init(data: image, mime: mime) }
            else { missing = true; return nil }
            guard resource.data.count <= 8_000_000 - outputBytes else { missing = true; return nil }
            outputBytes += resource.data.count
            let url = RepositoryHTMLDocument.scheme + "://asset/" + String(resources.count)
            resources[url] = resource; paths[resolved] = url
            return url
        } catch { missing = true; return nil }
    }

    private func replace(_ input: String, pattern: String, transform: (String) async -> String) async -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
        let source = input as NSString, matches = expression.matches(in: input, range: NSRange(location: 0, length: (input as NSString).length))
        var result = "", cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += await transform(source.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return result
    }
}
