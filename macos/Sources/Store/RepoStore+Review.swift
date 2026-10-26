import Foundation

extension RepoStore {
    private var reviewAccess: ReviewAccess? {
        guard let t = target, let a = hostingAccount, let token = AccountStore.shared.token(for: a) else { return nil }
        return ReviewAccess(target: t, token: token, apiBase: a.apiBase, me: a.username)
    }
    private func reviewSelected(_ number: Int, key: String, url: URL?) -> Bool {
        guard self.url == url, let target, ReviewAPI.repositoryKey(target) == key else { return false }
        return selection == .pullRequest(number)
    }

    func loadReview(_ number: Int) async {
        let loadID = UUID(), repoURL = url
        reviewLoadID = loadID
        guard let c = reviewAccess else { reviewError = String(localized: "Connect an account to see the conversation and approvals."); return }
        let key = ReviewAPI.repositoryKey(c.target)
        guard reviewSelected(number, key: key, url: repoURL) else { return }
        reviewDrafts = ReviewDraftStorage.load()
        if review?.number != number || review?.repositoryKey != key { review = nil }
        reviewLoading = true
        reviewError = nil
        defer { if reviewLoadID == loadID { reviewLoading = false } }
        do {
            let r = try await ReviewAPI.load(c.target, token: c.token, apiBase: c.apiBase, number: number, me: c.me)
            guard reviewLoadID == loadID, reviewSelected(number, key: key, url: repoURL) else { return }
            review = r
        } catch {
            guard reviewLoadID == loadID, reviewSelected(number, key: key, url: repoURL) else { return }
            reviewError = describe(error)
        }
    }

    func reviewDraftsFor(_ number: Int) -> [ReviewDraftComment] {
        guard let target else { return [] }
        let key = ReviewAPI.repositoryKey(target)
        return reviewDrafts.filter { $0.repositoryKey == key && $0.number == number }
    }

    func addReviewDraft(_ number: Int, path: String, line: Int, side: ReviewLineSide, oldLine: Int? = nil) {
        guard let r = review, r.number == number, !reviewBusy, reviewSelected(number, key: r.repositoryKey, url: url),
              let file = r.files.first(where: { $0.path == path }), let patch = file.patch,
              case .review(let displayedNumber, let change, let displayedPatch)? = diffSource,
              displayedNumber == number, change.path == path, displayedPatch == patch else { return }
        guard let row = Parsers.diff(patch).lines.first(where: { [.added, .removed, .context].contains($0.kind) && (side == .left ? $0.oldNo : $0.newNo) == line }),
              side != .right || row.kind != .context || oldLine == row.oldNo else { return }
        guard !reviewDraftsFor(number).contains(where: { $0.anchor.headSHA == r.headSHA && $0.anchor.path == path && $0.anchor.side == side && $0.anchor.line == line }) else { return }
        let anchor = ReviewLineAnchor(path: path, oldPath: file.oldPath, line: line, side: side, oldLine: row.kind == .context ? row.oldNo : nil, newLine: row.kind == .context ? row.newNo : nil,
                                      headSHA: r.headSHA, baseSHA: r.baseSHA, startSHA: r.startSHA)
        reviewDrafts.append(ReviewDraftComment(repositoryKey: r.repositoryKey, number: number, anchor: anchor, body: ""))
        if let added = reviewDrafts.last { ReviewDraftStorage.upsert(added) }
    }

    func updateReviewDraft(_ id: String, body: String) {
        guard !reviewBusy, let index = reviewDrafts.firstIndex(where: { $0.id == id }) else { return }
        reviewDrafts[index].body = body
        ReviewDraftStorage.upsert(reviewDrafts[index])
    }
    func removeReviewDraft(_ id: String) {
        guard !reviewBusy else { return }
        reviewDrafts.removeAll { $0.id == id }
        ReviewDraftStorage.remove(id)
    }

