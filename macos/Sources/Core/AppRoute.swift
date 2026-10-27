import Foundation

/// CLI 와 브라우저가 공유하는 탐색 URL. 실행 명령이나 외부 파일 경로는 받지 않는다.
struct AppRoute: Equatable {
    let repo: URL
    let file: String?
    let line: Int?
    let view: String?
    let commit: String?

    enum Invalid: Error, LocalizedError {
        case link
        case notInRepository(String)
        var errorDescription: String? {
            switch self {
            case .link: return String(localized: "Couldn't open the app link. Use an absolute repository path and a file inside that repository.")
            case .notInRepository(let name): return String(localized: "Couldn't open \(name): it isn't inside a Git repository.")
            }
        }
    }

    /// A folder or file handed to the app (Finder's Open With, the Dock icon, `open -a`): open the repository that holds it.
    /// (Windows: src-tauri/src/launch.rs, folder_route)
    init(opening item: URL) throws {
        let fm = FileManager.default
        var folder = item.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { throw Invalid.notInRepository(item.lastPathComponent) }
        if !isDirectory.boolValue { folder.deleteLastPathComponent() }
        var root = folder
        // .git is a folder in a repository and a file in a linked worktree
        while !fm.fileExists(atPath: root.appendingPathComponent(".git").path) {
            guard root.path != "/" else { throw Invalid.notInRepository(item.lastPathComponent) }
            root.deleteLastPathComponent()
        }
        repo = root
        file = nil
        line = nil
        view = nil
        commit = nil
    }

    init(url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "gitrochi", c.host == "open",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { throw Invalid.link }
        var values: [String: String] = [:]
        for item in c.queryItems ?? [] {
            guard ["repo", "file", "line", "view", "commit"].contains(item.name), values[item.name] == nil,
                  let value = item.value, !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Invalid.link }
            values[item.name] = value
        }
        guard let path = values["repo"], (path as NSString).isAbsolutePath else { throw Invalid.link }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { throw Invalid.link }
        if let file = values["file"] {
            guard !file.hasPrefix("/"), !file.contains("\\"), !file.contains(":"),
                  !file.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw Invalid.link }
            let target = root.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
            var ancestor = target
            let fm = FileManager.default
            while !fm.fileExists(atPath: ancestor.path), (try? fm.destinationOfSymbolicLink(atPath: ancestor.path)) == nil, ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            let resolved = ancestor.resolvingSymlinksInPath().path
            guard resolved == root.path || resolved.hasPrefix(root.path + "/") else { throw Invalid.link }
        }
        var number: Int?
        if let value = values["line"] {
            guard values["file"] != nil, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let n = Int(value), n > 0, n <= 999_999_999 else { throw Invalid.link }
            number = n
        }
        if let view = values["view"] {
            guard ["graph", "files", "modules", "changes", "tree", "diff", "affected", "precise"].contains(view),
                  view != "diff" || values["file"] != nil else { throw Invalid.link }
        }
        if let commit = values["commit"] {
            guard [40, 64].contains(commit.utf8.count), commit.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else { throw Invalid.link }
        }
        self.repo = root
        self.file = values["file"]
        self.line = number
        self.view = values["view"]
        self.commit = values["commit"]
    }
}
