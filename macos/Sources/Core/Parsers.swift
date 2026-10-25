import Foundation

/// git 의 기계용 출력(porcelain, -z, 커스텀 format)을 모델로 바꾼다.
enum Parsers {
    /// 그래프 날짜는 정렬(--date-order) 기준과 같은 커밋 날짜(%ct) — 리베이스·cherry-pick 된 커밋도 순서대로 보이게
    static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s%x1f%b%x1e"
    static let refFormat = "%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)"
    static let detailFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B"
    static let stashFormat = "%gd%x1f%H%x1f%gs"

    private static func fields(_ s: Substring) -> [String] {
        s.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
    }

    private static func date(_ s: String) -> Date {
        Date(timeIntervalSince1970: TimeInterval(s) ?? 0)
    }

    // MARK: log

    static func log(_ data: Data) -> [Commit] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [Commit] = []
        for rec in text.split(separator: "\u{1e}") {
            let r = rec.drop(while: { $0.isNewline })
            guard !r.isEmpty else { continue }
            let f = fields(r)
            guard f.count >= 6 else { continue }
            out.append(Commit(id: f[0],
                              parents: f[1].split(separator: " ").map(String.init),
                              author: f[2], email: f[3], date: date(f[4]), subject: f[5],
                              body: f.count > 6 ? bodyPreview(f[6]) : ""))
        }
        return out
    }

    /// 본문에서 첫 번째 내용 줄(Co-Authored-By 같은 꼬리말은 빼고, 글머리표는 떼고, 길면 자른다)
    static func bodyPreview(_ body: String) -> String {
        for line in body.split(whereSeparator: \.isNewline) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.range(of: #"^[A-Za-z][A-Za-z0-9-]*: \S"#, options: .regularExpression) != nil { continue }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = String(l.dropFirst(2)) }
            return String(l.prefix(200))
        }
        return ""
    }

    static func commitDetail(_ text: String) -> CommitDetail? {
        let f = fields(Substring(text))
        guard f.count >= 9 else { return nil }
        let message = f[8...].joined(separator: "\u{1f}").trimmed
        let summary = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let body = String(message.dropFirst(summary.count)).trimmed
        return CommitDetail(sha: f[0], parents: f[1].split(separator: " ").map(String.init),
                            author: f[2], email: f[3], date: date(f[4]),
                            committer: f[5], committerEmail: f[6], commitDate: date(f[7]),
                            summary: summary, body: body)
    }

    // MARK: refs

    static func refs(_ text: String) -> (locals: [Branch], remotes: [Branch], tags: [Tag]) {
        var locals: [Branch] = [], remotes: [Branch] = [], tags: [Tag] = []
        for line in text.split(separator: "\n") {
            let f = fields(line)
            guard f.count >= 6 else { continue }
            let ref = f[0], obj = f[1], peeled = f[2], upstream = f[3], track = f[4]
            if ref.hasPrefix("refs/heads/") {
                let t = parseTrack(track)
                locals.append(Branch(name: String(ref.dropFirst(11)), target: obj,
                                     upstream: upstream.isEmpty ? nil : upstream,
                                     ahead: t.ahead, behind: t.behind, upstreamGone: t.gone,
                                     isCurrent: f[5] == "*", isRemote: false))
            } else if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst(13))
                if name.hasSuffix("/HEAD") { continue }
                remotes.append(Branch(name: name, target: obj, upstream: nil, ahead: 0, behind: 0,
                                      upstreamGone: false, isCurrent: false, isRemote: true))
            } else if ref.hasPrefix("refs/tags/") {
                tags.append(Tag(name: String(ref.dropFirst(10)), target: peeled.isEmpty ? obj : peeled))
            }
        }
        return (locals, remotes, tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending })
    }

    /// "ahead 2, behind 1" / "gone"
    static func parseTrack(_ s: String) -> (ahead: Int, behind: Int, gone: Bool) {
        var ahead = 0, behind = 0, gone = false
        for part in s.split(separator: ",") {
            let w = part.split(separator: " ")
            if w.first == "gone" { gone = true }
            if w.count == 2, let n = Int(w[1]) {
                if w[0] == "ahead" { ahead = n } else if w[0] == "behind" { behind = n }
            }
        }
        return (ahead, behind, gone)
    }

    static func stashes(_ text: String) -> [Stash] {
        text.split(separator: "\n").compactMap { line in
            let f = fields(line)
            guard f.count >= 3 else { return nil }
            return Stash(ref: f[0], hash: f[1], message: f[2])
        }
    }

    /// `git remote -v` → 이름 순서와 fetch URL
    static func remotes(_ text: String) -> (names: [String], urls: [String: String]) {
        var names: [String] = [], urls: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            if !names.contains(name) { names.append(name) }
            if parts.count < 3 || parts[2] == "(fetch)" { urls[name] = String(parts[1]) }
        }
        return (names, urls)
    }

    /// `git worktree list --porcelain -z` (이전 줄 구분 출력도 읽는다)
    static func worktrees(_ text: String) -> [Worktree] {
        var out: [Worktree] = []
        let nul = text.contains("\0")
        let body = nul ? text : text.replacingOccurrences(of: "\r\n", with: "\n")
        for (i, block) in body.components(separatedBy: nul ? "\0\0" : "\n\n").enumerated() {
            var path: String?, head: String?, branch: String?
            var locked = false, prunable = false, bare = false
            for line in block.components(separatedBy: nul ? "\0" : "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    let ref = line.dropFirst(7)
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref)
                }
                else if line == "bare" { bare = true }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
            }
            guard let path, !bare else { continue }
            out.append(Worktree(path: path, head: head, branch: branch, isMain: i == 0, locked: locked, prunable: prunable))
        }
        return out
    }

    // MARK: status (porcelain v2, -z)

    static func status(_ data: Data) -> WorkingStatus {
        var st = WorkingStatus()
        let tokens = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        var i = 0

        func add(_ xy: Substring, _ path: String, _ orig: String?) {
            let chars = Array(xy)
            guard chars.count == 2 else { return }
            if chars[0] != "." {
                st.staged.append(FileChange(path: path, oldPath: orig, kind: ChangeKind(code: chars[0]), staged: true))
            }
            if chars[1] != "." {
                st.unstaged.append(FileChange(path: path, oldPath: nil, kind: ChangeKind(code: chars[1]), staged: false))
            }
        }

        while i < tokens.count {
            let t = tokens[i]
            i += 1
            if t.hasPrefix("# ") {
                let parts = t.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head": st.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": st.upstream = parts[1]
                case "branch.ab":
                    for w in parts[1].split(separator: " ") {
                        if w.hasPrefix("+") { st.ahead = Int(w.dropFirst()) ?? 0 }
                        if w.hasPrefix("-") { st.behind = Int(w.dropFirst()) ?? 0 }
                    }
                default: break
                }
            } else if t.hasPrefix("1 ") {
                let f = t.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if f.count == 9 { add(f[1], String(f[8]), nil) }
            } else if t.hasPrefix("2 ") {
                let f = t.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let orig = i < tokens.count ? tokens[i] : nil
                i += 1
                if f.count == 10 { add(f[1], String(f[9]), orig) }
            } else if t.hasPrefix("u ") {
                let f = t.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if f.count == 11 {
                    st.conflicted.append(FileChange(path: String(f[10]), oldPath: nil, kind: .conflicted, staged: false))
                }
            } else if t.hasPrefix("? ") {
                st.unstaged.append(FileChange(path: String(t.dropFirst(2)), oldPath: nil, kind: .untracked, staged: false))
            }
        }
        return st
    }

    // MARK: name-status (-z)

    static func nameStatus(_ data: Data) -> [FileChange] {
        let tokens = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        var out: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let c = code.first else { continue }
            if c == "R" || c == "C" {
                guard i + 1 < tokens.count else { break }
                out.append(FileChange(path: tokens[i + 1], oldPath: tokens[i],
                                      kind: c == "R" ? .renamed : .copied, staged: false))
                i += 2
            } else {
                guard i < tokens.count else { break }
                out.append(FileChange(path: tokens[i], oldPath: nil, kind: ChangeKind(code: c), staged: false))
                i += 1
            }
        }
        return out
    }

    /// `--numstat -z`: "추가\t삭제\t경로\0", 이름 변경은 "추가\t삭제\t\0이전\0새\0"
    static func numstat(_ data: Data) -> [String: LineStat] {
        let tokens = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var out: [String: LineStat] = [:]
        var i = 0
        while i < tokens.count {
            let f = tokens[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            i += 1
            guard f.count == 3 else { continue }
            let stat = LineStat(added: Int(f[0]), deleted: Int(f[1]))
            if f[2].isEmpty {
                guard i + 1 < tokens.count else { break }
                out[tokens[i + 1]] = stat
                i += 2
            } else {
                out[f[2]] = stat
            }
        }
        return out
    }

    // MARK: unified diff

    static func diff(_ text: String, maxLines: Int = 20_000) -> DiffDocument {
        var doc = DiffDocument()
        var lines = text.lfLines()
        if lines.last?.isEmpty == true { lines.removeLast() }   // 끝의 줄바꿈
        guard !lines.isEmpty else { return doc }

        var oldNo = 0, newNo = 0, inHunk = false, cols = 1, id = 0, files = 0
        func push(_ kind: DiffLine.Kind, _ s: String, _ o: Int?, _ n: Int?, raw: String = "") {
            doc.lines.append(DiffLine(id: id, kind: kind, text: s, oldNo: o, newNo: n, raw: raw,
                                      hunk: doc.hunks.isEmpty ? nil : doc.hunks.count - 1))
            id += 1
        }

        // 줄 끝의 \r(CRLF 파일)은 화면에서는 빼고, 줄 단위 스테이지 패치용 원문(raw)에는 남긴다
        for line in lines {
            if doc.lines.count >= maxLines { doc.truncated = true; break }
            let s = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if s.hasPrefix("@@") {
                inHunk = true
                cols = max(1, s.prefix(while: { $0 == "@" }).count - 1)   // "@@" 1열, 결합 diff "@@@" 2열
                if cols > 1 { doc.combined = true }
                oldNo = hunkStart(s, "-")
                newNo = hunkStart(s, "+")
                doc.hunks.append(DiffHunk(line: doc.lines.count, oldStart: oldNo, oldCount: hunkCount(s, "-"),
                                          newStart: newNo, newCount: hunkCount(s, "+")))
                push(.hunk, s, nil, nil)
                continue
            }
            if s.hasPrefix("diff ") { inHunk = false; files += 1; doc.multipleFiles = files > 1 }
            if !inHunk {
                if files <= 1 {
                    doc.header.append(s)
                    readInfo(s, into: &doc.info)
                }
                if s.hasPrefix("Binary files") || s.hasPrefix("GIT binary patch") { doc.isBinary = true }
                continue
            }
            if s.hasPrefix("\\") { push(.meta, String(localized: "No newline at end of file"), nil, nil, raw: s); continue }
            let marker = s.prefix(cols)
            let raw = String(line.dropFirst(cols))
            let content = s.dropFirst(cols).replacingOccurrences(of: "\t", with: "    ")
            if marker.contains("+") && !marker.contains("-") {
                push(.added, content, nil, newNo, raw: raw); newNo += 1
            } else if marker.contains("-") {
                push(.removed, content, oldNo, nil, raw: raw); oldNo += 1
            } else {
                push(.context, content, oldNo, newNo, raw: raw); oldNo += 1; newNo += 1
            }
        }
        doc.hasOldSide = doc.lines.contains { $0.oldNo != nil }
        doc.hasNewSide = doc.lines.contains { $0.newNo != nil }
        WordDiff.mark(&doc)
        doc.splitRows = DiffSplit.rows(doc.lines)
        return doc
    }

    /// diff 머리 한 줄에서 새 파일·지운 파일·권한·이름 바꿈을 읽는다
    private static func readInfo(_ s: String, into info: inout DiffFileInfo) {
        func rest(_ prefix: String) -> String? { s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil }
        if let m = rest("new file mode ") { info.newFile = true; info.newMode = m }
        else if let m = rest("deleted file mode ") { info.deletedFile = true; info.oldMode = m }
        else if let m = rest("old mode ") { info.oldMode = m }
        else if let m = rest("new mode ") { info.newMode = m }
        else if let p = rest("rename from ") { info.renameFrom = p }
        else if let p = rest("rename to ") { info.renameTo = p }
        else if let v = rest("similarity index ") { info.similarity = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) }
    }

    // MARK: 파일 히스토리 · blame

    /// git log --follow --name-only 와 함께 쓰는 형식(커밋마다 \x1e 로 시작)
    static let fileHistoryFormat = "%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s"

    static func fileHistory(_ text: String) -> [FileHistoryEntry] {
        var records: [(header: String, path: String)] = []
        if text.contains("\0") {
            let fields = text.components(separatedBy: "\0")
            var i = 0
            while i < fields.count {
                let field = fields[i]
                i += 1
                guard field.hasPrefix("\u{1e}") else { continue }
                var path = ""
                if i < fields.count, fields[i].hasPrefix("\n") { path = String(fields[i].dropFirst()); i += 1 }
                records.append((String(field.dropFirst()), path))
            }
        } else {
            for rec in text.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
                let lines = rec.split(separator: "\n", omittingEmptySubsequences: true)
                guard let head = lines.first else { continue }
                records.append((String(head), lines.dropFirst().first.map(String.init) ?? ""))
            }
        }
        return records.compactMap { record in
            let f = record.header.components(separatedBy: "\u{1f}")
            guard f.count >= 6 else { return nil }
            let commit = Commit(id: f[0], parents: f[1].split(separator: " ").map(String.init), author: f[2], email: f[3],
                                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0), subject: f[5...].joined(separator: "\u{1f}"))
            return FileHistoryEntry(commit: commit, path: record.path)
        }
    }

    /// git blame --porcelain
    static func blame(_ text: String) -> [BlameLine] {
        struct Info { var author = "", email = "", time: TimeInterval = 0, summary = "" }
        var infos: [String: Info] = [:]
        var out: [BlameLine] = []
        var sha = "", lineNo = 0, prevSha = ""
        for raw in text.lfLines() {
            if raw.hasPrefix("\t") {
                let info = infos[sha] ?? Info()
                let code = raw.hasSuffix("\r") ? raw.dropFirst().dropLast() : raw.dropFirst()
                out.append(BlameLine(id: lineNo, sha: sha, text: code.replacingOccurrences(of: "\t", with: "    "),
                                     author: info.author, email: info.email, date: Date(timeIntervalSince1970: info.time),
                                     summary: info.summary, startsBlock: sha != prevSha))
                prevSha = sha
                continue
            }
            let parts = raw.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if key.count == 40 || key.count == 64, key.allSatisfy(\.isHexDigit) {
                sha = String(key)
                lineNo = Int(value.split(separator: " ").dropFirst().first ?? "") ?? lineNo + 1
                if infos[sha] == nil { infos[sha] = Info() }
                continue
            }
            switch key {
            case "author": infos[sha]?.author = value
            case "author-mail": infos[sha]?.email = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            case "author-time": infos[sha]?.time = TimeInterval(value) ?? 0
            case "summary": infos[sha]?.summary = value
            default: break
            }
        }
        return out
    }

    /// "@@ -12,5 +12,7 @@" 의 줄 수(생략되면 1)
    private static func hunkCount(_ s: String, _ sign: Character) -> Int {
        guard let r = s.range(of: " \(sign)") else { return 0 }
        let field = s[r.upperBound...].prefix(while: { $0.isNumber || $0 == "," })
        let parts = field.split(separator: ",", omittingEmptySubsequences: false)
        return parts.count > 1 ? Int(parts[1]) ?? 1 : 1
    }

    private static func hunkStart(_ s: String, _ sign: Character) -> Int {
        guard let r = s.range(of: " \(sign)") else { return 0 }
        return Int(s[r.upperBound...].prefix(while: { $0.isNumber })) ?? 0
    }
}

extension String {
    /// \n 으로만 나눈 줄들(끝의 \r 은 남는다). Swift 는 \r\n 을 한 글자로 보아 split(separator: "\n") 으로는 CRLF 줄이 나뉘지 않는다.
    func lfLines() -> [String] {
        utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
    }
}
