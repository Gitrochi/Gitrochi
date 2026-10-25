import Foundation

/// 로컬 브랜치·태그와 HEAD 의 위치(되돌리기의 '전'과 '후')
struct RefSnapshot: Equatable {
    /// refs/heads/*, refs/tags/* → 가리키는 객체
    var refs: [String: String] = [:]
    /// HEAD 가 가리키는 브랜치(refs/heads/x). 분리된 HEAD 면 nil
    var headRef: String?
    /// HEAD 커밋(아직 커밋이 없으면 nil)
    var head: String?
}

/// 되돌릴 수 있는 git 작업 하나
struct UndoPoint: Identifiable {
    let id = UUID()
    let title: String
    /// 커밋·amend 는 되돌려도 변경을 스테이지된 채로 남긴다(reset --soft). 그 밖에는 작업 트리까지(reset --keep)
    let soft: Bool
    let before: RefSnapshot
    let after: RefSnapshot

    /// 되돌리면 무엇이 바뀌는지(확인 창에 보여 줌)
    var summary: String {
        var lines: [String] = []
        if before.headRef != after.headRef {
            lines.append(String(localized: "Returns to '\(Self.short(before.headRef) ?? String(localized: "Detached HEAD"))'."))
        }
        if let ref = before.headRef, before.refs[ref] != after.refs[ref], let old = before.refs[ref] {
            lines.append(soft
                ? String(localized: "Undoes the commit and leaves its changes staged.")
                : String(localized: "Moves '\(Self.short(ref) ?? ref)' back to the previous commit (\(old.prefix(7))). Uncommitted changes are kept."))
        }
        for ref in Set(before.refs.keys).union(after.refs.keys).sorted() where ref != before.headRef {
            let name = Self.short(ref) ?? ref
            let kind = ref.hasPrefix("refs/tags/") ? String(localized: "tag") : String(localized: "branch")
            switch (before.refs[ref], after.refs[ref]) {
            case (nil, _?): lines.append(String(localized: "Deletes the \(kind) '\(name)' that was created."))
            case (let old?, nil): lines.append(String(localized: "Restores the deleted \(kind) '\(name)' at \(old.prefix(7))."))
            case (let old?, let new?) where old != new: lines.append(String(localized: "Moves \(kind) '\(name)' back to \(old.prefix(7))."))
            default: break
            }
        }
        return lines.joined(separator: "\n")
    }

    static func short(_ ref: String?) -> String? {
        guard let ref else { return nil }
        for p in ["refs/heads/", "refs/tags/"] where ref.hasPrefix(p) { return String(ref.dropFirst(p.count)) }
        return ref
    }
}

/// 되돌리기: run() 이 git 작업 전후의 브랜치·태그·HEAD 를 기록해 두고, 그대로 되돌린다.
/// 원격(push·원격 브랜치)과 작업 트리만 바꾸는 일(변경 버리기·stash)은 기록하지 않는다.
extension RepoStore {
    func refSnapshot() async -> RefSnapshot? {
        guard let url else { return nil }
        async let refsR = Git.raw(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"], in: url)
        async let headRefR = Git.raw(["symbolic-ref", "-q", "HEAD"], in: url)
        async let headR = Git.raw(["rev-parse", "-q", "--verify", "HEAD"], in: url)
        guard let refs = try? await refsR, refs.status == 0 else { return nil }
        var s = RefSnapshot()
        for line in refs.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { s.refs[String(parts[0])] = String(parts[1]) }
        }
        if let r = try? await headRefR, r.status == 0 { s.headRef = r.output.trimmed }
        if let r = try? await headR, r.status == 0 { s.head = r.output.trimmed }
        return s
    }

    /// run() 이 부른다: 무엇을 했는지 이름 붙여 기록(브랜치·태그·HEAD 가 바뀐 경우만)
    func recordUndo(args: [String], input: String?, before: RefSnapshot, after: RefSnapshot) {
        guard before != after else { return }
        let soft = args.first == "commit"
        undoStack.append(UndoPoint(title: Self.undoTitle(args, input: input, after: after), soft: soft, before: before, after: after))
        if undoStack.count > 30 { undoStack.removeFirst(undoStack.count - 30) }
    }

