import Foundation

/// 충돌 해결: 충돌 난 파일을 블록마다 고르고 저장한 뒤 해결됨으로 표시
extension RepoStore {
    /// 지금 진행 중인 작업에 맞는 양쪽 이름(머지·리베이스에서 '내 것'의 뜻이 다르다)
    var conflictSides: (ours: String, theirs: String) {
        switch repoState {
        case .rebasing: return (String(localized: "Base (being rebased onto)"), String(localized: "My commit"))
        case .cherryPicking: return (String(localized: "Current branch"), String(localized: "Incoming commit"))
        case .reverting: return (String(localized: "Current branch"), String(localized: "Reverting change"))
        default: return (String(localized: "Current branch"), String(localized: "Branch being merged"))
        }
    }

    func loadConflict(_ c: FileChange) {
        guard let url else { return }
        let text = (try? String(contentsOf: url.appendingPathComponent(c.path), encoding: .utf8)) ?? ""
        conflictPath = c.path
        conflictDoc = ConflictDocument.parse(text)
        conflictChoices = [:]
        let loadID = conflictDoc?.loadID
        Task { [weak self] in
            async let base = Git.raw(["show", ":1:" + c.path], in: url)
            async let signature = Git.raw(["ls-files", "--unmerged", "--stage", "-z", "--", c.path], in: url)
            let values = try? await (base, signature)
            guard let self, self.url == url, self.conflictPath == c.path, self.conflictDoc?.loadID == loadID, let values else { return }
            if values.0.status == 0 { self.conflictDoc?.baseText = values.0.output }
            self.conflictDoc?.indexSignature = values.1.output
        }
    }

    func chooseConflict(_ block: Int, _ choice: ConflictDocument.Choice?) {
        conflictChoices[block] = choice
    }

    /// 고른 대로 파일을 쓰고 해결됨으로 표시(스테이지)
    func saveConflictResolution(_ c: FileChange, editedText: String? = nil) async {
        guard let url, busy == nil, conflictPath == c.path, let doc = conflictDoc,
              !doc.isEmpty, let text = editedText ?? doc.resolved(conflictChoices) else { return }
        guard ConflictDocument.parse(text).isEmpty, text.range(of: "(?m)^<{7,}([ \\t]|$)", options: .regularExpression) == nil else { errorMessage = String(localized: "Resolve every conflict marker before saving."); return }
        do {
            let original = try String(contentsOf: url.appendingPathComponent(c.path), encoding: .utf8)
            guard original == doc.sourceText else { errorMessage = String(localized: "The conflict file changed outside this editor. Reload before saving."); return }
            if let signature = doc.indexSignature {
                let now = try await Git.run(["ls-files", "--unmerged", "--stage", "-z", "--", c.path], in: url).output
                guard self.url == url, conflictDoc?.loadID == doc.loadID, now == signature else { errorMessage = String(localized: "The conflict file changed outside this editor. Reload before saving."); return }
            }
            try Data(text.utf8).write(to: url.appendingPathComponent(c.path), options: .atomic)
        } catch {
            errorMessage = String(localized: "Couldn't save the file.\n\n") + describe(error)
            return
        }
        if await run(String(localized: "Marking as resolved…"), ["add", "--", c.path]) { closeConflict() }
    }

    /// 파일 전체를 한쪽으로(git checkout --ours/--theirs)
    func resolveWholeFile(_ c: FileChange, ours: Bool) async {
        guard await run(String(localized: "Resolving conflict…"), ["checkout", ours ? "--ours" : "--theirs", "--", c.path]) else { return }
        if await run(String(localized: "Marking as resolved…"), ["add", "--", c.path]) { closeConflict() }
    }

    /// 한쪽이 지운 파일: 남기기(스테이지) 또는 지우기
    func resolveDeleted(_ c: FileChange, keep: Bool) async {
        if await run(String(localized: "Resolving conflict…"), keep ? ["add", "--", c.path] : ["rm", "-q", "--", c.path]) { closeConflict() }
    }

    func closeConflict() {
        conflictDoc = nil
        conflictChoices = [:]
        conflictPath = nil
    }
}
