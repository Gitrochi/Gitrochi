import Foundation

/// 이미지 파일의 바뀌기 전·후(diff 화면에서 나란히 보여 준다)
struct DiffImages {
    var old: Data?
    var new: Data?
}

/// diff 화면: 줄 고르기, 덩어리·줄 단위 스테이지·언스테이지·버리기, 이미지 비교, 보기 설정
extension RepoStore {
    enum LineAction { case stage, unstage, discard }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "ico"]

    /// 나란히 보기(왼쪽 이전, 오른쪽 이후)
    var diffSplit: Bool {
        get { UserDefaults.standard.bool(forKey: "diffSplit") }
        set { UserDefaults.standard.set(newValue, forKey: "diffSplit"); diffSettingsVersion += 1 }
    }

    /// 공백만 바뀐 줄은 같은 것으로(git diff -w). 켜면 줄 단위 스테이지는 끈다(패치가 맞지 않아서).
    var diffIgnoreWhitespace: Bool {
        get { UserDefaults.standard.bool(forKey: "diffIgnoreWhitespace") }
        set {
            UserDefaults.standard.set(newValue, forKey: "diffIgnoreWhitespace")
            diffSettingsVersion += 1
            loadDiff(keepCurrent: true)
        }
    }

    /// 이 diff 에서 덩어리·줄 단위로 스테이지·언스테이지·버리기를 할 수 있는지
    var canEditDiffLines: Bool {
        guard case .working(let c)? = diffSource, let doc = diff, !diffIgnoreWhitespace,
              c.kind != .untracked, c.kind != .conflicted else { return false }
        return DiffPatch.canEdit(doc)
    }

    /// 줄 누르기: 그냥 누르면 그 줄만 넣고 빼기, Shift 와 함께면 앞에 누른 줄부터 같은 덩어리 안에서 범위로
    func toggleDiffLine(_ line: DiffLine, extend: Bool) {
        guard line.kind == .added || line.kind == .removed, let doc = diff else { return }
        if extend, let anchor = diffSelectionAnchor, let a = doc.lines.firstIndex(where: { $0.id == anchor }),
           let b = doc.lines.firstIndex(where: { $0.id == line.id }), doc.lines[a].hunk == line.hunk {
            for l in doc.lines[min(a, b)...max(a, b)] where l.kind == .added || l.kind == .removed {
                diffSelection.insert(l.id)
            }
        } else if diffSelection.contains(line.id) {
            diffSelection.remove(line.id)
        } else {
            diffSelection.insert(line.id)
        }
        diffSelectionAnchor = line.id
    }

    /// 이 덩어리에서 고른 줄 수
    func selectedCount(inHunk hunk: Int) -> Int {
        diff?.lines.filter { $0.hunk == hunk && diffSelection.contains($0.id) }.count ?? 0
    }

    /// 덩어리(고른 줄이 있으면 그 줄만)를 스테이지·언스테이지·버리기
    func applyLines(_ action: LineAction, hunk: Int) async {
        guard let doc = diff, canEditDiffLines else { return }
        let picked = Set(doc.lines.filter { $0.hunk == hunk && diffSelection.contains($0.id) }.map(\.id))
        guard let patch = DiffPatch.build(doc, hunks: [hunk], lines: picked.isEmpty ? nil : picked, reverse: action != .stage) else { return }
        if action == .discard {
            guard let repository = url, let source = diffSource,
                  await preserveDiscardedChanges(paths: source.change.paths), url == repository else { return }
        }
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        switch action {
        case .stage: args.append("--cached")
        case .unstage: args += ["--cached", "--reverse"]
        case .discard: args.append("--reverse")
        }
        let label = action == .stage ? String(localized: "Staging…") : (action == .unstage ? String(localized: "Unstaging…") : String(localized: "Discarding changes…"))
        if await run(label, args + ["-"], input: patch) {
            diffSelection = []
            diffSelectionAnchor = nil
        }
    }

    func confirmDiscardLines(hunk: Int) {
        let n = selectedCount(inHunk: hunk)
        confirm = ConfirmRequest(title: n > 0 ? String(localized: "Discard changes in \(n) selected lines?") : String(localized: "Discard the changes in this hunk?"),
                                 message: String(localized: "A local recovery copy of this file is saved before discarding the selected changes."),
                                 actionTitle: String(localized: "Discard")) { [weak self] in
            await self?.applyLines(.discard, hunk: hunk)
        }
    }

    /// 이미지 파일이면 바뀌기 전·후를 읽는다(그 밖이면 nil)
    func loadDiffImages(_ source: DiffSource) async -> DiffImages? {
        let c = source.change
        guard let url, Self.imageExtensions.contains((c.path as NSString).pathExtension.lowercased()) else { return nil }
        func show(_ spec: String) async -> Data? {
            guard let r = try? await Git.raw(["show", spec], in: url), r.status == 0 else { return nil }
            return r.data
        }
        var images = DiffImages()
        switch source {
        case .working(let c):
            if c.staged {
                if c.kind != .added { images.old = await show("HEAD:\(c.oldPath ?? c.path)") }
                if c.kind != .deleted { images.new = await show(":\(c.path)") }
            } else {
                if c.kind != .untracked { images.old = await show(":\(c.oldPath ?? c.path)") }
                if c.kind != .deleted { images.new = try? Data(contentsOf: url.appendingPathComponent(c.path)) }
            }
        case .commit(let sha, let c, let parent):
            if c.kind != .added, let parent { images.old = await show("\(parent):\(c.oldPath ?? c.path)") }
            if c.kind != .deleted { images.new = await show("\(sha):\(c.path)") }
        case .review, .worktree:
            return nil
        }
        return images.old == nil && images.new == nil ? nil : images
    }
}