    static func undoTitle(_ args: [String], input: String?, after: RefSnapshot) -> String {
        var args = args
        while args.first == "-c" { args.removeFirst(min(2, args.count)) }   // git -c 설정 이름=값 …
        let last = args.last ?? ""
        switch args.first {
        case "commit":
            let subject = input?.split(separator: "\n").first.map { String($0).trimmed } ?? ""
            return (args.contains("--amend") ? String(localized: "Amend commit") : String(localized: "Commit")) + (subject.isEmpty ? "" : " '\(subject)'")
        case "switch", "checkout":
            if args.contains("-c") || args.contains("-b") { return String(localized: "Create and check out branch '\(UndoPoint.short(after.headRef) ?? last)'") }
            return String(localized: "Check out '\(UndoPoint.short(after.headRef) ?? String(last.prefix(7)))'")
        case "merge": return args.contains("--ff-only") ? String(localized: "Fast-forward to '\(last)'") : String(localized: "Merge '\(last)'")
        case "rebase": return args.contains("-i") ? String(localized: "Clean up commits") : String(localized: "Rebase onto '\(last)'")
        case "reset": return "Reset(\(args.dropFirst().first?.replacingOccurrences(of: "--", with: "") ?? ""))"
        case "cherry-pick": return "Cherry-pick"
        case "revert": return "Revert"
        case "pull": return "Pull"
        case "fetch": return String(localized: "Fast-forward")
        case "branch": return args.contains("-d") || args.contains("-D") ? String(localized: "Delete branch '\(last)'") : String(localized: "Create branch '\(args.dropFirst().first ?? last)'")
        case "tag": return args.contains("-d") ? String(localized: "Delete tag '\(last)'") : String(localized: "Create tag")
        case "worktree": return String(localized: "Create worktree")
        default: return "git \(args.first ?? "")"
        }
    }

    func confirmUndo() {
        guard let p = undoStack.last else { return }
        confirm = ConfirmRequest(title: String(localized: "Undo “\(p.title)”?"), message: p.summary,
                                 actionTitle: String(localized: "Undo"), destructive: false) { [weak self] in
            await self?.undo()
        }
    }

    /// 마지막 작업을 되돌린다. 그 뒤로 저장소가 바뀌었으면(터미널에서 커밋 등) 엉뚱하게 되돌리지 않도록 하지 않는다.
    func undo() async {
        guard let p = undoStack.last, let url, busy == nil else { return }
        guard let now = await refSnapshot(), now == p.after else {
            undoStack.removeAll()
            errorMessage = String(localized: "The repository changed since then (a commit, checkout, etc. elsewhere), so “\(p.title)” can't be undone.")
            return
        }
        busy = String(localized: "Undoing…")
        defer { busy = nil }
        do {
            // 커밋을 취소하면 그 메시지를 입력 칸에 돌려 놓는다
            if p.soft, summary.isEmpty, message.isEmpty, let h = p.after.head,
               let r = try? await Git.run(["log", "-1", "--format=%B", h], in: url) {
                let lines = r.output.trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                summary = lines.first ?? ""
                message = lines.dropFirst().joined(separator: "\n").trimmed
            }
            // 1) 체크아웃이 바뀌었으면 원래 자리로
            if p.before.headRef != p.after.headRef {
                if let ref = p.before.headRef, let name = UndoPoint.short(ref), p.after.refs[ref] != nil {
                    try await Git.run(["switch", name], in: url)
                } else if p.before.headRef == nil, let h = p.before.head {
                    try await Git.run(["switch", "--detach", h], in: url)
                }
            }
            // 2) 원래 브랜치(지금 체크아웃한 브랜치)의 끝이 움직였으면 reset
            let oldTip = p.before.headRef.flatMap { p.before.refs[$0] } ?? p.before.head
            let newTip = p.before.headRef.flatMap { p.after.refs[$0] } ?? p.after.head
            if let oldTip, oldTip != newTip {
                try await Git.run(["reset", p.soft ? "--soft" : "--keep", oldTip], in: url)
            } else if oldTip == nil, let newTip, p.soft, let ref = p.before.headRef {
                try await Git.run(["update-ref", "-d", ref, newTip], in: url)
            }
            // 3) 나머지 브랜치·태그: 생긴 건 지우고, 없어진 건 되살리고, 옮겨진 건 되돌린다
            for ref in Set(p.before.refs.keys).union(p.after.refs.keys) where ref != p.before.headRef {
                switch (p.before.refs[ref], p.after.refs[ref]) {
                case (nil, let new?): try await Git.run(["update-ref", "-d", ref, new], in: url)
                case (let old?, nil): try await Git.run(["update-ref", ref, old], in: url)
                case (let old?, let new?) where old != new: try await Git.run(["update-ref", ref, old, new], in: url)
                default: break
                }
            }
            undoStack.removeLast()
        } catch {
            errorMessage = String(localized: "Couldn't undo.\n\n") + describe(error)
        }
        await reload()
    }
}
