import { useEffect } from "react";
import { Plus, RefreshCw, SquareArrowOutUpRight } from "lucide-react";
import { accounts, type IssueScope, workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { IconButton, showContextMenu, Spinner } from "@/shared/ui";
import { ListFilterCaption, ListSearchRow } from "./ListSearchRow";
import { Section } from "./Section";

/**
 * The repository's issues: in the repository sidebar (a row opens the Issues page), and as the list of the
 * Issues page (onPage). The list itself lives in the store, so both show the same items. (macOS: IssueListSection.swift)
 */
export function IssueListSection({ store, openSettings, onPage = false }: { store: RepoStore; openSettings: () => void; onPage?: boolean }) {
  useObserve(store);
  useObserve(accounts);
  const key = store.issueContextKey;
  useEffect(() => { void store.prepareIssues(); }, [store, key]);
  const st = store.issueState;
  const filters: { value: IssueScope; title: string }[] = [{ value: "open", title: workStateTitle("open") }, { value: "closed", title: workStateTitle("closed") }, { value: "all", title: t("All") }];
  const openPage = t("Open in Issues");
  const selected = store.inboxDetail?.item.kind === "issue" ? store.inboxDetail.item.id : null;
  return (
    <Section
      id="issues"
      title={t("Issues")}
      count={st.kind === "loaded" ? store.issues.length : undefined}
      collapsible={!onPage}
      actions={
        <>
          {st.kind === "loading" && store.issues.length > 0 && <Spinner size={11} />}
          {/* the sidebar keeps two icons; refreshing and searching belong to the page */}
          {onPage ? <IconButton small icon={<RefreshCw size={12} />} tip={t("Refresh list")} aria-label={t("Refresh list")} onClick={() => void store.loadIssues()} />
            : <IconButton small icon={<SquareArrowOutUpRight size={12} />} tip={openPage} aria-label={openPage} onClick={() => store.navigate("issues")} />}
          <IconButton small icon={<Plus size={13} />} tip={t("New issue")} aria-label={t("New issue")} disabled={!store.hostingAccount} onClick={() => store.openSheet({ kind: "issueEditor", title: "", body: "" })} />
        </>
      }
    >
      {onPage ? <ListSearchRow
        prompt={t("Search issues")}
        text={store.issueSearch}
        onText={(text) => { store.issueSearch = text; store.changed(); }}
        filters={filters}
        selection={store.issueScope}
        defaultFilter="open"
        onSearch={(text) => void store.filterIssues(store.issueScope, text)}
        onFilter={(value) => void store.filterIssues(value)}
      /> : (store.issueScope !== "open" || store.issueLoadedSearch.trim()) && <ListFilterCaption
        state={filters.find((f) => f.value === store.issueScope)?.title ?? store.issueScope}
        search={store.issueLoadedSearch.trim()}
        onClear={() => void store.filterIssues("open", "")}
      />}
      <div style={{ padding: "0 6px" }}>
        {st.kind === "needsAccount" && <button className="link" onClick={openSettings}>{t("Connect account…")}</button>}
        {st.kind === "failed" && <div className="error-text selectable" style={{ fontSize: 11.5 }}>{st.message}</div>}
        {st.kind === "loading" && !store.issues.length && <Spinner size={12} />}
        {st.kind === "loaded" && !store.issues.length && <div className="muted">{t("No issues match this filter.")}</div>}
      </div>
      {store.issues.map((issue) => (
        <div
          key={issue.id}
          className="side-row"
          data-issue={issue.number}
          style={{ alignItems: "flex-start", background: onPage && selected === issue.id ? "var(--select)" : undefined }}
          onClick={() => (onPage ? void store.openInboxItem(issue) : store.openIssue(issue))}
          onContextMenu={(e) =>
            showContextMenu(e, [
              { label: t("Open in browser"), onClick: () => store.openUrl(issue.url) },
              { label: t("Copy link"), onClick: () => store.copy(issue.url) },
            ])
          }
        >
          <span className="col grow">
            <span className="row">
              <span className="muted" style={{ fontVariantNumeric: "tabular-nums" }}>#{issue.number}</span>
              <span className="ellipsis">{issue.title}</span>
            </span>
            <span className="side-sub ellipsis">{workStateTitle(issue.state)} · @{issue.author}</span>
          </span>
        </div>
      ))}
      {store.issuesMore && <button className="link" disabled={st.kind === "loading"} onClick={() => void store.loadIssues(true)}>{t("Load more")}</button>}
    </Section>
  );
}