    private func reviewAction(_ number: Int, _ work: (ReviewAccess) async throws -> Void) async -> Bool {
        guard let c = reviewAccess, !reviewBusy else { return false }
        let repoURL = url, key = ReviewAPI.repositoryKey(c.target)
        guard reviewSelected(number, key: key, url: repoURL) else { return false }
        let actionID = UUID()
        reviewActionID = actionID
        reviewBusy = true
        defer { if reviewActionID == actionID { reviewBusy = false; reviewActionID = nil } }
        do { try await work(c) }
        catch {
            guard reviewActionID == actionID, reviewSelected(number, key: key, url: repoURL) else { return false }
            var msg = describe(error)
            if let h = error as? HostingError, h.status == 403 || h.status == 404 || h.status == 422 {
                msg += c.target.provider == .gitlab
                    ? String(localized: "\n\nThe token needs the api scope, and only people who can approve this MR can approve it.")
                    : String(localized: "\n\nThe token needs write access to pull requests (classic token: repo). You can't approve your own PR.")
            }
            errorMessage = msg
            return false
        }
        guard reviewActionID == actionID, reviewSelected(number, key: key, url: repoURL) else { return false }
        await loadReview(number)
        return reviewActionID == actionID && reviewSelected(number, key: key, url: repoURL)
    }

    func submitReview(_ number: Int, body: String, verdict: ReviewVerdict = .comment) async -> Bool {
        guard let r = review, r.number == number, let target, r.repositoryKey == ReviewAPI.repositoryKey(target) else { return false }
        let drafts = reviewDraftsFor(number)
        guard verdict != .comment || !body.trimmed.isEmpty || !drafts.isEmpty else { return false }
        return await reviewAction(number) { c in
            try await ReviewAPI.submit(c.target, token: c.token, apiBase: c.apiBase, number: number, expected: r.refs, drafts: drafts, body: body, verdict: verdict) { id in
                guard let sent = drafts.first(where: { $0.id == id }) else { return }
                if let saved = ReviewDraftStorage.load().first(where: { $0.id == id }), !ReviewAPI.sameDraft(saved, sent) {
                    self.reviewDrafts.removeAll { $0.id == id }; self.reviewDrafts.append(saved); return
                }
                if let current = self.reviewDrafts.first(where: { $0.id == id }), !ReviewAPI.sameDraft(current, sent) { return }
                self.reviewDrafts.removeAll { $0.id == id }
                ReviewDraftStorage.remove(id, expected: sent)
            }
        }
    }
    func postReviewComment(_ number: Int, body: String) async -> Bool { await submitReview(number, body: body) }
    func approvePullRequest(_ number: Int, body: String) async -> Bool { await submitReview(number, body: body, verdict: .approve) }
    func requestChanges(_ number: Int, body: String) async -> Bool { await submitReview(number, body: body, verdict: .requestChanges) }
    func unapprovePullRequest(_ number: Int) async { _ = await reviewAction(number) { c in try await ReviewAPI.unapprove(c.target, token: c.token, apiBase: c.apiBase, number: number) } }
    func replyReviewComment(_ number: Int, comment: ReviewComment, body: String) async -> Bool {
        guard !body.trimmed.isEmpty, comment.threadID != nil else { return false }
        return await reviewAction(number) { c in try await ReviewAPI.reply(c.target, token: c.token, apiBase: c.apiBase, number: number, comment: comment, body: body.trimmed) }
    }
    func resolveReviewThread(_ number: Int, comment: ReviewComment) async {
        guard let threadID = comment.threadID, comment.resolvable else { return }
        _ = await reviewAction(number) { c in try await ReviewAPI.resolve(c.target, token: c.token, apiBase: c.apiBase, number: number, threadID: threadID, resolved: !comment.resolved) }
    }
    func openReviewFile(_ number: Int, _ f: ReviewFile) { openDiff(.review(number: number, change: f.change, patch: f.patch ?? "")) }
}
