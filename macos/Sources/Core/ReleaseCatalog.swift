import Foundation

/// Release ordering mirrors Windows entities/hosting/model/releases.ts.
enum ReleaseCatalog {
    struct Version { let family: String; let core: [String]; let pre: [String] }
    static func version(_ tag: String) -> Version? {
        let pattern = #"^(.*?)(?:v|V)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        func group(_ n: Int) -> String { Range(match.range(at: n), in: tag).map { String(tag[$0]) } ?? "" }
        let family = group(1), pre = group(5).split(separator: ".").map(String.init)
        guard family.isEmpty || family.last.map({ "@/-_".contains($0) }) == true,
              !pre.contains(where: { isNumber($0) && $0.count > 1 && $0.hasPrefix("0") }) else { return nil }
        return Version(family: family, core: (2...4).map(group), pre: pre)
    }
    private static func isNumber(_ value: String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } }
    private static func numeric(_ a: String, _ b: String) -> Int { a.count != b.count ? (a.count < b.count ? -1 : 1) : a == b ? 0 : a < b ? -1 : 1 }
    static func compare(_ a: String, _ b: String) -> Int? {
        guard let x = version(a), let y = version(b), x.family == y.family else { return nil }
        for i in 0..<3 { let n = numeric(x.core[i], y.core[i]); if n != 0 { return n } }
        if x.pre.isEmpty || y.pre.isEmpty { return x.pre.isEmpty == y.pre.isEmpty ? 0 : x.pre.isEmpty ? 1 : -1 }
        for i in 0..<max(x.pre.count, y.pre.count) {
            guard i < x.pre.count, i < y.pre.count else { return x.pre.count < y.pre.count ? -1 : 1 }
            let p = x.pre[i], q = y.pre[i]
            if p == q { continue }
            let pn = isNumber(p), qn = isNumber(q)
            return pn && qn ? numeric(p, q) : pn != qn ? (pn ? -1 : 1) : p < q ? -1 : 1
        }
        return 0
    }
    static func tag(_ item: HubItem) -> String { item.data["tag_name"] as? String ?? item.subtitle.components(separatedBy: " · ").first ?? "" }
    static func date(_ item: HubItem) -> String { (item.data["published_at"] as? String) ?? (item.data["released_at"] as? String) ?? (item.data["created_at"] as? String) ?? "" }
    static func state(_ item: HubItem) -> String { item.data["draft"] as? Bool == true ? "Draft" : item.data["prerelease"] as? Bool == true ? "Prerelease" : "Stable" }
    static func family(_ item: HubItem) -> String {
        let value = tag(item)
        if let version = version(value) { return version.family }
        if let index = value.lastIndex(where: { "@/".contains($0) }), index < value.index(before: value.endIndex) { return String(value[...index]) }
        return ""
    }
    static func ordered(_ items: [HubItem], byVersion: Bool = false) -> [HubItem] {
        let versions = items.map { version(tag($0)) }
        let numericOrder = byVersion && versions.allSatisfy { $0 != nil && $0?.family == versions.first.flatMap { $0 }?.family }
        return items.sorted { a, b in
            if numericOrder, let n = compare(tag(a), tag(b)), n != 0 { return n > 0 }
            if date(a) != date(b) { return date(a) > date(b) }
            return a.id < b.id
        }
    }
    static func compareURL(_ target: RepoTarget?, base: String, head: String) -> URL? {
        guard let target, !base.isEmpty, !head.isEmpty, base != head,
              ![base, head].contains(where: { $0.unicodeScalars.contains { CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) } }) else { return nil }
        let a = version(base), b = version(head)
        guard a?.family == b?.family else { return nil }
        if a == nil && b == nil {
            func prefix(_ s: String) -> String { s.components(separatedBy: CharacterSet(charactersIn: "@/")).dropLast().joined(separator: "/") }
            guard prefix(base) == prefix(head) else { return nil }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let from = base.addingPercentEncoding(withAllowedCharacters: allowed), let to = head.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://\(target.host)/\(target.path)/\(target.provider == .gitlab ? "-/" : "")compare/\(from)...\(to)")
    }
    static func assetSize(_ size: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}
