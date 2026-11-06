import type { LoadState } from "@/entities/git";
import * as Hosting from "@/entities/hosting";
import type { PullRequest } from "@/entities/git";
import { accounts, type AssignedIssue, type InboxItem, type IssueScope, type IssueSort } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { describe } from "@/shared/platform";
import { RepoHosting } from "./hosting";

/**
 * The repository's issue list, shared by the repository sidebar and the Issues page. The open issue is the
 * collaboration detail (inboxDetail) and survives page changes; only another repository, server or account resets it.
 * (macOS: RepoStore+Issues.swift)
 */
export abstract class RepoIssues extends RepoHosting {
  issues: InboxItem[] = [];
  issueScope: IssueScope = "open";
  issueSort: IssueSort = "updated";
  /** The open issues assigned to this account, for the Issues page's summary and its segment count; null until read */
  issueAssigned: InboxItem[] | null = null;
  issueAssignedMore = false;
  /** The assigned issues could not be read and none are shown from before */
  issueAssignedFailed = false;
  /** When the list last arrived, in seconds, for "Showing data from 12m ago" after a refresh fails */
  issueLoadedAt: number | null = null;
  private issueAssignedContext = "";
  /** The text in the search field; a search runs on Enter */
  issueSearch = "";
  /** The search the list was loaded with (the sidebar's filter caption shows it, not unsent typing) */
  issueLoadedSearch = "";
  /** Pages loaded for the current context (0: not loaded yet) */
  issuePage = 0;
  issuesMore = false;
  issueState: LoadState = { kind: "idle" };
  private issueContext = "";
  private issueListToken = 0;

  /** Which repository, server and account the list belongs to; the filter is not part of it */
  get issueContextKey() {
    return JSON.stringify([this.path, this.collaborationRevision, this.target?.host ?? null, this.target?.path ?? null, this.hostingAccount?.id ?? null, accounts.revision]);
  }

  /** Loads the list for a new context or the first time; keeps an issue that is already open in the same context */
  async prepareIssues() {
    const key = this.issueContextKey;
    if (key !== this.issueContext) {
      if (this.inboxDetail?.item.kind === "issue") this.inboxDetail = null;
      this.clearIssueList();
      this.issueContext = key;
    }
    if (this.issueState.kind === "idle") await this.loadIssues();
  }

  async loadIssues(append = false) {
    const key = this.issueContextKey, token = ++this.issueListToken, page = append ? this.issuePage + 1 : 1;
    const current = () => token === this.issueListToken && key === this.issueContextKey;
    this.issueContext = key;
    if (!this.target) { this.clearIssueList(); this.emit(); return; }
    if (!append) this.issueLoadedSearch = this.issueSearch;
    this.issueState = { kind: "loading" }; this.emit();
    try {
    const c = await this.workspaceAccess();
    if (!current()) return;
    if (!c) {
      this.issues = []; this.issuePage = 0; this.issuesMore = false;
      this.issueState = this.hostingAccount
        ? { kind: "failed", message: t("Couldn't read the saved account credentials. Unlock your credentials, then retry.") }
        : { kind: "needsAccount" };
      this.emit(); return;
    }
      const result = await Hosting.issuePage(c, this.issueScope, this.issueSearch, page, this.issueSort);
      if (!current()) return;
      this.issues = append ? [...this.issues, ...result.items.filter((i) => !this.issues.some((old) => old.id === i.id))] : result.items;
      this.issuePage = page; this.issuesMore = result.more; this.issueState = { kind: "loaded" }; this.issueLoadedAt = Date.now() / 1000;
    } catch (e) { if (current()) this.issueState = { kind: "failed", message: describe(e) }; }
    if (current()) this.emit();
  }

  /** A new filter or search reloads the list from its first page; the open issue stays */
  async filterIssues(scope: IssueScope, search = this.issueSearch) {
    this.issueScope = scope; this.issueSearch = search;
    await this.loadIssues();
  }

  /** updated, created or oldest; the list starts over in the new order */
  async sortIssues(sort: IssueSort) {
    this.issueSort = sort;
    await this.loadIssues();
  }

  /** What is assigned to this account, for the Issues page's summary and the count on its segment; a failure leaves it as it was */
  async loadAssignedIssues() {
    const key = this.issueContextKey;
    if (key !== this.issueAssignedContext) { this.issueAssigned = null; this.issueAssignedMore = false; this.issueAssignedFailed = false; this.issueAssignedContext = key; this.emit(); }
    if (!this.target) return;
    try {
      const c = await this.workspaceAccess();
      if (!c || key !== this.issueContextKey) return;
      const result = await Hosting.issuePage(c, "assigned", "", 1, "oldest");
      if (key !== this.issueContextKey) return;
      this.issueAssigned = result.items; this.issueAssignedMore = result.more; this.issueAssignedFailed = false;
    } catch {
      // the summary keeps what it showed; with nothing to show it says the server was out of reach
      if (key !== this.issueContextKey) return;
      this.issueAssignedFailed = this.issueAssigned === null;
    }
    this.emit();
  }

  /** The local branches this repository linked to the issue */
  issueBranches(item: InboxItem): string[] {
    const task = Hosting.issueTaskReference(this.target, item);
    return task && this.path ? Hosting.projectIssueBranches(this.path, task).filter((name) => this.localBranches.some((branch) => branch.name === name)) : [];
  }

  /** The branches of the loaded requests, when the request list shows open ones (a closed request is no review) */
  private get openRequestBranches(): Set<string> {
    return new Set(["open", "mine", "reviewRequested"].includes(this.requestQuery.scope) ? this.pullRequests.map((request) => request.source) : []);
  }

