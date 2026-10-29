import { accountApiBase, branchRemote, branchShort, displayPushURL, type HostAccount, parseDiff, providerInfo, type PullRequest, sameTarget } from "@/entities/git";
import * as Hosting from "@/entities/hosting";
import { accounts, type ReviewAccess, ReviewAPI, type ReviewComment, type ReviewDraftComment, type ReviewFile, type ReviewLineSide, type ReviewVerdict, reviewFileChange, reviewRepositoryKey, reviewDraftMatches } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { describe, git } from "@/shared/platform";
import { RepoWorktrees } from "./worktrees";

/** GitHub·GitLab: PR·MR 목록·만들기·체크아웃 */
export abstract class RepoHosting extends RepoWorktrees {
  /** 이 저장소의 PR·MR 에 쓰는 계정(같은 서버에 여럿이면 저장소마다 고른 것) */
  get hostingAccount(): HostAccount | null {
    return this.target ? accounts.accountFor(this.target, this.path) : null;
  }

  /** 사용자가 눌렀을 때: 이미 연결한 계정이 이 저장소 서버에도 통하는지 직접 확인 */
  async tryExistingAccounts() {
    const target = this.target;
    if (!target) return;
    if (!(await accounts.discoverAlias(target, false))) {
      this.errorMessage = t("The connected {0} account can't access {1}. Add an account with a token for this server.", providerInfo[target.provider].title, target.host);
      this.emit();
    } else await this.loadPullRequests();
  }

  useAccount(a: HostAccount) {
    if (this.path) accounts.setPreferred(a, this.path);
    void this.refreshHostingAccount();
  }

  private hostingAccountContext = "";

  /** 계정 연결·갱신 뒤 SSH 별칭도 다시 해석하고 이전 계정의 요청·CI 상태를 버린다. */
  async refreshHostingAccount() {
    const context = JSON.stringify([this.path, accounts.revision, this.remotes, this.remoteURLs]);
    if (context === this.hostingAccountContext) return;
    this.hostingAccountContext = context;
    this.target = Hosting.findTarget(this.remotes, this.remoteURLs, accounts.accountsFor("gitlab").map((account) => new URL(account.server).host.toLowerCase()), accounts.sshHostAliases);
    this.reviewContextGeneration++; this.requestListToken++; this.lifecycleLoadToken++; this.inboxLoadToken++; this.inboxDetailToken++;
    this.requestLifecycle = null; this.lifecycleBusy = false; this.lifecycleLoading = false; this.lifecycleError = null;
    this.inboxItems = []; this.inboxDetail = null; this.inboxLoading = false; this.inboxBusy = false;
    this.review = null; this.reviewLoadGeneration++; this.reviewActionToken = null; this.reviewBusy = false;
    this.pullRequests = []; this.prState = { kind: "idle" }; this.ci.reset(); this.emit();
    await this.loadPullRequests();
    if (context === this.hostingAccountContext) await this.ci.refreshBadges();
  }

  requestQuery: Hosting.RequestQuery = { scope: "open", search: "", page: 1 };
  requestsMore = false;
  requestsWarning: string | null = null;
  requestLifecycle: Hosting.RequestLifecycle | null = null;
  lifecycleLoading = false;
  lifecycleBusy = false;
  lifecycleError: string | null = null;
  inboxKind: Hosting.InboxItem["kind"] = "issue";
  inboxItems: Hosting.InboxItem[] = [];
  inboxPageNumber = 1;
  inboxMore = false;
  inboxLoading = false;
  inboxBusy = false;
  inboxError: string | null = null;
  inboxDetail: Hosting.InboxDetail | null = null;
  private requestListToken = 0;
  private lifecycleLoadToken = 0;
  private inboxLoadToken = 0;
  private inboxDetailToken = 0;

