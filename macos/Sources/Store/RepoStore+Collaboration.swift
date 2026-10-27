import Foundation

extension RepoStore {
    var collaborationAccess: ReviewAccess? {
        guard let target, let a = hostingAccount, let token = AccountStore.shared.token(for: a) else { return nil }
        return ReviewAccess(target: target, token: token, apiBase: a.apiBase, me: a.username)
    }
    /// Waits while the keychain asks the user, so a slow approval is not reported as a missing account.
    func resolveCollaborationAccess() async -> ReviewAccess? {
        guard let target, let a = hostingAccount, let token = await AccountStore.shared.loadToken(for: a) else { return nil }
        return ReviewAccess(target: target, token: token, apiBase: a.apiBase, me: a.username)
    }
    /// Why the inbox has no access: the saved account needs the user's approval, or no account is connected.
    private var inboxAccessMessage: String {
        pendingCredentialAccount == nil ? String(localized: "Connect an account to load your inbox.") : String(localized: "Allow access to the saved account to use repository services.")
    }
    func filterPullRequests(scope: String, search: String) async {
        collaboration.query = RequestQuery(scope: scope, search: search, page: 1)
        await loadPullRequests()
    }
    func loadRequestLifecycle(_ number: Int) async {
        let state = collaboration, context = collaboration.contextID, loadID = UUID(), repoURL = url
        state.lifecycleID = loadID
        let current = { self.url == repoURL && state.contextID == context && state.lifecycleID == loadID && self.selection == .pullRequest(number) }
        guard let c = collaborationAccess, current() else { return }
        if state.lifecycle?.number != number { state.lifecycle = nil }
        state.lifecycleLoading = true; state.lifecycleError = nil
        defer { if current() { state.lifecycleLoading = false } }
        do { let result = try await CollaborationAPI.lifecycle(c, number); if current() { state.lifecycle = result } }
        catch { if current() { state.lifecycleError = describe(error) } }
    }
    @discardableResult
    func lifecycleAction(_ number: Int, action: (ReviewAccess) async throws -> Void) async -> Bool {
        let state = collaboration, context = collaboration.contextID, repoURL = url
        guard !state.lifecycleBusy, var c = collaborationAccess else { return false }
        let originalTarget = c.target
        let current = { self.url == repoURL && self.target == originalTarget && state.contextID == context }
        c.isCurrent = current
        state.lifecycleBusy = true; state.lifecycleError = nil
        defer { if current() { state.lifecycleBusy = false } }
        do { try await action(c); guard current() else { return false }; await loadRequestLifecycle(number); return true }
        catch { if current() { state.lifecycleError = describe(error) }; return false }
    }
    func confirmMergeRequest(method: String) {
        guard let expected = collaboration.lifecycle, expected.blockers.isEmpty, expected.methods.contains(method), !collaboration.lifecycleBusy else { return }
        let context = collaboration.contextID
        confirm = ConfirmRequest(title: String(localized: "Merge request #\(expected.number)?"), message: String(localized: "Method: \(method)\nCommit: \(expected.headSHA)\nThe server will recheck branch rules before merging."), actionTitle: String(localized: "Merge")) { [weak self] in
            guard let self, self.collaboration.contextID == context else { return }
            await self.lifecycleAction(expected.number) { c in try await CollaborationAPI.merge(c, expected: expected, method: method) }
        }
    }
    func confirmRequestState(open: Bool) {
        guard let r = collaboration.lifecycle, r.state != "merged" else { return }
        let context = collaboration.contextID
        confirm = ConfirmRequest(title: open ? String(localized: "Reopen request #\(r.number)?") : String(localized: "Close request #\(r.number)?"), message: r.title, actionTitle: open ? String(localized: "Reopen") : String(localized: "Close request")) { [weak self] in
            guard let self, self.collaboration.contextID == context else { return }
            await self.lifecycleAction(r.number) { c in try await CollaborationAPI.setState(c, r.number, open: open) }
        }
    }
    func confirmRequestRebase() {
        guard let r = collaboration.lifecycle, r.canRebase else { return }
        let context = collaboration.contextID
        confirm = ConfirmRequest(title: String(localized: "Rebase request #\(r.number)?"), message: String(localized: "GitLab rebases the source branch on the server. Refresh when the rebase finishes and review the new commit before merging."), actionTitle: String(localized: "Rebase")) { [weak self] in
            guard let self, self.collaboration.contextID == context else { return }
            await self.lifecycleAction(r.number) { c in
                let fresh = try await CollaborationAPI.lifecycle(c, r.number)
                guard fresh.canRebase, fresh.headSHA == r.headSHA else { throw CollaborationAPI.fail(String(localized: "The request changed. Refresh and review the latest commit before merging.")) }
                _ = try await CollaborationAPI.value(c, CollaborationAPI.requestURL(c, r.number) + "/rebase", method: "PUT", body: ["skip_ci": false])
            }
        }
    }
    func saveRequestMetadata(_ number: Int, title: String, body: String, base: String) async -> Bool {
        guard !title.trimmed.isEmpty, !base.trimmed.isEmpty else { return false }
        let context = collaboration.contextID, repoURL = url
        let result = await lifecycleAction(number) { c in try await CollaborationAPI.update(c, number, title: title.trimmed, body: body, base: base.trimmed) }
        if result, collaboration.contextID == context, url == repoURL, let c = collaborationAccess, let p = try? await CollaborationAPI.object(c, CollaborationAPI.requestURL(c, number)), let updated = try? CollaborationAPI.pull(c, p) {
            guard collaboration.contextID == context, url == repoURL else { return false }
            pullRequests = pullRequests.map { $0.number == number ? updated : $0 }
        }
        return result
    }
    func saveRequestReviewers(_ number: Int, names: [String]) async -> Bool {
        guard let r = collaboration.lifecycle, r.number == number else { return false }
        return await lifecycleAction(number) { c in try await CollaborationAPI.reviewers(c, number, names: names, previous: r.reviewers) }
    }
    func loadInbox(kind: String? = nil, append: Bool = false) async {
        let state = collaboration, context = collaboration.contextID, loadID = UUID(), repoURL = url
        state.inboxID = loadID
        let kind = kind ?? state.inboxKind, page = append && kind == state.inboxKind ? state.inboxPage + 1 : 1
        let current = { self.url == repoURL && state.contextID == context && state.inboxID == loadID }
        state.inboxKind = kind; state.inboxLoading = true; state.inboxError = nil
        if !append { state.inbox = []; state.inboxDetail = nil; state.detailID = UUID() }
        defer { if current() { state.inboxLoading = false } }
        let access = await resolveCollaborationAccess()
        guard current() else { return }
        guard let c = access else { state.inboxError = inboxAccessMessage; return }
        do {
            let (items, more) = try await CollaborationAPI.inbox(c, kind: kind, page: page)
            guard current() else { return }
            state.inbox = append ? state.inbox + items.filter { item in !state.inbox.contains(where: { $0.id == item.id }) } : items
            state.inboxPage = page; state.inboxMore = more
        } catch { if current() { state.inboxError = describe(error) } }
    }
    func openInboxItem(_ item: CollaborationInboxItem, append: Bool = false) async {
        let state = collaboration, context = collaboration.contextID, loadID = UUID(), repoURL = url
        state.detailID = loadID
        let current = { self.url == repoURL && state.contextID == context && state.detailID == loadID }
        let previous = append && state.inboxDetail?.item.id == item.id ? state.inboxDetail : nil
        state.inboxDetail = previous ?? CollaborationInboxDetail(item: item, comments: [], page: 0)
        state.inboxLoading = true; state.inboxError = nil
        defer { if current() { state.inboxLoading = false } }
        let access = await resolveCollaborationAccess()
        guard current() else { return }
        guard let c = access else { state.inboxError = inboxAccessMessage; return }
        do {
            var detail = try await CollaborationAPI.detail(c, item: item, page: (previous?.page ?? 0) + 1)
            guard current() else { return }
            if let previous { detail.comments = previous.comments + detail.comments.filter { next in !previous.comments.contains(where: { $0.id == next.id }) } }
            state.inboxDetail = detail
        } catch { if current() { state.inboxError = describe(error) } }
    }
    func inboxAction(_ item: CollaborationInboxItem, action: String, body: String = "") async -> Bool {
        let state = collaboration, context = collaboration.contextID, repoURL = url
        let current = { self.url == repoURL && state.contextID == context }
        guard !state.inboxBusy, var c = collaborationAccess else { return false }
        c.isCurrent = current
        state.inboxBusy = true; state.inboxError = nil
        defer { if current() { state.inboxBusy = false } }
        do {
            try await CollaborationAPI.inboxAction(c, item: item, action: action, body: body)
            guard current() else { return false }
            if action == "read" {
                if let index = state.inbox.firstIndex(where: { $0.id == item.id }) { state.inbox[index].unread = false }
                if state.inboxDetail?.item.id == item.id { state.inboxDetail?.item.unread = false }
            } else if state.inboxDetail?.item.id == item.id { await openInboxItem(item) }
            return current()
        } catch { if current() { state.inboxError = describe(error) }; return false }
    }
    func confirmIssueState(_ item: CollaborationInboxItem) {
        let context = collaboration.contextID, open = ["open", "opened"].contains(item.state)
        confirm = ConfirmRequest(title: String(localized: "Change issue state?"), message: item.title, actionTitle: open ? String(localized: "Close issue") : String(localized: "Reopen")) { [weak self] in
            guard let self, self.collaboration.contextID == context else { return }
            _ = await self.inboxAction(item, action: open ? "close" : "reopen")
        }
    }
}
