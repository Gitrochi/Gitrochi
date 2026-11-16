import Foundation

// The pure parts of the sidebar's Branches tab: grouping branches into folders and narrowing them with the Filter
// branches field. (Windows: widgets/sidebar/lib/branch-filter.ts)

/// Branches that share the part of their names before the first "/" (feature, fix …)
struct BranchFolder: Identifiable {
    let name: String
    let branches: [Branch]
    var id: String { name }
}

struct BranchFolders {
    /// Branches outside a folder, a folder's only branch among them
    let loose: [Branch]
    let folders: [BranchFolder]

    /// Groups by the first "/" of `key`; a folder of one stays a loose branch under its whole name
    init(_ branches: [Branch], key: (Branch) -> String) {
        var loose: [Branch] = []
        var byFolder: [String: [Branch]] = [:]
        for b in branches {
            let k = key(b)
            if let slash = k.firstIndex(of: "/") {
                byFolder[String(k[..<slash]), default: []].append(b)
            } else {
                loose.append(b)
            }
        }
        var folders: [BranchFolder] = []
        for (name, list) in byFolder {
            if list.count == 1 { loose.append(list[0]) } else { folders.append(BranchFolder(name: name, branches: list)) }
        }
        self.loose = loose.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
        self.folders = folders.sorted { $0.name < $1.name }
    }

    private init(loose: [Branch], folders: [BranchFolder]) {
        self.loose = loose
        self.folders = folders
    }

    /// How many branches the folders hold
    var count: Int { loose.count + folders.reduce(0) { $0 + $1.branches.count } }

    /// The folders narrowed to the names that match. A folder keeps its place and its form even with one match left,
    /// so the tree does not regroup while typing; a folder without a match is left out.
    func filtered(_ query: String) -> BranchFolders {
        guard !query.isEmpty else { return self }
        let keep = { (b: Branch) in BranchFilter.matches(b.name, query) }
        return BranchFolders(loose: loose.filter(keep),
                             folders: folders.map { BranchFolder(name: $0.name, branches: $0.branches.filter(keep)) }.filter { !$0.branches.isEmpty })
    }

    /// The name without its folder (feature/auth-jwt → auth-jwt)
    static func leaf(_ name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

/// The Filter branches field's matching
enum BranchFilter {
    /// What the field's text matches with: trimmed, in lower case; "" filters nothing
    static func query(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether a branch or tag's whole name (feature/login, origin/main, v1.2.0) contains the query
    static func matches(_ name: String, _ query: String) -> Bool {
        query.isEmpty || name.lowercased().contains(query)
    }
}
