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
    /// The package a page opens with: the one whose release was published last.
    static func defaultFamily(_ items: [HubItem]) -> String {
        guard let newest = ordered(items.filter { state($0) != "Draft" }).first ?? ordered(items).first else { return "" }
        return family(newest)
    }
    /// A readable package name: its newest release's title without the version ("Desktop 1.2.0" → "Desktop").
    static func packageName(_ items: [HubItem], family value: String) -> String {
        if let newest = ordered(items.filter { family($0) == value }).first {
            let tag = tag(newest)
            var name = newest.title
            if let version = version(tag) {
                name = name.replacingOccurrences(of: "v?" + version.core.joined(separator: "\\.") + "(?:-[\\w.-]+)?", with: " ", options: [.regularExpression, .caseInsensitive])
            }
            if !tag.isEmpty { name = name.replacingOccurrences(of: tag, with: " ") }
            name = name.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"^[\s\-–—:·@/_]+|[\s\-–—:·@/_]+$"#, with: "", options: .regularExpression)
            if !name.isEmpty { return name }
        }
        return value.replacingOccurrences(of: #"[@/\-_]+$"#, with: "", options: .regularExpression)
    }
    struct Timeline { var stable: HubItem?; var prerelease: HubItem?; var path: [HubItem] }
    /// Recent releases of one package, oldest first: older stables, the newest stable, then a newer prerelease.
    static func timeline(_ items: [HubItem], family value: String, count: Int = 4) -> Timeline {
        let sorted = ordered(items.filter { family($0) == value && state($0) != "Draft" })
        guard let index = sorted.firstIndex(where: { state($0) == "Stable" }) else { return Timeline(stable: nil, prerelease: sorted.first, path: Array(sorted.prefix(1))) }
        let stable = sorted[index], prerelease = index > 0 ? sorted[0] : nil
        let older = Array(sorted[(index + 1)...].filter { state($0) == "Stable" }.prefix(count - 1).reversed())
        return Timeline(stable: stable, prerelease: prerelease, path: older + [stable] + (prerelease.map { [$0] } ?? []))
    }
    /// Installers and archives of this version come first; checksums, signatures and helper binaries fold away.
    static func assetGroups<Asset>(_ assets: [Asset], tag value: String, name: (Asset) -> String) -> (primary: [Asset], other: [Asset]) {
        let packages = assets.indices.filter { name(assets[$0]).range(of: #"\.(dmg|pkg|zip|exe|msi|msix|appimage|deb|rpm|apk|tar\.gz|tgz|tar\.xz|7z)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let versioned = version(value).map { v in packages.filter { name(assets[$0]).contains(v.core.joined(separator: ".")) } } ?? []
        let primary = Set(versioned.isEmpty ? packages : versioned)
        guard !primary.isEmpty, primary.count != assets.count else { return (assets, []) }
        return (assets.indices.filter { primary.contains($0) }.map { assets[$0] }, assets.indices.filter { !primary.contains($0) }.map { assets[$0] })
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