  async loadPullRequests(append = false) {
    const target = this.target, path = this.path, generation = this.reviewContextGeneration, tokenID = ++this.requestListToken;
    const query = { ...this.requestQuery, page: append ? this.requestQuery.page + 1 : 1 };
    const current = () => generation === this.reviewContextGeneration && tokenID === this.requestListToken && this.path === path && sameTarget(this.target, target);
    if (!target) { this.pullRequests = []; this.prState = { kind: "idle" }; this.emit(); return; }
    if (!this.hostingAccount && accounts.accountsFor(target.provider).length) await accounts.discoverAlias(target, true);
    if (!current()) return;
    const acct = this.hostingAccount, token = acct ? await accounts.token(acct) : null;
    if (!current()) return;
    if (!acct || !token) {
      if (target.provider === "gitlab") accounts.suggestedGitLabServer = `https://${target.host}`;
      this.pullRequests = []; this.prState = { kind: "needsAccount" }; this.emit(); return;
    }
    this.prState = { kind: "loading" }; this.emit();
    try {
      const result = await Hosting.requestPage({ target, token, apiBase: accountApiBase(acct), me: acct.username, stillCurrent: current }, query);
      if (!current()) return;
      this.pullRequests = append ? [...this.pullRequests, ...result.items.filter((p) => !this.pullRequests.some((old) => old.number === p.number))] : result.items;
      this.requestQuery = query; this.requestsMore = result.more; this.requestsWarning = result.warning ?? null; this.prState = { kind: "loaded" };
    } catch (e) { if (current()) this.prState = { kind: "failed", message: describe(e) }; }
    if (current()) this.emit();
  }

  async filterPullRequests(scope: Hosting.RequestScope, search: string) {
    this.requestQuery = { scope, search, page: 1 }; await this.loadPullRequests();
  }

  async loadRequestLifecycle(number: number) {
    const generation = this.reviewContextGeneration, token = ++this.lifecycleLoadToken, path = this.path;
    const current = () => generation === this.reviewContextGeneration && token === this.lifecycleLoadToken && path === this.path && this.selection?.kind === "pullRequest" && this.selection.number === number;
    const c = await this.reviewAccess(); if (!c || !current()) return;
    if (this.requestLifecycle?.number !== number) this.requestLifecycle = null;
    this.lifecycleLoading = true; this.lifecycleError = null; this.emit();
    try { const result = await Hosting.requestLifecycle(c, number); if (current()) this.requestLifecycle = result; }
    catch (e) { if (current()) this.lifecycleError = describe(e); }
    finally { if (current()) { this.lifecycleLoading = false; this.emit(); } }
  }

  private async lifecycleAction(number: number, action: (c: ReviewAccess) => Promise<unknown>): Promise<boolean> {
    if (this.lifecycleBusy) return false;
    const generation = this.reviewContextGeneration, path = this.path, target = this.target;
    const current = () => generation === this.reviewContextGeneration && path === this.path && sameTarget(target, this.target);
    const c = await this.reviewAccess(); if (!c || !current()) return false;
    this.lifecycleBusy = true; this.lifecycleError = null; this.emit();
    try { await action({ ...c, stillCurrent: current }); if (!current()) return false; await this.loadRequestLifecycle(number); return true; }
    catch (e) { if (current()) this.lifecycleError = describe(e); return false; }
    finally { if (current()) { this.lifecycleBusy = false; this.emit(); } }
  }
  confirmMergeRequest(method: Hosting.MergeMethod) {
    const expected = this.requestLifecycle, generation = this.reviewContextGeneration;
    if (!expected || expected.blockers.length || !expected.methods.includes(method) || this.lifecycleBusy) return;
    this.confirm = { title: t("Merge request #{0}?", expected.number), message: t("Method: {0}\nCommit: {1}\nThe server will recheck branch rules before merging.", method, expected.headSHA), actionTitle: t("Merge"), action: async () => {
      if (generation === this.reviewContextGeneration) await this.lifecycleAction(expected.number, (c) => Hosting.mergeRequest(c, expected, method));
    } }; this.emit();
  }
  confirmRequestState(open: boolean) {
    const r = this.requestLifecycle, generation = this.reviewContextGeneration; if (!r || r.state === "merged") return;
    this.confirm = { title: open ? t("Reopen request #{0}?", r.number) : t("Close request #{0}?", r.number), message: r.title, actionTitle: open ? t("Reopen") : t("Close request"), action: async () => {
      if (generation === this.reviewContextGeneration) await this.lifecycleAction(r.number, (c) => Hosting.setRequestState(c, r.number, open));
    } }; this.emit();
  }
  confirmRequestRebase() {
    const r = this.requestLifecycle, generation = this.reviewContextGeneration; if (!r?.canRebase) return;
    this.confirm = { title: t("Rebase request #{0}?", r.number), message: t("GitLab rebases the source branch on the server. Refresh when the rebase finishes and review the new commit before merging."), actionTitle: t("Rebase"), action: async () => {
      if (generation === this.reviewContextGeneration) await this.lifecycleAction(r.number, async (c) => {
        const fresh = await Hosting.requestLifecycle(c, r.number);
        if (!fresh.canRebase || fresh.headSHA !== r.headSHA) throw new Error(t("The request changed. Refresh and review the latest commit before merging."));
        await Hosting.rebaseRequest(c, r.number);
      });
    } }; this.emit();
  }
  async saveRequestMetadata(number: number, title: string, body: string, base: string) {
    if (!title.trim() || !base.trim()) return false;
    const ok = await this.lifecycleAction(number, (c) => Hosting.updateRequest(c, number, title.trim(), body, base.trim()));
    if (ok) { this.pullRequests = this.pullRequests.map((p) => p.number === number ? { ...p, title, body, target: base } : p); this.emit(); } return ok;
  }
  async saveRequestReviewers(number: number, names: string[]) {
    const r = this.requestLifecycle; if (!r || r.number !== number) return false;
    return this.lifecycleAction(number, (c) => Hosting.setReviewers(c, number, names, r.reviewers));
  }

