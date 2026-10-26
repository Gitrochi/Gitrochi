import Foundation

struct RepositoryTreeEntry: Identifiable, Equatable {
    let path: String
    let mode: String
    let oid: String
    let size: Int
    var id: String { path }
    var isFile: Bool { mode == "100644" || mode == "100755" }
    var isSymlink: Bool { mode == "120000" }
    var isSubmodule: Bool { mode == "160000" }
}
struct RepositoryTreeSnapshot {
    let revision: String
    let entries: [RepositoryTreeEntry]
    let truncated: Bool
}
struct RepositoryBlobPreview {
    var text: String?
    var image: Data?
    var notice: String?
}
struct RepositoryBrowserError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
/// Reads only immutable Git objects. Symbolic links and submodules are displayed as data, never followed.
enum RepositoryBrowser {
    /// 링크·서브모듈·대형 파일은 자동 미리보기에서 제외한다.
    static func initialFile(_ entries: [RepositoryTreeEntry]) -> RepositoryTreeEntry? {
        let files = entries.filter { $0.isFile && $0.size <= textLimit }
        func matches(_ path: String, _ pattern: String) -> Bool { path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        return files.first { matches($0.path, "^readme(?:\\.(?:md|markdown|rst|txt))?$") }
            ?? files.first { matches($0.path, "^(?:package\\.json|Package\\.swift|Cargo\\.toml|CONTRIBUTING\\.md)$") }
            ?? files.first { matches($0.path, "\\.(?:md|txt|rst|swift|tsx?|jsx?|rs|py|go|kt|java|cs|cpp|c|h)$") }
    }
    static func folderCount(_ entries: [RepositoryTreeEntry]) -> Int {
        var folders = Set<String>()
        for entry in entries { let parts = entry.path.split(separator: "/"); if parts.count > 1 { for count in 1..<parts.count { folders.insert(parts.prefix(count).joined(separator: "/")) } } }
        return folders.count
    }

    static let textLimit = 2_000_000, imageLimit = 8_000_000, entryLimit = 25_000
    static func objectID(_ value: String) -> Bool { value.range(of: "^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", options: .regularExpression) != nil }
    static func validRevision(_ value: String) -> Bool { !value.isEmpty && value.count <= 1024 && !value.hasPrefix("-") && !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 } }
    static func safePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func parseTree(_ output: String) -> [RepositoryTreeEntry] {
        output.split(separator: "\0").compactMap { row in
            guard let tab = row.firstIndex(of: "\t") else { return nil }
            let info = row[..<tab].split(whereSeparator: { $0 == " " }).map(String.init), path = String(row[row.index(after: tab)...])
            guard info.count == 4, safePath(path), objectID(info[2]), ["100644", "100755", "120000", "160000"].contains(info[0]), ["blob", "commit"].contains(info[1]), let size = info[3] == "-" ? 0 : Int(info[3]), size >= 0 else { return nil }
            return RepositoryTreeEntry(path: path, mode: info[0], oid: info[2], size: size)
        }
    }
    static func imageMIME(_ data: Data) -> String? {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if bytes.starts(with: [255, 216, 255]) { return "image/jpeg" }
        let prefix = String(decoding: bytes, as: UTF8.self)
        if prefix.hasPrefix("GIF87a") || prefix.hasPrefix("GIF89a") { return "image/gif" }
        if prefix.hasPrefix("RIFF") && String(prefix.dropFirst(8)) == "WEBP" { return "image/webp" }
        return nil
    }
    static func tree(in url: URL, ref: String) async throws -> RepositoryTreeSnapshot {
        guard validRevision(ref) else { throw RepositoryBrowserError(message: String(localized: "Enter a valid branch, tag or commit.")) }
        let revision = try await Git.run(["rev-parse", "--verify", ref + "^{commit}"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard objectID(revision) else { throw RepositoryBrowserError(message: String(localized: "Enter a valid branch, tag or commit.")) }
        let entries = parseTree(try await Git.run(["ls-tree", "-r", "-z", "-l", revision, "--"], in: url).output)
        return RepositoryTreeSnapshot(revision: revision, entries: Array(entries.prefix(entryLimit)), truncated: entries.count > entryLimit)
    }
    static func blob(in url: URL, entry: RepositoryTreeEntry) async throws -> RepositoryBlobPreview {
        guard safePath(entry.path), objectID(entry.oid) else { throw RepositoryBrowserError(message: String(localized: "This file cannot be displayed safely.")) }
        if entry.isSubmodule { return RepositoryBlobPreview(text: entry.oid, notice: String(localized: "Submodule commit")) }
        if entry.size > imageLimit { return RepositoryBlobPreview(notice: String(localized: "This file exceeds the 8 MB preview limit.")) }
        let rawSize = try await Git.run(["cat-file", "-s", entry.oid], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int(rawSize), size == entry.size, size <= imageLimit else { throw RepositoryBrowserError(message: String(localized: "The file size changed. Reload this revision.")) }
        let data = try await Git.run(["cat-file", "blob", entry.oid], in: url).data
        guard data.count == size else { throw RepositoryBrowserError(message: String(localized: "Couldn't read this file.")) }
        if entry.isFile && imageMIME(data) != nil { return RepositoryBlobPreview(image: data) }
        if size > textLimit { return RepositoryBlobPreview(notice: String(localized: "This text file exceeds the 2 MB preview limit.")) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return RepositoryBlobPreview(notice: String(localized: "Binary file. Text preview is unavailable.")) }
        return RepositoryBlobPreview(text: text, notice: entry.isSymlink ? String(localized: "Symbolic link target. The link is never followed.") : nil)
    }
}
