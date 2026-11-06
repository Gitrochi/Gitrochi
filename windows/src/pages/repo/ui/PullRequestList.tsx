import { ArrowUpDown, Eye, GitPullRequestDraft, MessageSquare, PanelLeftClose, Search, X } from "lucide-react";
import { useEffect, useState } from "react";
import { commentCount, isThisBranch, requestDate, type RequestSort, reviewRequestedCount, sorted } from "@/widgets/inspector";
import { CIStatusIcon, statusInfo } from "@/entities/ci";
import { accountHost, type PullRequest, type RepoTarget } from "@/entities/git";
import { accounts, type RequestScope, workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { longDate, useObserve } from "@/shared/lib";
import { Avatar, Button, Segmented, showContextMenu, showMenuBelow, Spinner, StatusPill } from "@/shared/ui";

const sortSetting = "pullRequestSort";

/**
 * The list column of the Pull requests page: search, sort and the Hide list control in one row, the filter below, and
 * two-line rows that end with the comment count and the author. The repository sidebar keeps its own compact section.
 * (macOS: PullRequestList.swift)
 */
export function PullRequestList({ store, target, openSettings, onHide }: { store: RepoStore; target: RepoTarget; openSettings: () => void; onHide: () => void }) {
  useObserve(store);
  useObserve(accounts);
  useObserve(store.ci);
  useObserve(settings);
  const gitlab = target.provider === "gitlab";
  const st = store.prState, scope = store.requestQuery.scope;
  const [search, setSearch] = useState(store.requestQuery.search);
  useEffect(() => setSearch(store.requestQuery.search), [store.requestQuery.search]);
  const sort = settings.get<RequestSort>(sortSetting, "updated");
  // The count beside "Review requested" is read off the open list, and stays while another filter shows
  const [requested, setRequested] = useState(0);
  const loadedCount = st.kind === "loaded" && scope === "open" ? reviewRequestedCount(store.pullRequests) : st.kind === "loaded" && scope === "reviewRequested" ? store.pullRequests.length : null;
  useEffect(() => { if (loadedCount != null) setRequested(loadedCount); }, [loadedCount]);
  const filter = (value: RequestScope) => void store.filterPullRequests(value, search);
  const submit = (text: string) => void store.filterPullRequests(scope, text);
  // An account on this very host cannot be an alias for it, so only other servers are worth a try.
  const other = accounts.accountsFor(target.provider).find((a) => accountHost(a) !== target.host);
  const sortItem = (value: RequestSort, label: string) => ({ label, checked: sort === value, onClick: () => settings.set(sortSetting, value) });
  // Closed and Merged have no segment, so they live here; choosing the checked one goes back to open requests
  const showItem = (value: RequestScope) => ({ label: workStateTitle(value), checked: scope === value, onClick: () => filter(scope === value ? "open" : value) });
  const hideLabel = t(gitlab ? "Hide merge request list" : "Hide pull request list");
  const row = (pr: PullRequest) => {
    const selected = store.selection?.kind === "pullRequest" && store.selection.number === pr.number;
    const run = pr.headSHA ? store.ci.bySha.get(pr.headSHA) : undefined;
    const comments = commentCount(pr, store.review);
    return <button type="button" key={pr.number} className={`pr-row ${selected ? "selected" : ""}`} data-request={pr.number} aria-current={selected}
      onClick={() => store.select({ kind: "pullRequest", number: pr.number })}
      onContextMenu={(event) => showContextMenu(event, [
        { label: t("Check out branch"), onClick: () => void store.checkoutPullRequest(pr) },
        { label: t("Open in browser"), onClick: () => store.openUrl(pr.url) },
        { label: t("Copy link"), onClick: () => store.copy(pr.url) },
      ])}>
      <span className="pr-row-top">
        <span className="pr-row-title">{pr.title}</span>
        {pr.updated != null && <span className="pr-row-when" title={longDate(pr.updated)}>{requestDate(pr.updated)}</span>}
      </span>
      <span className="pr-row-meta">
        <span className="pr-row-number mono">#{pr.number}</span>
        {run && <span className="ci-badge" data-tip={`CI: ${statusInfo[run.status].title} · #${run.number}`}><CIStatusIcon status={run.status} size={12} /></span>}
        {pr.isDraft && <StatusPill tone="waiting" icon={<GitPullRequestDraft />}>{t("Draft")}</StatusPill>}
        {isThisBranch(pr, store.headBranch) && <StatusPill tone="neutral"><span className="pr-row-dot" aria-hidden="true" />{t("This branch")}</StatusPill>}
        {/* a badge never repeats the filter that already says it */}
        {pr.reviewRequested && scope !== "reviewRequested" && <StatusPill tone="info" icon={<Eye />} className="pr-row-shrink"><span className="ellipsis">{t("Review requested")}</span></StatusPill>}
        <span className="spacer" />
        {!!comments && <span className="pr-row-comments" role="img" aria-label={comments === 1 ? t("1 comment") : t("{0} comments", comments)}><MessageSquare size={11} />{comments}</span>}
        <span role="img" aria-label={`@${pr.author}`} title={`@${pr.author}`}><Avatar name={pr.author} email={pr.author} size={16} /></span>
      </span>
    </button>;
  };
  return (
    <aside className="pr-list" aria-label={t(gitlab ? "Merge requests" : "Pull requests")}>
      <div className="pr-list-controls">
        <label className="pr-list-search">
          <Search size={13} />
          <input aria-label={t(gitlab ? "Search merge requests" : "Search pull requests")} placeholder={t(gitlab ? "Search merge requests" : "Search pull requests")} value={search}
            onChange={(event) => setSearch(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") submit(search);
              else if (event.key === "Escape" && search) { event.stopPropagation(); setSearch(""); submit(""); }
            }} />
          {search && <button type="button" className="pr-list-clear" aria-label={t("Clear search")} data-tip={t("Clear search")} onClick={() => { setSearch(""); submit(""); }}><X size={12} /></button>}
        </label>
        <Button className={`pr-page-icon ${sort !== "updated" || scope === "closed" || scope === "merged" ? "on" : ""}`} aria-label={t("Sort")} aria-haspopup="menu" tip={t("Sort")} onClick={(event) => showMenuBelow(event.currentTarget, [
          { label: t("Sort by"), disabled: true },
          sortItem("updated", t("Recently updated")), sortItem("newest", t("Newest")), sortItem("comments", t("Most commented")),
          "divider",
          { label: t("Show"), disabled: true },
          showItem("closed"), showItem("merged"),
        ])}><ArrowUpDown size={14} /></Button>
        <Button className="pr-page-icon" aria-label={hideLabel} aria-expanded={true} tip={t("Hide list")} onClick={onHide}><PanelLeftClose size={14} /></Button>
      </div>
      <div role="group" aria-label={t("Filter")}>
        <Segmented<RequestScope> stretch value={scope} onChange={filter} options={[
          { value: "open", label: workStateTitle("open") },
          { value: "reviewRequested", label: requested > 0 ? `${t("Review requested")} ${requested}` : t("Review requested") },
          { value: "mine", label: t("Mine") },
        ]} />
      </div>
      {store.requestsWarning && <span className="pr-list-note">{store.requestsWarning}</span>}
      {st.kind === "needsAccount" && !store.hostingAccount && (
        <div className="pr-list-state">
          {other && <button className="link" onClick={() => void store.tryExistingAccounts()} data-tip={t("If the same server is used under another address, an account you've already connected works there too")}>{t("Try with the connected account (@{0})", other.username)}</button>}
          <button className="link" onClick={openSettings}>{gitlab ? t("Connect a self-hosted GitLab ({0}) account…", target.host) : t("Connect a GitHub account…")}</button>
        </div>
      )}
      {st.kind === "needsAccount" && store.hostingAccount && <div className="pr-list-state"><span className="pr-list-note">{t("Couldn't read the saved account credentials. Unlock your credentials, then retry.")}</span><button className="link" onClick={() => void store.loadPullRequests()}>{t("Retry")}</button></div>}
      {st.kind === "failed" && <div className="pr-list-state"><span className="error-text selectable">{st.message}</span><button className="link" onClick={() => void store.loadPullRequests()}>{t("Retry")}</button></div>}
      {st.kind === "loading" && !store.pullRequests.length && <div className="pr-list-state"><Spinner size={12} /></div>}
      {st.kind === "loaded" && !store.pullRequests.length && <div className="pr-list-note">{t(gitlab ? "No merge requests match this filter." : "No pull requests match this filter.")}</div>}
      <div className="pr-rows">
        {sorted(store.pullRequests, sort).map(row)}
        {store.requestsMore && <button type="button" className="pr-list-more" disabled={st.kind === "loading"} onClick={() => void store.loadPullRequests(true)}>{t("Load more")}</button>}
      </div>
    </aside>
  );
}