  async loadInbox(kind: Hosting.InboxItem["kind"] = this.inboxKind, append = false) {
    const generation = this.reviewContextGeneration, token = ++this.inboxLoadToken, path = this.path;
    const page = append && kind === this.inboxKind ? this.inboxPageNumber + 1 : 1;
    const current = () => generation === this.reviewContextGeneration && token === this.inboxLoadToken && path === this.path;
    this.inboxKind = kind; this.inboxLoading = true; this.inboxError = null;
    if (!append) { this.inboxItems = []; this.inboxDetail = null; this.inboxDetailToken++; } this.emit();
    try {
      const c = await this.reviewAccess(); if (!current()) return;
      if (!c) throw new Error(t("Connect an account to load your inbox."));
      const result = await Hosting.inboxPage(c, kind, page); if (!current()) return;
      this.inboxItems = append ? [...this.inboxItems, ...result.items.filter((i) => !this.inboxItems.some((old) => old.id === i.id))] : result.items;
      this.inboxPageNumber = page; this.inboxMore = result.more;
    } catch (e) { if (current()) this.inboxError = describe(e); }
    finally { if (current()) { this.inboxLoading = false; this.emit(); } }
  }
  async openInboxItem(item: Hosting.InboxItem, append = false) {
    const generation = this.reviewContextGeneration, token = ++this.inboxDetailToken, path = this.path;
    const current = () => generation === this.reviewContextGeneration && token === this.inboxDetailToken && path === this.path;
    const previous = append && this.inboxDetail?.item.id === item.id ? this.inboxDetail : null;
    this.inboxDetail = previous ?? { item, comments: [], more: false, page: 0 }; this.inboxLoading = true; this.inboxError = null; this.emit();
    try {
      const c = await this.reviewAccess(); if (!current()) return;
      if (!c) throw new Error(t("Connect an account to load your inbox."));
      const detail = await Hosting.inboxDetail(c, item, (previous?.page ?? 0) + 1); if (!current()) return;
      this.inboxDetail = previous ? { ...detail, comments: [...previous.comments, ...detail.comments.filter((i) => !previous.comments.some((old) => old.id === i.id))] } : detail;
    } catch (e) { if (current()) this.inboxError = describe(e); }
    finally { if (current()) { this.inboxLoading = false; this.emit(); } }
  }
  confirmInboxState(item: Hosting.InboxItem) {
    const generation = this.reviewContextGeneration, open = ["open", "opened"].includes(item.state);
    this.confirm = { title: t("Change issue state?"), message: item.title, actionTitle: open ? t("Close issue") : t("Reopen"), action: async () => {
      if (generation === this.reviewContextGeneration) await this.inboxAction(item, open ? "close" : "reopen");
    } }; this.emit();
  }
  async inboxAction(item: Hosting.InboxItem, kind: "comment" | "close" | "reopen" | "read", body = "") {
    if (this.inboxBusy) return false;
    const generation = this.reviewContextGeneration, path = this.path;
    const current = () => generation === this.reviewContextGeneration && path === this.path;
    this.inboxBusy = true; this.inboxError = null; this.emit();
    try {
      const c = await this.reviewAccess(); if (!c || !current()) return false;
      if (kind === "comment") await Hosting.postInboxComment({ ...c, stillCurrent: () => current() && c.stillCurrent?.() !== false }, item, body);
      else if (kind === "read") await Hosting.markInboxRead({ ...c, stillCurrent: current }, item);
      else { if (item.kind !== "issue") return false; await Hosting.setIssueState({ ...c, stillCurrent: current }, item, kind === "reopen"); }
      if (!current()) return false;
      if (kind === "read") { this.inboxItems = this.inboxItems.map((i) => i.id === item.id ? { ...i, unread: false } : i); if (this.inboxDetail?.item.id === item.id) this.inboxDetail.item.unread = false; }
      else if (this.inboxDetail?.item.id === item.id) await this.openInboxItem(item);
      return current();
    } catch (e) { if (current()) this.inboxError = describe(e); return false; }
    finally { if (current()) { this.inboxBusy = false; this.emit(); } }
  }

