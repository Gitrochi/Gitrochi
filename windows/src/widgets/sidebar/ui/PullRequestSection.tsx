import { useEffect, useState } from "react";
import type { RequestScope } from "@/entities/hosting";
import { ChevronDown, GitBranch, GitPullRequest, Plus, RefreshCw, Search, TriangleAlert, UserRound, X } from "lucide-react";
import { CIStatusIcon, statusInfo } from "@/entities/ci";
import { providerInfo, type RepoTarget } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import { Button, IconButton, type MenuItem, showContextMenu, showMenuBelow, Spinner } from "@/shared/ui";
import { Section } from "./Section";
import "./pull-requests.css";

const scopeTitle = (scope: RequestScope) => t(scope === "reviewRequested" ? "Review requested" : scope === "mine" ? "Created by me" : scope === "open" ? "Open" : scope === "closed" ? "Closed" : "Merged");

export function PullRequestSection({ store, target, openSettings }: { store: RepoStore; target: RepoTarget; openSettings: () => void }) {
  useObserve(accounts);
  useObserve(store.ci);
  const info = providerInfo[target.provider];
  const current = store.hostingAccount;
  const candidates = accounts.candidates(target);
  const st = store.prState;
  const [search, setSearch] = useState(store.requestQuery.search);
  useEffect(() => setSearch(store.requestQuery.search), [target.host, target.path, store.requestQuery.search]);
  const loading = st.kind === "loading";
  return (
    <Section
      id="prs"
      title={t(target.provider === "gitlab" ? "Merge requests" : "Pull requests")}
      count={st.kind === "loaded" ? store.pullRequests.length : undefined}
      actions={<>
        <IconButton small disabled={loading} icon={<RefreshCw size={13} />} tip={t("Refresh list")} onClick={() => void store.loadPullRequests()} />
        <IconButton small icon={<Plus size={14} />} tip={t("New {0} from the current branch", info.requestShort)} disabled={!store.headBranch} onClick={() => store.openSheet({ kind: "createPullRequest" })} />
      </>}
    >
      <div className="pr-list-controls">
        <form className="pr-list-filter" onSubmit={(e) => { e.preventDefault(); void store.filterPullRequests(store.requestQuery.scope, search); }}>
          <select className="select" aria-label={t("Request filter")} value={store.requestQuery.scope} onChange={(e) => void store.filterPullRequests(e.target.value as RequestScope, search)}>
            {(["open", "closed", "merged", "mine", "reviewRequested"] as const).map((scope) => <option key={scope} value={scope}>{scopeTitle(scope)}</option>)}
          </select>
          <div className="pr-search-field">
            <Search size={13} aria-hidden="true" />
            <input className="input" value={search} onChange={(e) => setSearch(e.target.value)} placeholder={t("Search requests")} aria-label={t("Search requests")} />
            {search && <IconButton small type="button" icon={<X size={12}/>} tip={t("Clear search")} onClick={() => { setSearch(""); void store.filterPullRequests(store.requestQuery.scope, ""); }} />}
            <IconButton small type="submit" icon={<Search size={13}/>} tip={t("Search requests")} disabled={loading}/>
          </div>
        </form>
        {current && <button type="button" className="pr-account" title={t("Choose the account for this repository")} onClick={(e) => showMenuBelow(e.currentTarget, [
          ...candidates.map((a): MenuItem => ({ label: `@${a.username}`, checked: a.id === current.id, onClick: () => store.useAccount(a) })),
          "divider", { label: t("Add account…"), onClick: openSettings },
        ])}><UserRound size={13}/><span className="ellipsis">@{current.username}</span><span className="pr-account-host ellipsis">{target.host}</span><ChevronDown size={11}/></button>}
        {store.requestsWarning && <span className="pr-list-notice">{store.requestsWarning}</span>}
      </div>
      {st.kind === "needsAccount" && <div className="pr-list-state">
        <UserRound size={23}/><strong>{t("Connect account…")}</strong><p>{t("Connect an account to see the conversation and approvals.")}</p>
        {accounts.accountsFor(target.provider)[0] && <Button size="small" block onClick={() => void store.tryExistingAccounts()}>{t("Try connected account")}</Button>}
        <Button size="small" block kind="primary" onClick={openSettings}>{t("Connect {0} account", target.provider === "gitlab" ? "GitLab" : "GitHub")}</Button>
      </div>}
      {st.kind === "failed" && <div className="pr-list-state" role="alert"><TriangleAlert size={23}/><strong>{t("Unable to load requests")}</strong><p className="error-text">{st.message}</p><Button size="small" onClick={() => void store.loadPullRequests()}>{t("Retry")}</Button></div>}
      {loading && !store.pullRequests.length && <div className="pr-list-state" role="status"><Spinner size={18}/><span>{t("Loading…")}</span></div>}
      {st.kind === "loaded" && !store.pullRequests.length && <div className="pr-list-state"><GitPullRequest size={26}/><strong>{t("No requests found")}</strong><p>{store.requestQuery.search ? t("Try another search or filter.") : t("No requests in {0}.", scopeTitle(store.requestQuery.scope))}</p></div>}
      <div className="pr-list-rows">
        {store.pullRequests.map((pr) => {
          const selected = store.selection?.kind === "pullRequest" && store.selection.number === pr.number;
          const pipeline = pr.headSHA ? store.ci.bySha.get(pr.headSHA) : undefined;
          return <button type="button" key={pr.number} className={`pr-list-row ${selected ? "selected" : ""}`} aria-pressed={selected} onClick={() => store.select({ kind: "pullRequest", number: pr.number })} onContextMenu={(e) => showContextMenu(e, [
            { label: t("Check out branch"), onClick: () => void store.checkoutPullRequest(pr) },
            { label: t("Open in browser"), onClick: () => store.openUrl(pr.url) },
            { label: t("Copy link"), onClick: () => store.copy(pr.url) },
          ])}>
            <GitPullRequest size={16} className={pr.isDraft ? "muted" : "pr-list-icon"}/>
            <span className="pr-list-row-body">
              <span className="pr-list-row-top"><span>#{pr.number}</span>{pr.isDraft && <span className="pr-draft-badge">{t("Draft")}</span>}{pipeline && <span className="pr-row-ci" title={`CI: ${statusInfo[pipeline.status].title}`}><CIStatusIcon status={pipeline.status} size={12}/></span>}</span>
              <strong className="pr-list-title">{pr.title}</strong>
              <span className="pr-list-author"><span className="ellipsis">@{pr.author}</span>{pr.updated && <time>{shortDate(pr.updated)}</time>}</span>
              <span className="pr-list-branch" title={`${pr.source} → ${pr.target}`}><GitBranch size={11}/><span className="ellipsis">{pr.source} → {pr.target}</span></span>
            </span>
          </button>;
        })}
      </div>
      {store.requestsMore && <div className="pr-list-more"><Button size="small" block disabled={loading} onClick={() => void store.loadPullRequests(true)}>{loading ? <Spinner size={12}/> : t("Load more")}</Button></div>}
    </Section>
  );
}
