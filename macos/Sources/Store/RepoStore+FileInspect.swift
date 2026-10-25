import Foundation

/// 파일 히스토리·blame: 가운데 영역(그래프 자리)에 띄운다
extension RepoStore {
    func openFileHistory(_ path: String) {
        closeFileInspect()
        fileInspectLine = nil
        fileInspect = FileInspect(mode: .history, path: path)
        Task { await loadFileInspect() }
    }

    func openBlame(_ path: String, rev: String? = nil) {
        closeFileInspect()
        fileInspectLine = nil
        fileInspect = FileInspect(mode: .blame, path: path, rev: rev)
        Task { await loadFileInspect() }
    }

    func setFileInspectMode(_ mode: FileInspect.Mode) {
        guard var f = fileInspect, f.mode != mode else { return }
        f.mode = mode
        fileInspect = f
        Task { await loadFileInspect() }
    }

    func closeFileInspect() {
        fileInspectGeneration += 1
        fileHistoryGeneration += 1
        fileInspectLoading = false
        fileInspectLine = nil
        fileInspect = nil
        fileHistory = []
        fileHistoryDiff = nil
        fileHistorySelected = nil
        blameLines = []
        fileInspectError = nil
    }

    func loadFileInspect() async {
        guard let url, let f = fileInspect else { return }
        fileInspectGeneration += 1
        let generation = fileInspectGeneration
        fileInspectLoading = true
        fileInspectError = nil
        defer { if fileInspectGeneration == generation { fileInspectLoading = false } }
        do {
            switch f.mode {
            case .history:
                let r = try await Git.run(["log", "--follow", "-M", "--name-only", "-z", "--format=" + Parsers.fileHistoryFormat, "--", f.path], in: url)
                let list = await Task.detached { Parsers.fileHistory(r.output) }.value
                guard fileInspectGeneration == generation, self.url == url, fileInspect == f else { return }
                fileHistory = list
                if let first = list.first, fileHistorySelected == nil || !list.contains(where: { $0.id == fileHistorySelected }) {
                    await selectHistory(first)
                }
            case .blame:
                let r = try await Git.run(["blame", "--porcelain"] + (f.rev.map { [$0] } ?? []) + ["--", f.path], in: url)
                let lines = await Task.detached { Parsers.blame(r.output) }.value
                guard fileInspectGeneration == generation, self.url == url, fileInspect == f else { return }
                blameLines = lines
            }
        } catch {
            guard fileInspectGeneration == generation, self.url == url, fileInspect == f else { return }
            fileInspectError = describe(error)
        }
    }

    /// 히스토리에서 커밋을 고르면 그 커밋에서 이 파일이 어떻게 바뀌었는지
    func selectHistory(_ e: FileHistoryEntry) async {
        guard let url else { return }
        fileHistoryGeneration += 1
        let generation = fileHistoryGeneration
        let inspect = fileInspect
        fileHistorySelected = e.id
        fileHistoryDiff = nil
        let base = e.commit.parents.first ?? emptyTree
        guard let r = try? await Git.run(["diff", "--no-ext-diff", "-M", base, e.commit.id, "--", e.path], in: url) else {
            guard fileHistoryGeneration == generation, self.url == url, fileInspect == inspect else { return }
            fileHistoryDiff = DiffDocument(error: String(localized: "Couldn't read this commit's changes."))
            return
        }
        let doc = await Task.detached { Parsers.diff(r.output) }.value
        guard fileHistoryGeneration == generation, self.url == url, fileInspect == inspect else { return }
        fileHistoryDiff = doc
    }
}