  /** PR 브랜치 체크아웃: 같은 저장소 브랜치면 추적 브랜치로, 포크면 pr/번호 로컬 브랜치로 가져온다 */
  async checkoutPullRequest(pr: PullRequest) {
    const target = this.target;
    if (!target) return;
    const remoteName = `${target.remote}/${pr.source}`;
    if (!pr.fromFork) {
      if (!this.remoteBranches.some((b) => b.name === remoteName)) {
        if (!(await this.run(t("Fetching…"), ["fetch", target.remote, pr.source], { network: true }))) return;
      }
      const b = this.remoteBranches.find((x) => x.name === remoteName);
      if (b) {
        await this.checkout(b);
        return;
      }
    }
    const ref = target.provider === "github" ? `refs/pull/${pr.number}/head` : `refs/merge-requests/${pr.number}/head`;
    const local = `${providerInfo[target.provider].requestShort.toLowerCase()}/${pr.number}`;
    if (this.headBranch === local) await this.run(t("Fetching…"), ["pull", "--ff-only", target.remote, ref], { network: true });
    else if (await this.run(t("Fetching…"), ["fetch", target.remote, `+${ref}:refs/heads/${local}`], { network: true }))
      await this.run(t("Checking out…"), ["switch", local]);
  }

  /** PR 대상 브랜치 후보: 원격 브랜치 이름(원격 접두사 제외) */
  pullRequestBaseCandidates() {
    const target = this.target;
    if (!target) return [];
    return this.remoteBranches.filter((b) => branchRemote(b) === target.remote && branchShort(b) !== this.headBranch).map(branchShort);
  }

  async defaultBaseBranch() {
    const candidates = this.pullRequestBaseCandidates();
    const target = this.target,
      acct = this.hostingAccount;
    if (target && acct) {
      const token = await accounts.token(acct);
      if (token) {
        try {
          const b = await Hosting.defaultBranch(target, token, accountApiBase(acct));
          if (b && candidates.includes(b)) return b;
        } catch {
          /* 아래 */
        }
      }
    }
    return ["main", "master", "develop"].find((b) => candidates.includes(b)) ?? candidates[0] ?? null;
  }

  async createPullRequest(title: string, body: string, base: string, draft: boolean) {
    const target = this.target,
      branch = this.headBranch;
    if (!target || !branch || !this.path || this.busy) return;
    const originalPath = this.path, originalHead = this.headHash, context = this.reviewContextGeneration;
    this.newPullRequestDraft = { branch, title, body, base, draft, issue: this.newPullRequestDraft?.branch === branch ? this.newPullRequestDraft.issue : undefined };
    const acct = this.hostingAccount;
    const token = acct ? await accounts.token(acct) : null;
    const current = () => context === this.reviewContextGeneration && this.path === originalPath && sameTarget(this.target, target);
    if (!current()) return;
    if (!acct || !token) {
      this.errorMessage = t("Connect a {0} ({1}) account first (Settings > Accounts).", providerInfo[target.provider].title, target.host);
      this.emit();
      return;
    }
    if (!(await this.validatePullRequestPushTarget(target, originalPath, acct, context))) return;
    // PR 서버와 다른 pushRemote가 있어도 검토한 PR 원격으로만 게시한다.
    if (!current()) return;
    if (!(await this.requestPushReview(branch, false, target.remote))) return;
    if (!current()) return;
    if (this.headBranch !== branch || this.headHash !== originalHead || this.hostingAccount?.id !== acct.id || this.busy) {
      this.showError(t("The repository or branch changed. Review the pull request again; your draft has been kept."));
      return;
    }
    if (!(await this.validatePullRequestPushTarget(target, originalPath, acct, context)) || !current()) return;
    this.busy = t("Creating {0}…", providerInfo[target.provider].requestShort);
    this.emit();
    try {
      const pr = await Hosting.createPullRequest(target, token, accountApiBase(acct), { title, body, source: branch, target: base, draft });
      if (!current()) return;
      this.newPullRequestDraft = null;
      this.busy = null;
      await this.loadPullRequests();
      if (!current()) return;
      this.select({ kind: "pullRequest", number: pr.number });
      this.openUrl(pr.url);
    } catch (e) {
      if (current()) this.fail(e);
    } finally {
      if (current()) { this.busy = null; this.emit(); }
    }
  }

