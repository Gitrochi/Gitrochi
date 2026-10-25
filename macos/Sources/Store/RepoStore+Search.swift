import Foundation

/// 커밋 검색: 불러온 그래프에서 바로 찾고, 메시지 본문·파일 경로·코드 변경은 git log 로 찾는다.
extension RepoStore {
    var isSearching: Bool { !searchText.trimmed.isEmpty }

    /// 지금 선택이 검색 결과 중 몇 번째인지(1부터, 없으면 nil)
    var searchPosition: Int? {
        guard let id = selectedID, let i = searchMatches.firstIndex(of: id) else { return nil }
        return i + 1
    }

    func requestSearchFocus() {
        showArea(.history)
        closeFileInspect()
        closeDiff()
        searchFocusRequest += 1
    }

    func updateSearch() {
        searchTask?.cancel()
        let q = searchText.trimmed
        guard !q.isEmpty, let url else { clearSearchResults(); return }
        let scope = searchScope

        if scope == .commits {
            // 1) 불러온 커밋에서 즉시: 제목·작성자·이메일·SHA·브랜치/태그 이름
            let lower = q.lowercased()
            var found = Set<String>()
            for e in entries where !e.commit.isWIP {
                let c = e.commit
                if c.subject.lowercased().contains(lower) || c.author.lowercased().contains(lower)
                    || c.email.lowercased().contains(lower) || c.id.hasPrefix(lower)
                    || (refsByCommit[e.id] ?? []).contains(where: { $0.name.lowercased().contains(lower) }) {
                    found.insert(e.id)
                }
            }
            applySearch(found, jump: true)
        } else {
            searchMatches = []
            searchMatchSet = []
        }

        // 2) git 으로 더 깊게(메시지 본문, 파일 경로, 코드 변경) — 입력이 멈추면 실행
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(scope == .commits ? 350 : 500))
            guard !Task.isCancelled else { return }
            var args = ["log", "--exclude=refs/stash", "--all", "--format=%H"]
            switch scope {
            case .commits: args += ["-n", "20000", "-i", "-F", "--grep=" + q]
            case .files: args += ["-n", "20000", "--", ":(glob,icase)**/*\(q)*"]
            case .code: args += ["-n", "1000", "-G", NSRegularExpression.escapedPattern(for: q)]
            }
            let r = try? await Git.run(args, in: url, timeout: 180, env: ["GIT_LITERAL_PATHSPECS": "0"])
            guard !Task.isCancelled, searchText.trimmed == q, searchScope == scope else { return }
            searching = false
            var found = Set((r?.output ?? "").split(separator: "\n").map(String.init))
            if scope == .commits { found.formUnion(searchMatchSet) }
            applySearch(found, jump: scope != .commits || searchMatches.isEmpty)
        }
    }

    private func applySearch(_ found: Set<String>, jump: Bool) {
        let ordered = entries.compactMap { found.contains($0.id) ? $0.id : nil }
        searchMatches = ordered
        searchMatchSet = Set(ordered)
        searchUnloaded = found.subtracting(searchMatchSet).count
        // 지금 고른 커밋이 결과가 아니면 첫 결과로 이동
        if jump, let first = ordered.first, !searchMatchSet.contains(selectedID ?? "") {
            select(.commit(first))
            scrollTarget = first
        }
    }

    func clearSearchResults() {
        searchMatches = []
        searchMatchSet = []
        searchUnloaded = 0
        searching = false
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        clearSearchResults()
    }

    func nextMatch() { stepMatch(1) }
    func previousMatch() { stepMatch(-1) }

    private func stepMatch(_ d: Int) {
        guard !searchMatches.isEmpty else { return }
        let cur = searchMatches.firstIndex(of: selectedID ?? "") ?? (d > 0 ? -1 : 0)
        let sha = searchMatches[(cur + d + searchMatches.count) % searchMatches.count]
        select(.commit(sha))
        scrollTarget = sha
    }

    /// 아직 그래프에 없는 결과가 있으면 기록을 더 불러와 다시 찾는다
    func loadMoreForSearch() async {
        await loadMore()
        updateSearch()
    }
}
