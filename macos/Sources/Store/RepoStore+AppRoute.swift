import Foundation

extension RepoStore {
    /// 저장소를 연 뒤에만 탐색한다. 줄은 실제 blame 행으로 이동하고 화면에 강조한다.
    func applyAppRoute(_ route: AppRoute) async {
        guard url?.resolvingSymlinksInPath().path == route.repo.path else { return }
        if let commit = route.commit {
            closeFileInspect()
            select(.commit(commit))
            reveal(commit)
            await detailTask?.value
            if let file = route.file, selection == .commit(commit), let change = detailFiles.first(where: { $0.paths.contains(file) }) {
                openDiff(.commit(sha: commit, change: change, parent: nil))
            }
            return
        }
        if let file = route.file {
            if route.view == "diff", let change = (status.unstaged + status.staged).first(where: { $0.paths.contains(file) }) {
                openDiff(.working(change))
            } else if let line = route.line {
                openBlame(file)
                fileInspectLine = line
            } else {
                openFileHistory(file)
            }
        } else if route.view == "affected" {
            await openAffectedGraph()
        } else if route.view == "precise" {
            await openStructureGraph(.files, precise: true)
        } else if let view = route.view, let relation = Gitch.GraphRelation(rawValue: view) {
            await openStructureGraph(relation)
        } else {
            navigate(.commits)
            closeFileInspect()
            closeDiff()
        }
    }
}
