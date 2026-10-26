import Foundation

extension RepoStore {
    var pinnedRepositoryPages: [RepositorySection] {
        _ = navigationPreferencesVersion
        let saved = UserDefaults.standard.stringArray(forKey: "pinnedRepositoryPages") ?? []
        return RepositorySection.allCases.filter { saved.contains($0.rawValue) }
    }

    func isRepositoryPagePinned(_ section: RepositorySection) -> Bool { pinnedRepositoryPages.contains(section) }

    func toggleRepositoryPagePin(_ section: RepositorySection) {
        var pinned = pinnedRepositoryPages
        if let index = pinned.firstIndex(of: section) { pinned.remove(at: index) } else { pinned.append(section) }
        UserDefaults.standard.set(RepositorySection.allCases.filter { pinned.contains($0) }.map(\.rawValue), forKey: "pinnedRepositoryPages")
        navigationPreferencesVersion += 1
    }

    @discardableResult func selectRepositorySection(_ section: RepositorySection, prepare: Bool = true, remember: Bool = true) -> Bool {
        navigate(section.destination, prepare: prepare, remember: remember)
    }

    /// 이전 버전의 작업별 주소도 통합 저장소 화면의 해당 탭으로 이어 준다.
    @discardableResult func navigate(_ page: WorkspaceDestination, prepare: Bool = true, remember: Bool = true) -> Bool {
        guard !page.needsRepository || url != nil else { return false }
        return navigateLocation(WorkspaceLocation(page, section: repositorySection), prepare: prepare, remember: remember)
    }

    @discardableResult private func navigateLocation(_ location: WorkspaceLocation, prepare: Bool, remember: Bool) -> Bool {
        guard !location.destination.needsRepository || url != nil else { return false }
        let current = WorkspaceLocation(destination, section: repositorySection)
        if remember, location != current {
            navigationTrail = Array(navigationTrail.prefix(navigationPosition + 1))
            navigationTrail.append(location)
            if navigationTrail.count > 40 { navigationTrail.removeFirst() }
            navigationPosition = navigationTrail.count - 1
        }
        destination = location.destination
        repositorySection = location.repositorySection
        if let url {
            var saved = UserDefaults.standard.dictionary(forKey: "workspaceDestinations") as? [String: String] ?? [:]
            saved[url.path] = destination.rawValue
            UserDefaults.standard.set(saved, forKey: "workspaceDestinations")
            var sections = UserDefaults.standard.dictionary(forKey: "workspaceRepositorySections") as? [String: String] ?? [:]
            sections[url.path] = repositorySection.rawValue
            UserDefaults.standard.set(sections, forKey: "workspaceRepositorySections")
        }
        if prepare {
            workspaceNavigationPreparing = true
            defer { workspaceNavigationPreparing = false }
            if destination == .repository {
                switch repositorySection {
                case .changes: showArea(.changes)
                case .commits:
                    showArea(.history)
                    if case .pullRequest? = selection, let headHash { select(.commit(headHash)) }
                default: break
                }
            } else if destination == .pullRequests {
                if case .pullRequest? = selection {} else {
                    if let number = pullRequestSelection {
                        select(.pullRequest(number), restoringContext: true)
                    } else {
                        rememberDocumentContext()
                    }
                }
            }
        }
        return true
    }

    func restoreWorkspaceDestination() {
        let saved = UserDefaults.standard.dictionary(forKey: "workspaceDestinations") as? [String: String] ?? [:]
        let sections = UserDefaults.standard.dictionary(forKey: "workspaceRepositorySections") as? [String: String] ?? [:]
        let fallback: RepositorySection = area == .changes ? .changes : .commits
        let section = url.flatMap { sections[$0.path] }.flatMap(RepositorySection.init(rawValue:)) ?? fallback
        let page = url.flatMap { saved[$0.path] }.flatMap(WorkspaceDestination.init(rawValue:)) ?? .repository
        let initial = WorkspaceLocation(page, section: section)
        navigationTrail = [initial]; navigationPosition = 0
        navigateLocation(initial, prepare: true, remember: false)
    }

    func moveWorkspaceHistory(_ delta: Int) {
        let next = navigationPosition + delta
        guard navigationTrail.indices.contains(next) else { return }
        navigationPosition = next
        navigateLocation(navigationTrail[next], prepare: true, remember: false)
    }

    func syncWorkspaceSelection(_ selection: Selection?) {
        guard !workspaceNavigationPreparing, let selection else { return }
        let inDocument = destination == .repository && [.changes, .commits].contains(repositorySection)
        guard inDocument || destination == .pullRequests else { return }
        let next: WorkspaceDestination
        switch selection { case .wip: next = .changes; case .commit, .worktree: next = .commits; case .pullRequest: next = .pullRequests }
        let location = WorkspaceLocation(next, section: repositorySection)
        if location != WorkspaceLocation(destination, section: repositorySection) { navigate(next, prepare: false) }
    }
}
