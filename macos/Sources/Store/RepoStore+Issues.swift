import Foundation

/// The repository's issue list, shared by the repository sidebar and the Issues page (Windows: entities/repo/model/layers/issues.ts)
extension RepoStore {
    /// Which repository, account and filter the issue list belongs to
    var issueContextKey: String {
        "\(url?.path ?? "")|\(collaboration.contextID)|\(AccountStore.shared.revision)|\(hostingAccount?.id ?? "")|\(issueList.scope)"
    }

    /// Access that turns stale as soon as the repository, account or context changes
    var issueAccess: ReviewAccess? {
        guard var c = collaborationAccess else { return nil }
        let url = self.url, context = collaboration.contextID, revision = AccountStore.shared.revision, account = hostingAccount?.id
        c.isCurrent = { [weak self] in
            guard let self else { return false }
            return self.url == url && self.collaboration.contextID == context
                && AccountStore.shared.revision == revision && self.hostingAccount?.id == account
        }
        return c
    }

    /// Loads the list when it belongs to another context or has not been loaded; keeps an issue that is already open
    func prepareIssues() async {
        let key = issueContextKey
        guard issueList.contextKey != key || issueList.page == 0 else { return }
        if issueList.contextKey != key, collaboration.inboxDetail?.item.kind == "issue" { collaboration.inboxDetail = nil }
        issueList.reset()
        issueList.contextKey = key
        await loadIssues()
    }

    func loadIssues(append: Bool = false) async {
        guard let c = issueAccess else { return }
        issueList.contextKey = issueContextKey
        await issueList.load(c, scope: issueList.scope, search: issueList.search, append: append)
    }

    func filterIssues(scope: String) async {
        issueList.scope = scope
        issueList.reset()
        await loadIssues()
    }

    /// Shows the issue on the Issues page
    func openIssue(_ item: CollaborationInboxItem) {
        navigate(.issues)
        Task { await openInboxItem(item) }
    }

    /// Saves a new issue or an edit, then shows it
    func saveIssue(title: String, body: String, number: Int?) async throws {
        guard let c = issueAccess else { return }
        let item = try await WorkspaceOperations.saveIssue(c, title: title, body: body, number: number)
        guard c.isCurrent?() != false else { return }
        await loadIssues()
        await openInboxItem(item)
    }
}
