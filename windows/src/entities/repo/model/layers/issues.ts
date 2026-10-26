import type { LoadState } from "@/entities/git";
import * as Hosting from "@/entities/hosting";
import { accounts, type InboxItem, type IssueScope } from "@/entities/hosting";
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
  /** The text in the search field; a search runs on Enter */
  issueSearch = "";
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
    this.issueState = { kind: "loading" }; this.emit();
    const c = await this.workspaceAccess();
    if (!current()) return;
    if (!c) { this.issues = []; this.issuePage = 0; this.issuesMore = false; this.issueState = { kind: "needsAccount" }; this.emit(); return; }
    try {
      const result = await Hosting.issuePage(c, this.issueScope, this.issueSearch, page);
      if (!current()) return;
      this.issues = append ? [...this.issues, ...result.items.filter((i) => !this.issues.some((old) => old.id === i.id))] : result.items;
      this.issuePage = page; this.issuesMore = result.more; this.issueState = { kind: "loaded" };
    } catch (e) { if (current()) this.issueState = { kind: "failed", message: describe(e) }; }
    if (current()) this.emit();
  }

  /** A new filter or search reloads the list from its first page; the open issue stays */
  async filterIssues(scope: IssueScope, search = this.issueSearch) {
    this.issueScope = scope; this.issueSearch = search;
    await this.loadIssues();
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

  private clearIssueList() {
    this.issueListToken++;
    this.issues = []; this.issuePage = 0; this.issuesMore = false; this.issueState = { kind: "idle" };
  }

  protected override resetState() {
    this.clearIssueList();
    this.issueContext = ""; this.issueScope = "open"; this.issueSearch = "";
    super.resetState();
  }
}
