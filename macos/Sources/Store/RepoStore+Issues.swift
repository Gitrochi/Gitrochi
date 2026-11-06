import Foundation

/// The repository's issue list, shared by the repository sidebar and the Issues page (Windows: entities/repo/model/layers/issues.ts)
extension RepoStore {
    /// Which repository, account and filter the issue list belongs to
    var issueContextKey: String {
        "\(issueAccountKey)|\(issueList.scope)|\(issueList.sort)"
    }

    /// Which repository and account the issues belong to, whatever the filter (what is assigned to you does not depend on it)
    var issueAccountKey: String {
        "\(url?.path ?? "")|\(collaboration.contextID)|\(AccountStore.shared.revision)|\(hostingAccount?.id ?? "")"
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
        guard await resolveCollaborationAccess() != nil else { return }
        guard let c = issueAccess else { return }
        issueList.contextKey = issueContextKey
        issueList.loadedSearch = issueList.search
        await issueList.load(c, scope: issueList.scope, search: issueList.search, append: append)
    }

    func filterIssues(scope: String) async {
        issueList.scope = scope
        issueList.reset()
        await loadIssues()
    }

    /// updated, created or oldest; the list starts over in the new order
    func sortIssues(_ sort: String) async {
        issueList.sort = sort
        issueList.reset()
        await loadIssues()
    }

    /// What is assigned to this account, for the Issues page's summary and the count on its segment
    func loadAssignedIssues() async {
        let key = issueAccountKey
        if issueList.assignedKey != key { issueList.assigned = nil; issueList.assignedMore = false; issueList.assignedFailed = false; issueList.assignedKey = key }
        guard await resolveCollaborationAccess() != nil, let c = issueAccess, issueAccountKey == key else { return }
        await issueList.loadAssigned(c)
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
    /// The local branches this repository linked to the issue
    func issueBranches(_ item: CollaborationInboxItem) -> [String] {
        guard let task = issueTask(item), let path = url?.path else { return [] }
        return ProjectTaskLinks.issueBranches(task, repositoryPath: path).filter { name in localBranches.contains { $0.name == name } }
    }

    /// The branches of the loaded requests, when the request list shows open ones (a closed request is no review)
    private var openRequestBranches: Set<String> {
        ["open", "mine", "reviewRequested"].contains(collaboration.query.scope) ? Set(pullRequests.map(\.source)) : []
    }

    /// How far the issue's work is, as this repository knows it: its linked branches and their loaded requests
    func issueProgress(_ item: CollaborationInboxItem) -> IssuePage.Assigned {
        let branches = issueBranches(item)
        return IssuePage.Assigned(number: item.number, progress: IssuePage.progress(branches: branches, requestBranches: openRequestBranches),
                                  branch: branches.first { $0 == headBranch } ?? branches.first)
    }

    /// Shows a request one of the issue's branches opened on the Pull requests page
    func openIssueRequest(_ request: PullRequest) {
        navigate(.pullRequests, prepare: false)
        select(.pullRequest(request.number))
    }

    /// The loaded request each issue's branch opened, by issue number
    func issueRequests(_ items: [CollaborationInboxItem]) -> [Int: PullRequest] {
        let open = openRequestBranches
        guard !open.isEmpty else { return [:] }
        var out: [Int: PullRequest] = [:]
        for item in items {
            let branches = issueBranches(item)
            if let request = pullRequests.first(where: { branches.contains($0.source) }) { out[item.number] = request }
        }
        return out
    }

    func issueTask(_ item: CollaborationInboxItem) -> ProjectTaskReference? {
        IssueWorkflow.task(target: target, number: item.number, title: item.title, url: item.url, isIssue: item.kind == "issue" && !item.isRequest)
    }
    func requestIssueBranch(_ item: CollaborationInboxItem) {
        guard let task = issueTask(item), let headHash, busy == nil else { return }
        sheet = .newBranch(start: headHash, label: headBranch ?? "HEAD", suggestedName: IssueWorkflow.branchName(task), projectTask: task)
    }
    var currentBranchIssue: ProjectTaskReference? {
        guard let path = url?.path, let branch = headBranch, let target,
              let task = ProjectTaskLinks.task(repositoryPath: path, branch: branch, repository: target.path, host: target.host), let number = task.number else { return nil }
        return IssueWorkflow.task(target: target, number: number, title: task.title, url: task.url)
    }
    func requestIssuePullRequest(_ item: CollaborationInboxItem) {
        guard let task = issueTask(item), let branch = headBranch, busy == nil else { return }
        if let existing = pullRequests.first(where: { $0.source == branch }) { navigate(.pullRequests); select(.pullRequest(existing.number)); return }
        newPullRequestDraft = NewPullRequestDraft(branch: branch, title: task.title, body: IssueWorkflow.requestBody(task), base: "", draft: true, issue: task)
        sheet = .createPullRequest
    }

    func changeIssueComment(_ item: CollaborationInboxItem, comment: CollaborationInboxComment, body: String?) async -> Bool {
        guard !collaboration.inboxBusy, !collaboration.inboxLoading, collaboration.inboxDetail?.item.id == item.id,
              collaboration.inboxDetail?.comments.contains(where: { $0.id == comment.id && $0.body == comment.body && $0.editable }) == true, let access = issueAccess else { return false }
        let key = issueContextKey
        let current = { self.issueContextKey == key && self.collaboration.inboxDetail?.item.id == item.id && access.isCurrent?() != false }
        collaboration.inboxBusy = true; collaboration.inboxError = nil
        defer { if issueContextKey == key { collaboration.inboxBusy = false } }
        do {
            try await CollaborationAPI.changeIssueComment(access, item: item, comment: comment, body: body)
            guard current() else { return false }
            await openInboxItem(item); return current()
        } catch { if current() { collaboration.inboxError = describe(error) }; return false }
    }
    func confirmDeleteIssueComment(_ item: CollaborationInboxItem, comment: CollaborationInboxComment) {
        let key = issueContextKey
        confirm = ConfirmRequest(title: String(localized: "Delete comment?"), message: String(localized: "This permanently deletes your comment."), actionTitle: String(localized: "Delete"), destructive: true) {
            if self.issueContextKey == key { _ = await self.changeIssueComment(item, comment: comment, body: nil) }
        }
    }

}
