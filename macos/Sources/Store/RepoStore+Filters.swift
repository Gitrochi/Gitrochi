import Foundation

/// 그래프 거르기: 브랜치 숨기기·고정, 현재 브랜치만 보기(저장소마다 기억)
extension RepoStore {
    private static let hiddenKey = "graphHiddenRefs"
    private static let pinnedKey = "pinnedBranches"
    private static let pinnedRefsKey = "pinnedRefs"
    private static let currentOnlyKey = "graphCurrentOnly"

    func loadGraphFilters() {
        guard let path = url?.path else { return }
        let d = UserDefaults.standard
        hiddenRefs = Set((d.dictionary(forKey: Self.hiddenKey)?[path] as? [String]) ?? [])
        pinnedRefs = PinnedRefs.load(branches: (d.dictionary(forKey: Self.pinnedKey)?[path] as? [String]) ?? [],
                                     refs: (d.dictionary(forKey: Self.pinnedRefsKey)?[path] as? [String]) ?? [])
        graphCurrentOnly = (d.dictionary(forKey: Self.currentOnlyKey)?[path] as? Bool) ?? false
    }

    private func save(_ key: String, _ value: Any?) {
        guard let path = url?.path else { return }
        var dict = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        dict[path] = value
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func ref(of b: Branch) -> String { b.isRemote ? "refs/remotes/\(b.name)" : "refs/heads/\(b.name)" }
    static func tagRef(_ t: Tag) -> String { "refs/tags/\(t.name)" }

    func isHidden(_ b: Branch) -> Bool { hiddenRefs.contains(Self.ref(of: b)) }
    func isPinned(_ b: Branch) -> Bool { pinnedRefs.contains(Self.ref(of: b)) }
    func isTagHidden(_ t: Tag) -> Bool { hiddenRefs.contains(Self.tagRef(t)) }
    func isTagPinned(_ t: Tag) -> Bool { pinnedRefs.contains(Self.tagRef(t)) }

    /// 브랜치를 그래프에서 숨기거나 다시 보인다. 로컬 브랜치면 같은 이름의 원격 브랜치도 함께.
    func setHidden(_ b: Branch, _ hidden: Bool) async {
        var refs = [Self.ref(of: b)]
        if !b.isRemote { refs += remoteBranches.filter { $0.shortName == b.name }.map(Self.ref(of:)) }
        await setHidden(refs, hidden)
    }

    /// Hides a tag from the graph, or shows it again: its chip goes, and so do the commits only it reaches
    func setTagHidden(_ t: Tag, _ hidden: Bool) async {
        await setHidden([Self.tagRef(t)], hidden)
    }

    private func setHidden(_ refs: [String], _ hidden: Bool) async {
        if hidden { hiddenRefs.formUnion(refs) } else { hiddenRefs.subtract(refs) }
        save(Self.hiddenKey, hiddenRefs.isEmpty ? nil : hiddenRefs.sorted())
        await reload()
    }

    /// Shows every hidden branch and tag again
    func showAllBranches() async {
        hiddenRefs = []
        save(Self.hiddenKey, nil)
        await reload()
    }

    func setPinned(_ b: Branch, _ pinned: Bool) { setPinned(Self.ref(of: b), pinned) }
    func setTagPinned(_ t: Tag, _ pinned: Bool) { setPinned(Self.tagRef(t), pinned) }

    private func setPinned(_ ref: String, _ pinned: Bool) {
        if pinned { pinnedRefs.insert(ref) } else { pinnedRefs.remove(ref) }
        let stored = PinnedRefs.split(pinnedRefs)
        save(Self.pinnedKey, stored.branches.isEmpty ? nil : stored.branches)
        save(Self.pinnedRefsKey, stored.refs.isEmpty ? nil : stored.refs)
    }

    func setCurrentOnly(_ on: Bool) async {
        graphCurrentOnly = on
        save(Self.currentOnlyKey, on ? true : nil)
        await reload()
        if on, let h = headHash { scrollTarget = h }
    }

    /// 그래프에 그릴 커밋의 범위(git log 인자)
    var logScope: [String] {
        if graphCurrentOnly {
            var scope = ["HEAD"]
            if let up = status.upstream, remoteBranches.contains(where: { $0.name == up }) { scope.append("refs/remotes/\(up)") }
            return scope
        }
        return hiddenRefs.sorted().map { "--exclude=\($0)" } + ["--exclude=refs/stash", "--all"]
    }
}
