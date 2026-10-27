import { useEffect, useState } from "react";
import type { RequestScope } from "@/entities/hosting";
import { Plus, RefreshCw, SquareArrowOutUpRight } from "lucide-react";
import { CIStatusIcon, statusInfo } from "@/entities/ci";
import { accountHost, providerInfo, type RepoTarget } from "@/entities/git";
import { accounts, workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { IconButton, type MenuItem, showContextMenu, Spinner } from "@/shared/ui";
import { ListFilterCaption, ListSearchRow } from "./ListSearchRow";
import { Section } from "./Section";

/**
 * The repository's pull/merge requests: in the repository sidebar, and as the list of the Pull requests page (onPage).
 * (macOS: PullRequestSection.swift)
 */
export function PullRequestSection({ store, target, openSettings, onPage = false }: { store: RepoStore; target: RepoTarget; openSettings: () => void; onPage?: boolean }) {
  useObserve(accounts);
  useObserve(store.ci);
  const info = providerInfo[target.provider];
  const gitlab = target.provider === "gitlab";
  const openPage = t(gitlab ? "Open in Merge requests" : "Open in Pull requests");
  // An account on this very host cannot be an alias for it, so only other servers are worth a try.
  const other = accounts.accountsFor(target.provider).find((a) => accountHost(a) !== target.host);
  const st = store.prState;
  const scope = store.requestQuery.scope;
  const [search, setSearch] = useState(store.requestQuery.search);
  useEffect(() => setSearch(store.requestQuery.search), [store.requestQuery.search]);
  const filters: { value: RequestScope; title: string }[] = [
    { value: "open", title: workStateTitle("open") }, { value: "closed", title: workStateTitle("closed") }, { value: "merged", title: workStateTitle("merged") },
    { value: "mine", title: t("Created by me") }, { value: "reviewRequested", title: t("Review requested") },
  ];
  return (
    <Section
      id="prs"
      title={t(gitlab ? "Merge requests" : "Pull requests")}
      count={st.kind === "loaded" ? store.pullRequests.length : undefined}
      collapsible={!onPage}
      actions={
        <>
          {st.kind === "loading" && store.pullRequests.length > 0 && <Spinner size={11} />}
          {/* the sidebar keeps two icons; refreshing and searching belong to the page */}
          {onPage ? <IconButton small icon={<RefreshCw size={12} />} tip={t("Refresh list")} aria-label={t("Refresh list")} onClick={() => void store.loadPullRequests()} />
            : <IconButton small icon={<SquareArrowOutUpRight size={12} />} tip={openPage} aria-label={openPage} onClick={() => store.navigate("pullRequests")} />}
          <IconButton
            small
            icon={<Plus size={13} />}
            tip={t("New {0} from the current branch", info.requestShort)}
            disabled={!store.headBranch}
            onClick={() => {
              store.sheet = { kind: "createPullRequest" };
              store.changed();
            }}
          />
        </>
      }
    >
      {onPage ? <ListSearchRow
        prompt={t(gitlab ? "Search merge requests" : "Search pull requests")}
        text={search}
        onText={setSearch}
        filters={filters}
        selection={scope}
        defaultFilter="open"
        onSearch={(text) => void store.filterPullRequests(scope, text)}
        onFilter={(value) => void store.filterPullRequests(value, search)}
      /> : (scope !== "open" || store.requestQuery.search.trim()) && <ListFilterCaption
        state={filters.find((f) => f.value === scope)?.title ?? scope}
        search={store.requestQuery.search.trim()}
        onClear={() => { setSearch(""); void store.filterPullRequests("open", ""); }}
      />}
      <div style={{ padding: "0 6px" }}>
        {store.requestsWarning && <span className="muted">{store.requestsWarning}</span>}
        {st.kind === "needsAccount" && (
          <div className="col" style={{ gap: 4, alignItems: "flex-start", padding: "2px 0 4px" }}>
            {other && (
              <button className="link" onClick={() => void store.tryExistingAccounts()} data-tip={t("If the same server is used under another address, an account you've already connected works there too")}>
                {t("Try with the connected account (@{0})", other.username)}</button>
            )}
            <button className="link" onClick={openSettings}>
              {gitlab ? t("Connect a self-hosted GitLab ({0}) account…", target.host) : t("Connect a GitHub account…")}
            </button>
          </div>
        )}
        {st.kind === "failed" && (
          <div className="error-text" style={{ fontSize: 11.5 }}>
            {st.message}
          </div>
        )}
        {st.kind === "loading" && !store.pullRequests.length && <Spinner size={12} />}
        {st.kind === "loaded" && !store.pullRequests.length && <div className="muted">{t(gitlab ? "No merge requests match this filter." : "No pull requests match this filter.")}</div>}
      </div>
      {store.pullRequests.map((pr) => (
        <div
          key={pr.number}
          className="side-row"
          data-request={pr.number}
          style={{ alignItems: "flex-start", background: store.selection?.kind === "pullRequest" && store.selection.number === pr.number ? "var(--select)" : undefined }}
          onClick={() => store.select({ kind: "pullRequest", number: pr.number })}
          onContextMenu={(e) =>
            showContextMenu(e, [
              ...(onPage ? [] : [{ label: openPage, onClick: () => { store.navigate("pullRequests"); store.select({ kind: "pullRequest", number: pr.number }); } }, "divider"] as MenuItem[]),
              { label: t("Check out branch"), onClick: () => void store.checkoutPullRequest(pr) },
              { label: t("Open in browser"), onClick: () => store.openUrl(pr.url) },
              { label: t("Copy link"), onClick: () => store.copy(pr.url) },
            ])
          }
        >
          <span className="col grow">
            <span className="row">
              <span className="muted" style={{ fontVariantNumeric: "tabular-nums" }}>
                #{pr.number}
              </span>
              <span className="ellipsis">{pr.title}</span>
              {pr.headSHA && store.ci.bySha.get(pr.headSHA) && (
                <span className="ci-badge" data-tip={`CI: ${statusInfo[store.ci.bySha.get(pr.headSHA)!.status].title} · #${store.ci.bySha.get(pr.headSHA)!.number}`}>
                  <CIStatusIcon status={store.ci.bySha.get(pr.headSHA)!.status} size={11} />
                </span>
              )}
            </span>
            <span className="row side-sub">
              {pr.isDraft && <span style={{ color: "var(--orange)", fontWeight: 600 }}>{t("Draft")}</span>}
              <span className="ellipsis">
                {pr.source} → {pr.target}
              </span>
            </span>
          </span>
        </div>
      ))}
      {store.requestsMore && <button className="link" disabled={st.kind === "loading"} onClick={() => void store.loadPullRequests(true)}>{t("Load more")}</button>}
    </Section>
  );
}
