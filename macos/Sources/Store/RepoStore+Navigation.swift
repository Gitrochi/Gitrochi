import Foundation

extension RepoStore {
    /// Opens a page and remembers it for the repository. A page that needs a repository is refused while none is open,
    /// so the window stays where it is (Home, as a rule).
    @discardableResult func navigate(_ page: WorkspaceDestination, prepare: Bool = true) -> Bool {
        guard page.isAvailable(hasRepository: url != nil) else { return false }
        let from = destination
        if from != page { cameFromRepository = from == .repository && page.returnsToRepository }
        destination = page
        if let url {
            var saved = UserDefaults.standard.dictionary(forKey: "workspaceDestinations") as? [String: String] ?? [:]
            saved[url.path] = page.rawValue
            UserDefaults.standard.set(saved, forKey: "workspaceDestinations")
        }
        if prepare, url != nil, page == .pullRequests {
            // the page shows one request at a time; bring back the one the user had open
            if case .pullRequest? = selection {} else {
                if let number = pullRequestSelection {
                    select(.pullRequest(number), restoringContext: true)
                } else {
                    rememberDocumentContext()
                }
            }
        }
        return true
    }

    /// The page a repository was on last time, or the repository screen; Home without a repository
    func restoreWorkspaceDestination() {
        let saved = UserDefaults.standard.dictionary(forKey: "workspaceDestinations") as? [String: String] ?? [:]
        let page = url.flatMap { saved[$0.path] }.flatMap(WorkspaceDestination.init(rawValue:)) ?? (url == nil ? .home : .repository)
        navigate(page.isAvailable(hasRepository: url != nil) ? page : .home, prepare: true)
    }

    /// A graph selection made from the Pull requests page (keyboard, routes) belongs to the repository screen
    func syncWorkspaceSelection(_ selection: Selection?) {
        guard !workspaceNavigationPreparing, let selection, destination == .pullRequests else { return }
        if case .pullRequest = selection { return }
        navigate(.repository, prepare: false)
    }
}
