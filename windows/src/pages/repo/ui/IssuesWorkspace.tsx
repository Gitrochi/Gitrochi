import { useEffect } from "react";
import { CircleDot, CircleX, Globe } from "@/shared/icons";
import { ChevronLeft, GitBranch, GitPullRequest, MessageSquare, PanelRight, Plus, RefreshCw, Search } from "@/shared/icons";
import { IssueDetail } from "@/widgets/inspector";
import type { RepoStore } from "@/entities/repo";
import {
  accounts, assignedIssueCount, type InboxItem, issueNext, type IssueScope, type IssueSort, issueSummary, issueSummaryCard, issueSummaryCounts, issueSummaryLines,
  issueSummaryTotal, workStateTitle,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { listDay, listWhen, useObserve } from "@/shared/lib";
import {
  Avatar, Button, FailureBlock, hostedListAge, HostedAccountNeeded, HostedListChip, HostedListColumns, HostedListEmpty, HostedListHeader, HostedListIconButton,
  HostedListLoading, HostedListPage, HostedListRow, HostedListSearch, HostedListSegments, HostedListSummary, HostedListSummaryBar, HostedListSummaryBars,
  HostedListSummaryLoadingLine, HostedListTextButton, showContextMenu, Spinner,
} from "@/shared/ui";
import "./issues-workspace.css";

/**
 * Issues, as the redesign's Issues board draws it: where the page is and its actions, what is assigned to you, then
 * the list column and the open issue beside it. The page fills the window; only the list column keeps its width.
 * (macOS: IssuesWorkspacePanel)
 */
export function IssuesWorkspace({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  useObserve(accounts);
  const key = store.issueContextKey;
  useEffect(() => { void store.prepareIssues(); void store.loadAssignedIssues(); }, [store, key]);
  const target = store.target;
  if (!target)
    return (
      <HostedListPage>
        <HostedListEmpty icon={<Globe size={24} />} title={t("No hosting remote")} caption={t("Open a repository with a GitHub or GitLab remote to use this workspace.")}
          action={{ label: t("Open repository…"), filled: true, onClick: () => void store.pickAndOpen() }} />
      </HostedListPage>
    );
  const detail = store.inboxDetail?.item.kind === "issue" ? store.inboxDetail : null;
  const refresh = () => { void store.loadIssues(); void store.loadAssignedIssues(); };
  const branchIssue = store.currentBranchIssue;
  // the issue the current branch was created for; the list may not have loaded it
  const openBranchIssue = () => {
    const number = branchIssue?.number;
    if (!branchIssue || !number) return;
    void store.openInboxItem(store.issues.find((issue) => issue.number === number)
      ?? { id: `issue-${number}`, kind: "issue", number, title: branchIssue.title, url: branchIssue.url, body: "", state: "open", updated: null, author: "", unread: false });
  };
  return (
    <HostedListPage className="issues-page">
      <HostedListHeader host={target.host} path={target.path}>
        <HostedListIconButton label={t("Refresh list")} disabled={store.issueState.kind === "loading"} onClick={refresh}><RefreshCw size={14} /></HostedListIconButton>
        <Button disabled={!store.hostingAccount} onClick={() => store.openSheet({ kind: "issueEditor", title: "", body: "" })}><Plus size={13} />{t("New issue…")}</Button>
      </HostedListHeader>
      {store.issueState.kind === "needsAccount" ? (
        <HostedAccountNeeded gitlab={target.provider === "gitlab"} host={target.host} path={target.path} onConnect={openSettings} />
      ) : (
        <>
          <IssueSummaryCard store={store} />
          <HostedListColumns detail={!!detail} list={<IssueListColumn store={store} />}>
            {detail ? (
              <>
                <div className="hosted-back">
                  <Button onClick={() => { store.inboxDetail = null; store.changed(); }}><ChevronLeft size={14} />{t("Back to issues")}</Button>
                </div>
                <IssueDetail store={store} detail={detail} />
              </>
            ) : (
              <HostedListEmpty icon={<PanelRight size={24} />} title={t("Select an issue")} caption={t("Search the list, then read the conversation and reply here.")}
                action={branchIssue ? { label: t("Show this branch's issue"), filled: true, onClick: openBranchIssue } : undefined} />
            )}
          </HostedListColumns>
        </>
      )}
    </HostedListPage>
  );
}

/** What is assigned to you: how far each issue's work is, as this repository knows it, and the one next step */
function IssueSummaryCard({ store }: { store: RepoStore }) {
  const items = store.issueAssigned;
  // what stands in for the summary until the assigned issues are read: still on their way, or out of reach
  const pending = store.issueAssignedFailed ? t("Couldn't reach {0}", store.target?.host ?? "") : t("Loading issues…");
  const assigned = (items ?? []).map((item) => store.issueProgress(item));
  const summary = issueSummary(assigned), total = issueSummaryTotal(summary), lines = issueSummaryLines(summary), counts = issueSummaryCounts(summary);
  const card = issueSummaryCard(items !== null, store.issueAssignedFailed, total);
  const next = issueNext(assigned, store.headBranch);
  const nextItem = next ? items?.find((item) => item.number === next.number) : undefined;
  const reviewOnThisBranch = !!store.headBranch && assigned.some((item) => item.progress === "inReview" && item.branch === store.headBranch);
  // the number of open issues, when the list shows all of them
  const open = store.issueScope === "open" && store.issueState.kind === "loaded" && !store.issuesMore && !store.issueLoadedSearch.trim() ? store.issues.length : null;
  const action = next && nextItem ? (
    next.kind === "createBranch" ? (
      <Button disabled={!!store.busy || !store.headHash} onClick={() => store.requestIssueBranch(nextItem)}><GitBranch size={14} />{t("Create branch for #{0}", String(next.number))}</Button>
    ) : (
      <Button disabled={!!store.busy} onClick={() => store.requestIssuePullRequest(nextItem)}>
        <GitPullRequest size={14} />{store.target?.provider === "gitlab" ? t("Create merge request for #{0}…", String(next.number)) : t("Create pull request for #{0}…", String(next.number))}
      </Button>
    )
  ) : items && !items.length && store.issueScope !== "open" ? (
    <Button onClick={() => void store.filterIssues("open")}>{t("Show open issues")}</Button>
  ) : null;
  const parts: [string, number][] = [["review", summary.inReview.length], ["progress", summary.inProgress.length], ["idle", summary.notStarted.length]];
  return (
    <HostedListSummary
      label={t("Issues assigned to you")}
      // with nothing assigned the card is one column of words, as the board draws it
      spread={card === "empty"}
      lead={
        <>
          <span className="hosted-summary-key">{t("Assigned to you")}</span>
          {card === "loading" ? <HostedListSummaryLoadingLine caption={pending} />
            : card === "unreachable" ? <span className="hosted-caption ellipsis">{pending}</span>
            : card === "empty" ? <><span className="hosted-summary-value">{t("No open issues are assigned to you")}</span>{open !== null && open > 0 && <span className="hosted-caption ellipsis">{t("{0} issues are open in {1}.", open, store.target?.path ?? "")}</span>}</>
            : <><span className="hosted-summary-value">{lines[0]}</span>{lines.length > 1 && <span className="hosted-caption ellipsis">{lines.slice(1).join(" · ")}</span>}</>}
        </>
      }
      middle={card === "loading" ? <HostedListSummaryBars /> : total > 0 ? (
        <div className="issue-summary-middle">
          {/* one bar, a part for each group as wide as its share; the legend under it says which is which */}
          <div className="issue-bar" role="img" aria-label={counts}>
            {parts.filter(([, count]) => count > 0).map(([name, count]) => <span key={name} className={name} style={{ flex: `${count} 1 0` }} />)}
          </div>
          <div className="issue-legend" aria-hidden>
            {summary.inReview.length > 0 && <span><i className="review" /><b>{t("In review")}</b>{reviewOnThisBranch && <span className="hosted-caption">{t("on this branch")}</span>}</span>}
            {summary.inProgress.length > 0 && <span><i className="progress" /><b>{t("In progress")}</b></span>}
            {summary.notStarted.length > 0 && <span><i className="idle" /><b>{t("Not started")}</b></span>}
          </div>
        </div>
      ) : null}
      trail={
        <>
          {card === "loading" && <HostedListSummaryBar />}
          {action}
          {next?.kind === "createBranch" && nextItem?.created != null && <span className="hosted-caption">{t("Oldest, opened {0}", listDay(nextItem.created))}</span>}
          {next?.kind === "createRequest" && <span className="hosted-caption ellipsis" style={{ maxWidth: "100%" }}>{next.branch}</span>}
        </>
      }
      strip={
        <>
          {card === "loading" ? <Spinner size={14} /> : <CircleDot size={14} />}
          <span className="hosted-caption" style={{ flex: "none" }}>{t("Assigned to you")}</span>
          {items === null ? <span className="hosted-caption ellipsis">{pending}</span>
            : <span className="hosted-strip-text">{total === 0 ? t("No open issues are assigned to you") : counts.replace(/, /g, " · ")}</span>}
          <span className="spacer" />
          {action}
        </>
      }
    />
  );
}

/** The Issues page's list column: search and order, the three filters, then the rows */
function IssueListColumn({ store }: { store: RepoStore }) {
  const st = store.issueState, host = store.target?.host ?? "";
  const sorts: { value: IssueSort; title: string }[] = [{ value: "updated", title: t("Recently updated") }, { value: "created", title: t("Newest first") }, { value: "oldest", title: t("Oldest first") }];
  const reload = () => void store.loadIssues();
  const show = (scope: IssueScope) => void store.filterIssues(scope);
  const search = store.issueLoadedSearch.trim();
  const selected = store.inboxDetail?.item.kind === "issue" ? store.inboxDetail.item.id : null;
  const requests = store.issueRequests(store.issues);
  const icon = <CircleDot size={24} />;
  return (
    <aside className="hosted-list" aria-label={t("Issue list")}>
      {st.kind === "failed" && store.issues.length > 0 && <FailureBlock title={t("Couldn't reach {0}", host)} caption={hostedListAge(store.issueLoadedAt)} detail={st.message} retry={reload} />}
      <HostedListSearch
        prompt={t("Search issues")}
        text={store.issueSearch}
        onText={(text) => { store.issueSearch = text; store.changed(); }}
        onSearch={(text) => void store.filterIssues(store.issueScope, text)}
        menuTitle={`${t("Sort")}: ${sorts.find((sort) => sort.value === store.issueSort)?.title ?? ""}`}
        menu={() => sorts.map((sort) => ({ label: sort.title, checked: sort.value === store.issueSort, onClick: () => void store.sortIssues(sort.value) }))}
      />
      {/* only "Assigned to you" counts: it is the segment that needs your attention */}
      <HostedListSegments<IssueScope>
        options={[
          { value: "open", title: workStateTitle("open") },
          { value: "assigned", title: t("Assigned to you"), count: store.issueAssigned ? assignedIssueCount(store.issueAssigned.length, store.issueAssignedMore) : null },
          { value: "closed", title: workStateTitle("closed") },
        ]}
        selection={store.issueScope}
        onSelect={show}
      />
      {st.kind === "failed" && !store.issues.length ? (
        <HostedListEmpty failed icon={<CircleX size={24} />} title={t("Couldn't reach {0}", host)} caption={st.message} action={{ label: t("Retry"), onClick: reload }} />
      ) : (st.kind === "loading" || st.kind === "idle") && !store.issues.length ? (
        <HostedListLoading caption={t("Loading issues…")} />
      ) : !store.issues.length ? (
        search ? <HostedListEmpty icon={<Search size={24} />} title={t("No issues match “{0}”", search)} action={{ label: t("Clear search"), onClick: () => void store.filterIssues(store.issueScope, "") }} />
          : store.issueScope === "closed" ? <HostedListEmpty icon={icon} title={t("No closed issues")} action={{ label: t("Show open issues"), onClick: () => show("open") }} />
          : store.issueScope === "assigned" ? <HostedListEmpty icon={icon} title={t("No open issues are assigned to you")} action={{ label: t("Show open issues"), onClick: () => show("open") }} />
          : <HostedListEmpty icon={icon} title={t("No open issues")} caption={t("Nothing is open in {0}. Closed issues are under Closed.", store.target?.path ?? "")} action={{ label: t("Show closed issues"), onClick: () => show("closed") }} />
      ) : (
        <div className="hosted-rows">
          {store.issues.map((issue) => <IssueRow key={issue.id} store={store} issue={issue} selected={selected === issue.id} request={requests.get(issue.number)?.number} />)}
          {store.issuesMore && <HostedListTextButton className="hosted-more" disabled={st.kind === "loading"} onClick={() => void store.loadIssues(true)}>{t("Show more")}</HostedListTextButton>}
        </div>
      )}
    </aside>
  );
}

/**
 * A row ends with its comment count and its author's avatar, like a pull request row. The state is not repeated:
 * the segment already says it.
 */
function IssueRow({ store, issue, selected, request }: { store: RepoStore; issue: InboxItem; selected: boolean; request?: number }) {
  const comments = issue.comments ?? 0;
  return (
    <HostedListRow
      selected={selected}
      title={issue.title}
      when={issue.updated != null ? listWhen(issue.updated) : null}
      data-issue={issue.number}
      onClick={() => void store.openInboxItem(issue)}
      onContextMenu={(event) =>
        showContextMenu(event, [
          { label: t("Open in browser"), onClick: () => store.openUrl(issue.url) },
          { label: t("Copy link"), onClick: () => store.copy(issue.url) },
        ])
      }
    >
      <span className="mono">#{issue.number}</span>
      {request != null && <HostedListChip icon={<GitPullRequest size={11} />}>#{request}</HostedListChip>}
      <span className="spacer" />
      {comments > 0 && <span className="issue-row-comments" role="img" aria-label={comments === 1 ? t("1 comment") : t("{0} comments", comments)}><MessageSquare size={11} />{comments}</span>}
      {issue.author && <span className="issue-row-author" role="img" aria-label={`@${issue.author}`} data-tip={`@${issue.author}`}><Avatar name={issue.author} email={issue.author} size={16} /></span>}
    </HostedListRow>
  );
}
