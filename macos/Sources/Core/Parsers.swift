import Foundation

/// Git 출력 해석은 공통 Rust 코어에 모으고 UI 모델 변환만 담당한다.
enum Parsers {
    static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s%x1f%b%x1e"
    static let refFormat = "%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)"
    static let detailFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B"
    static let stashFormat = "%gd%x1f%H%x1f%gs"
    static let fileHistoryFormat = "%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s"
    private static func read(_ op: String, _ text: String) -> Any { RustCore.call(op, ["text": text]) }
    private static func date(_ value: Any?) -> Date { Date(timeIntervalSince1970: (value as? NSNumber)?.doubleValue ?? 0) }
    private static func commit(_ v: [String: Any]) -> Commit {
        Commit(id: RustCore.string(v["id"]), parents: RustCore.strings(v["parents"]), author: RustCore.string(v["author"]),
               email: RustCore.string(v["email"]), date: date(v["date"]), subject: RustCore.string(v["subject"]), body: RustCore.string(v["body"]))
    }
    static func log(_ data: Data) -> [Commit] { RustCore.objects(read("log", String(decoding: data, as: UTF8.self))).map(commit) }
    static func bodyPreview(_ text: String) -> String { RustCore.string(read("bodyPreview", text)) }
    static func commitDetail(_ text: String) -> CommitDetail? {
        guard let v = read("detail", text) as? [String: Any] else { return nil }
        return CommitDetail(sha: RustCore.string(v["sha"]), parents: RustCore.strings(v["parents"]), author: RustCore.string(v["author"]), email: RustCore.string(v["email"]),
                            date: date(v["date"]), committer: RustCore.string(v["committer"]), committerEmail: RustCore.string(v["committerEmail"]),
                            commitDate: date(v["commitDate"]), summary: RustCore.string(v["summary"]), body: RustCore.string(v["body"]))
    }
    static func refs(_ text: String) -> (locals: [Branch], remotes: [Branch], tags: [Tag]) {
        let v = RustCore.object(read("refs", text))
        func branches(_ key: String) -> [Branch] {
            RustCore.objects(v[key]).map { b in Branch(name: RustCore.string(b["name"]), target: RustCore.string(b["target"]), upstream: b["upstream"] as? String,
                ahead: RustCore.integer(b["ahead"]), behind: RustCore.integer(b["behind"]), upstreamGone: RustCore.flag(b["upstreamGone"]),
                isCurrent: RustCore.flag(b["isCurrent"]), isRemote: RustCore.flag(b["isRemote"])) }
        }
        let tags = RustCore.objects(v["tags"]).map { Tag(name: RustCore.string($0["name"]), target: RustCore.string($0["target"])) }
        return (branches("locals"), branches("remotes"), tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending })
    }
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let v = RustCore.object(read("track", text)); return (RustCore.integer(v["ahead"]), RustCore.integer(v["behind"]), RustCore.flag(v["gone"]))
    }
    static func stashes(_ text: String) -> [Stash] {
        RustCore.objects(read("stashes", text)).map { Stash(ref: RustCore.string($0["ref"]), hash: RustCore.string($0["hash"]), message: RustCore.string($0["message"])) }
    }
    static func remotes(_ text: String) -> (names: [String], urls: [String: String]) {
        let v = RustCore.object(read("remotes", text)); return (RustCore.strings(v["names"]), v["urls"] as? [String: String] ?? [:])
    }
    static func worktrees(_ text: String) -> [Worktree] {
        RustCore.objects(read("worktrees", text)).map { Worktree(path: RustCore.string($0["path"]), head: $0["head"] as? String, branch: $0["branch"] as? String,
            isMain: RustCore.flag($0["isMain"]), locked: RustCore.flag($0["locked"]), prunable: RustCore.flag($0["prunable"])) }
    }
    private static func change(_ v: [String: Any]) -> FileChange {
        let kinds: [String: ChangeKind] = ["added": .added, "modified": .modified, "deleted": .deleted, "renamed": .renamed, "copied": .copied,
                                          "typeChanged": .typeChanged, "untracked": .untracked, "conflicted": .conflicted]
        return FileChange(path: RustCore.string(v["path"]), oldPath: v["oldPath"] as? String, kind: kinds[RustCore.string(v["kind"])] ?? .modified, staged: RustCore.flag(v["staged"]))
    }
    static func status(_ data: Data) -> WorkingStatus {
        let v = RustCore.object(read("status", String(decoding: data, as: UTF8.self)))
        return WorkingStatus(branch: v["branch"] as? String, upstream: v["upstream"] as? String, ahead: RustCore.integer(v["ahead"]), behind: RustCore.integer(v["behind"]),
                             staged: RustCore.objects(v["staged"]).map(change), unstaged: RustCore.objects(v["unstaged"]).map(change), conflicted: RustCore.objects(v["conflicted"]).map(change))
    }
    static func nameStatus(_ data: Data) -> [FileChange] { RustCore.objects(read("nameStatus", String(decoding: data, as: UTF8.self))).map(change) }
    static func numstat(_ data: Data) -> [String: LineStat] {
        RustCore.object(read("numstat", String(decoding: data, as: UTF8.self))).mapValues { value in
            let v = RustCore.object(value); return LineStat(added: RustCore.optionalInteger(v["added"]), deleted: RustCore.optionalInteger(v["deleted"]))
        }
    }
    static func diff(_ text: String, maxLines: Int = 20_000) -> DiffDocument {
        document(RustCore.object(RustCore.call("diffBundle", ["text": text, "maxLines": maxLines])))
    }
    static func document(_ bundle: [String: Any]) -> DiffDocument {
        let v = RustCore.object(bundle["doc"])
        var doc = DiffDocument()
        let kinds: [String: DiffLine.Kind] = ["context": .context, "added": .added, "removed": .removed, "hunk": .hunk, "meta": .meta]
        doc.lines = RustCore.objects(v["lines"]).enumerated().map { i, l in
            let kind = kinds[RustCore.string(l["kind"])] ?? .context
            let spans = (l["changes"] as? [[Int]] ?? []).filter { $0.count == 2 }.map { $0[0]..<$0[1] }
            return DiffLine(id: i, kind: kind, text: kind == .meta ? String(localized: "No newline at end of file") : RustCore.string(l["text"]),
                            oldNo: RustCore.optionalInteger(l["oldNo"]), newNo: RustCore.optionalInteger(l["newNo"]), raw: RustCore.string(l["raw"]), hunk: RustCore.optionalInteger(l["hunk"]), changes: spans)
        }
        doc.isBinary = RustCore.flag(v["isBinary"]); doc.truncated = RustCore.flag(v["truncated"])
        doc.header = RustCore.strings(v["header"]); doc.combined = RustCore.flag(v["combined"]); doc.multipleFiles = RustCore.flag(v["multipleFiles"])
        doc.hunks = RustCore.objects(v["hunks"]).map { h in DiffHunk(line: RustCore.integer(h["line"]), oldStart: RustCore.integer(h["oldStart"]), oldCount: RustCore.integer(h["oldCount"]), newStart: RustCore.integer(h["newStart"]), newCount: RustCore.integer(h["newCount"])) }
        let info = RustCore.object(v["info"])
        doc.info = DiffFileInfo(newFile: RustCore.flag(info["newFile"]), deletedFile: RustCore.flag(info["deletedFile"]), oldMode: info["oldMode"] as? String,
                               newMode: info["newMode"] as? String, renameFrom: info["renameFrom"] as? String, renameTo: info["renameTo"] as? String, similarity: RustCore.optionalInteger(info["similarity"]))
        doc.splitRows = RustCore.objects(bundle["rows"]).enumerated().map { i, r in DiffSplitRow(id: i, full: RustCore.optionalInteger(r["full"]), left: RustCore.optionalInteger(r["left"]), right: RustCore.optionalInteger(r["right"])) }
        doc.hasOldSide = doc.lines.contains { $0.oldNo != nil }; doc.hasNewSide = doc.lines.contains { $0.newNo != nil }
        return doc
    }
    static func fileHistory(_ text: String) -> [FileHistoryEntry] {
        RustCore.objects(read("fileHistory", text)).map { FileHistoryEntry(commit: commit(RustCore.object($0["commit"])), path: RustCore.string($0["path"])) }
    }
    static func blame(_ text: String) -> [BlameLine] {
        RustCore.objects(read("blame", text)).map { BlameLine(id: RustCore.integer($0["no"]), sha: RustCore.string($0["sha"]), text: RustCore.string($0["text"]),
            author: RustCore.string($0["author"]), email: RustCore.string($0["email"]), date: date($0["date"]), summary: RustCore.string($0["summary"]), startsBlock: RustCore.flag($0["startsBlock"])) }
    }
}

extension String {
    /// \n 으로만 나눈 줄들(끝의 \r 은 남는다). Swift 는 \r\n 을 한 글자로 보아 split(separator: "\n") 으로는 CRLF 줄이 나뉘지 않는다.
    func lfLines() -> [String] {
        utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
    }
}