  /** 같은 remote의 push URL도 다른 저장소를 가리킬 수 있으므로 PR과 같은 대상인지 확인한다. */
  private async validatePullRequestPushTarget(target: NonNullable<RepoHosting["target"]>, repo: string, account: HostAccount, context: number): Promise<boolean> {
    try {
      const urls = (await git(["remote", "get-url", "--push", "--all", target.remote], repo)).stdout.trim().split("\n").filter(Boolean);
      if (this.path !== repo || context !== this.reviewContextGeneration) return false;
      const parsed = urls.length === 1 ? Hosting.parseRemote(urls[0]) : null;
      if (parsed?.path === target.path && (parsed.host === target.host || accounts.accountFor({ ...target, host: parsed.host }, repo)?.id === account.id)) return true;
      this.showError(t("The push URL points to a different repository than this pull request. Check the remote configuration; your draft has been kept."));
    } catch (e) {
      if (this.path === repo && context === this.reviewContextGeneration) this.showError(displayPushURL(describe(e)));
    }
    return false;
  }

  // 리뷰 초안은 로컬에 보관하며 서버 저장소·PR·diff 버전으로 구분한다.
  reviewDrafts: ReviewDraftComment[] = readReviewDrafts();
  private reviewLoadGeneration = 0;
  private reviewContextGeneration = 0;
  get hostingHubRevision() { return this.reviewContextGeneration; }
  private reviewActionToken: symbol | null = null;

  protected override resetState() {
    this.reviewLoadGeneration++;
    this.reviewContextGeneration++;
    this.reviewActionToken = null;
    this.requestListToken++; this.lifecycleLoadToken++; this.inboxLoadToken++; this.inboxDetailToken++;
    this.requestQuery = { scope: "open", search: "", page: 1 }; this.requestsMore = false; this.requestsWarning = null;
    this.requestLifecycle = null; this.lifecycleBusy = false; this.lifecycleLoading = false; this.lifecycleError = null;
    this.inboxItems = []; this.inboxDetail = null; this.inboxMore = false; this.inboxBusy = false; this.inboxLoading = false; this.inboxError = null;
    super.resetState();
  }

  /** Workspace pages use the same epoch as reviews, including reopening the same path. */
  get collaborationRevision() { return this.reviewContextGeneration; }
  async workspaceAccess(): Promise<ReviewAccess | null> {
    const generation=this.reviewContextGeneration, path=this.path, target=this.target, account=this.hostingAccount, revision=accounts.revision;
    const current=()=>generation===this.reviewContextGeneration && this.path===path && this.target?.host===target?.host && this.target?.path===target?.path && accounts.revision===revision && this.hostingAccount?.id===account?.id;
    const token=account ? await accounts.token(account) : null;
    return target && account && token && current() ? {target,token,apiBase:accountApiBase(account),me:account.username,stillCurrent:current} : null;
  }

  protected async reviewAccess(): Promise<ReviewAccess | null> {
    const target = this.target, a = this.hostingAccount;
    const token = a ? await accounts.token(a) : null;
    return target && a && token ? { target, token, apiBase: accountApiBase(a), me: a.username } : null;
  }

  private reviewSelected(n: number, repositoryKey: string, path: string | null) {
    return this.path === path && this.target != null && reviewRepositoryKey(this.target) === repositoryKey && this.selection?.kind === "pullRequest" && this.selection.number === n;
  }