  /** How far the issue's work is, as this repository knows it: its linked branches and their loaded requests */
  issueProgress(item: InboxItem): AssignedIssue {
    const branches = this.issueBranches(item);
    return { number: item.number, progress: Hosting.issueProgress(branches, this.openRequestBranches), branch: branches.find((name) => name === this.headBranch) ?? branches[0] };
  }

  /** The loaded request each issue's branch opened, by issue number */
  issueRequests(items: InboxItem[]): Map<number, PullRequest> {
    const out = new Map<number, PullRequest>();
    if (!this.openRequestBranches.size) return out;
    for (const item of items) {
      const branches = this.issueBranches(item), request = this.pullRequests.find((value) => branches.includes(value.source));
      if (request) out.set(item.number, request);
    }
    return out;
  }

  /** Shows a request one of the issue's branches opened on the Pull requests page */
  openIssueRequest(request: PullRequest) {
    this.navigate("pullRequests");
    this.select({ kind: "pullRequest", number: request.number });
  }

  /** Shows the issue on the Issues page */
  openIssue(item: InboxItem) {
    this.navigate("issues");
    void this.openInboxItem(item);
  }

  /** Closing or reopening asks once, then refreshes the issue and the list */
  confirmIssueState(item: InboxItem) {
    const key = this.issueContextKey, open = ["open", "opened"].includes(item.state);
    this.confirm = { title: t("Change issue state?"), message: item.title, actionTitle: open ? t("Close issue") : t("Reopen"), destructive: false, action: async () => {
      if (key === this.issueContextKey && await this.inboxAction(item, open ? "close" : "reopen") && key === this.issueContextKey) await this.loadIssues();
    } };
    this.emit();
  }

  /** Saves a new issue or an edit, then shows it; errors reach the editor that asked */
  async saveIssue(title: string, body: string, number?: number) {
    const c = await this.workspaceAccess();
    if (!c) throw new Error(t("Connect an account to load this workspace."));
    const item = await Hosting.saveWorkspaceIssue(c, title, body, number);
    if (c.stillCurrent?.() === false) return;
    await this.loadIssues();
    await this.openInboxItem(item);
  }

  /** Opens a reviewed branch dialog without changing Git or posting to the server. */
  requestIssueBranch(item: InboxItem) {
    const task = Hosting.issueTaskReference(this.target, item);
    if (!task || !this.headHash || this.busy) return;
    this.requestNewBranch(this.headHash, this.headBranch ?? "HEAD", Hosting.issueBranchName(task), task);
  }

  get currentBranchIssue() {
    const task = this.path && this.headBranch && this.target ? Hosting.projectBranchTask(this.path, this.headBranch, this.target.path, this.target.host) : null;
    return task ? Hosting.issueTaskReference(this.target, { ...task, number: task.number ?? 0, kind: "issue" }) : null;
  }

  requestIssuePullRequest(item: InboxItem) {
    const task = Hosting.issueTaskReference(this.target, item), branch = this.headBranch;
    if (!task || !branch || this.busy) return;
    const existing = this.pullRequests.find(request => request.source === branch);
    if (existing) { this.navigate("pullRequests"); this.select({ kind: "pullRequest", number: existing.number }); return; }
    this.newPullRequestDraft = { branch, title: task.title, body: Hosting.issueRequestBody(task), base: "", draft: true, issue: task };
    this.openSheet({ kind: "createPullRequest" });
  }

  async changeIssueComment(item: InboxItem, comment: Hosting.InboxComment, body: string | null) {
    if (this.inboxBusy || this.inboxLoading || this.inboxDetail?.item.id !== item.id || !this.inboxDetail.comments.some(value => value.id === comment.id && value.body === comment.body && value.editable)) return false;
    const key = this.issueContextKey, current = () => key === this.issueContextKey && this.inboxDetail?.item.id === item.id;
    this.inboxBusy = true; this.inboxError = null; this.emit();
    try {
      const access = await this.workspaceAccess();
      if (!access || !current()) return false;
      await Hosting.changeIssueComment({ ...access, stillCurrent: () => current() && access.stillCurrent?.() !== false }, item, comment, body);
      if (!current()) return false;
      await this.openInboxItem(item); return current();
    } catch (error) { if (current()) this.inboxError = describe(error); return false; }
    finally { if (key === this.issueContextKey) { this.inboxBusy = false; this.emit(); } }
  }
  confirmDeleteIssueComment(item: InboxItem, comment: Hosting.InboxComment) {
    const key = this.issueContextKey;
    this.confirm = { title: t("Delete comment?"), message: t("This permanently deletes your comment."), actionTitle: t("Delete"), destructive: true, action: async () => { if (key === this.issueContextKey) await this.changeIssueComment(item, comment, null); } }; this.emit();
  }
  async issueLinkedRequests(item: InboxItem, page = 1) {
    const key = this.issueContextKey, access = await this.workspaceAccess();
    if (!access || key !== this.issueContextKey) throw new Error(t("The repository or account changed. Reopen this action."));
    return Hosting.issueLinkedRequests({ ...access, stillCurrent: () => key === this.issueContextKey && access.stillCurrent?.() !== false }, item, page);
  }

  private clearIssueList() {
    this.issueListToken++;
    this.issues = []; this.issuePage = 0; this.issuesMore = false; this.issueState = { kind: "idle" }; this.issueLoadedAt = null;
  }

  protected override resetState() {
    this.clearIssueList();
    this.issueContext = ""; this.issueScope = "open"; this.issueSort = "updated"; this.issueSearch = ""; this.issueLoadedSearch = "";
    this.issueAssigned = null; this.issueAssignedMore = false; this.issueAssignedFailed = false; this.issueAssignedContext = "";
    super.resetState();
  }
}