  async loadReview(n: number) {
    const generation = ++this.reviewLoadGeneration, path = this.path;
    const target = this.target;
    if (!target) return;
    const key = reviewRepositoryKey(target);
    const c = await this.reviewAccess();
    if (generation !== this.reviewLoadGeneration || !this.reviewSelected(n, key, path)) return;
    if (!c || reviewRepositoryKey(c.target) !== key) {
      this.reviewError = t("Connect an account to see the conversation and approvals."); this.emit(); return;
    }
    this.reviewDrafts = readReviewDrafts();
    if (this.review?.number !== n || this.review.repositoryKey !== key) this.review = null;
    this.reviewLoading = true; this.reviewError = null; this.emit();
    try {
      const r = await ReviewAPI.load(c, n);
      if (generation === this.reviewLoadGeneration && this.reviewSelected(n, key, path)) this.review = r;
    } catch (e) {
      if (generation === this.reviewLoadGeneration && this.reviewSelected(n, key, path)) this.reviewError = describe(e);
    } finally {
      if (generation === this.reviewLoadGeneration) { this.reviewLoading = false; this.emit(); }
    }
  }

  reviewDraftsFor(n: number) {
    const key = this.target ? reviewRepositoryKey(this.target) : null;
    return this.reviewDrafts.filter((d) => d.repositoryKey === key && d.number === n);
  }

  addReviewDraft(n: number, path: string, line: number, side: ReviewLineSide, oldLine?: number) {
    const r = this.review;
    if (!r || r.number !== n || !this.target || r.repositoryKey !== reviewRepositoryKey(this.target) || !this.reviewSelected(n, r.repositoryKey, this.path) || this.reviewBusy) return;
    const file = r.files.find((f) => f.path === path);
    if (!file?.patch || this.diffSource?.kind !== "review" || this.diffSource.number !== n || this.diffSource.change.path !== path || this.diffSource.patch !== file.patch) return;
    const row = parseDiff(file.patch).lines.find((l) => ["added", "removed", "context"].includes(l.kind) && (side === "LEFT" ? l.oldNo : l.newNo) === line);
    if (!row || (side === "RIGHT" && row.kind === "context" && oldLine !== row.oldNo)) return;
    const duplicate = this.reviewDraftsFor(n).find((d) => d.anchor.headSHA === r.headSHA && d.anchor.path === path && d.anchor.side === side && d.anchor.line === line);
    if (duplicate) return;
    this.reviewDrafts = [...this.reviewDrafts, { id: crypto.randomUUID(), repositoryKey: r.repositoryKey, number: n, anchor: { path, oldPath: file.oldPath, line, side, oldLine: row.kind === "context" ? row.oldNo ?? undefined : undefined, newLine: row.kind === "context" ? row.newNo ?? undefined : undefined, headSHA: r.headSHA, baseSHA: r.baseSHA, startSHA: r.startSHA }, body: "" }];
    this.persistReviewDrafts([this.reviewDrafts[this.reviewDrafts.length - 1].id]); this.emit();
  }

  updateReviewDraft(id: string, body: string) {
    if (this.reviewBusy) return;
    this.reviewDrafts = this.reviewDrafts.map((d) => d.id === id ? { ...d, body } : d);
    this.persistReviewDrafts([id]); this.emit();
  }

  removeReviewDraft(id: string) {
    if (this.reviewBusy) return;
    this.reviewDrafts = this.reviewDrafts.filter((d) => d.id !== id);
    this.persistReviewDrafts([], [id]); this.emit();
  }

  private persistReviewDrafts(changedIDs: string[], removedIDs: string[] = []) {
    try {
      // Merge individual edits, so another open repository cannot overwrite these drafts.
      localStorage.getItem("gitrochi.reviewDrafts.v1");
      const changed = new Set(changedIDs), removed = new Set(removedIDs);
      const saved = readReviewDrafts().filter((d) => !changed.has(d.id) && !removed.has(d.id));
      const merged = [...saved, ...this.reviewDrafts.filter((d) => changed.has(d.id))];
      localStorage.setItem("gitrochi.reviewDrafts.v1", JSON.stringify(merged));
    } catch { /* Keep drafts in memory if local storage is unavailable. */ }
  }

  private async reviewAction(n: number, work: (c: ReviewAccess) => Promise<unknown>): Promise<boolean> {
    const path = this.path, target = this.target, context = this.reviewContextGeneration;
    if (!target || this.reviewBusy) return false;
    const key = reviewRepositoryKey(target);
    const c = await this.reviewAccess();
    if (!c || reviewRepositoryKey(c.target) !== key || context !== this.reviewContextGeneration || !this.reviewSelected(n, key, path) || this.reviewBusy) return false;
    const action = Symbol("review");
    this.reviewActionToken = action;
    this.reviewBusy = true; this.emit();
    try {
      await work(c);
      if (this.reviewActionToken !== action || context !== this.reviewContextGeneration || !this.reviewSelected(n, key, path)) return false;
      await this.loadReview(n);
      return this.reviewActionToken === action && context === this.reviewContextGeneration && this.reviewSelected(n, key, path);
    } catch (e) {
      if (this.reviewActionToken !== action || context !== this.reviewContextGeneration || !this.reviewSelected(n, key, path)) return false;
      let msg = describe(e);
      if (e instanceof Hosting.HostingError && [403, 404, 422].includes(e.status)) msg += c.target.provider === "gitlab"
        ? t("\n\nThe token needs the api scope, and only people who can approve this MR can approve it.")
        : t("\n\nThe token needs write access to pull requests (classic token: repo). You can't approve your own PR.");
      this.showError(msg); return false;
    } finally {
      if (this.reviewActionToken === action && context === this.reviewContextGeneration) {
        this.reviewActionToken = null; this.reviewBusy = false; this.emit();
      }
    }
  }

  submitReview(n: number, body: string, verdict: ReviewVerdict = "COMMENT") {
    const r = this.review, drafts = this.reviewDraftsFor(n);
    if (!r || r.number !== n || !this.target || r.repositoryKey !== reviewRepositoryKey(this.target)) return Promise.resolve(false);
    if (verdict === "COMMENT" && !body.trim() && !drafts.length) return Promise.resolve(false);
    return this.reviewAction(n, async (c) => {
      await ReviewAPI.submit(c, n, r, drafts, body, verdict, (id) => {
        const sent = drafts.find((d) => d.id === id);
        if (!sent) return;
        // A reset can make the draft editable while the original response is still in flight.
        const saved = readReviewDrafts().find((d) => d.id === id);
        const current = this.reviewDrafts.find((d) => d.id === id);
        if (saved && !reviewDraftMatches(saved, sent)) {
          this.reviewDrafts = [...this.reviewDrafts.filter((d) => d.id !== id), saved]; this.emit(); return;
        }
        if (current && !reviewDraftMatches(current, sent)) return;
        this.reviewDrafts = this.reviewDrafts.filter((d) => d.id !== id); this.persistReviewDrafts([], [id]); this.emit();
      });
    });
  }

  postReviewComment(n: number, body: string) { return this.submitReview(n, body); }
  approvePullRequest(n: number, body: string) { return this.submitReview(n, body, "APPROVE"); }
  requestChanges(n: number, body: string) { return this.submitReview(n, body, "REQUEST_CHANGES"); }
  unapprovePullRequest(n: number) { return this.reviewAction(n, (c) => ReviewAPI.unapprove(c, n)); }
  replyReviewComment(n: number, comment: ReviewComment, body: string) {
    if (!body.trim() || !comment.threadID) return Promise.resolve(false);
    return this.reviewAction(n, (c) => ReviewAPI.reply(c, n, comment, body.trim()));
  }
  resolveReviewThread(n: number, comment: ReviewComment) {
    if (!comment.threadID || !comment.resolvable) return Promise.resolve(false);
    return this.reviewAction(n, (c) => ReviewAPI.resolve(c, n, comment.threadID!, !comment.resolved));
  }
  openReviewFile(n: number, f: ReviewFile) { this.openDiff({ kind: "review", number: n, change: reviewFileChange(f), patch: f.patch ?? "" }); }
}

function readReviewDrafts(): ReviewDraftComment[] {
  try {
    const value: unknown = JSON.parse(localStorage.getItem("gitrochi.reviewDrafts.v1") ?? "[]");
    if (!Array.isArray(value)) return [];
    return value.filter((d): d is ReviewDraftComment => d && typeof d.id === "string" && typeof d.repositoryKey === "string" && Number.isInteger(d.number) && typeof d.body === "string" && d.anchor && typeof d.anchor.path === "string" && Number.isInteger(d.anchor.line) && ["LEFT", "RIGHT"].includes(d.anchor.side) && [d.anchor.headSHA, d.anchor.baseSHA, d.anchor.startSHA].every((s) => typeof s === "string" && s.length > 0));
  } catch { return []; }
}
