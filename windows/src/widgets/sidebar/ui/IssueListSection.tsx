import { useEffect } from "react";
import { Plus, SquareArrowOutUpRight } from "@/shared/icons";
import { accounts, type IssueScope, workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { FailureRow, IconButton, showContextMenu, Spinner } from "@/shared/ui";
import { ListFilterCaption } from "./ListSearchRow";
import { Section } from "./Section";

/**
 * The repository's issues in the repository sidebar: a row opens the Issues page, which has the search, the filters and
 * its own rows (IssuesWorkspace). The list itself lives in the store, so both show the same items.
 * (macOS: IssueListSection.swift)
 */
export function IssueListSection({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  useObserve(accounts);
  const key = store.issueContextKey;
  useEffect(() => { void store.prepareIssues(); }, [store, key]);
  const st = store.issueState;
  const filters: { value: IssueScope; title: string }[] = [{ value: "open", title: workStateTitle("open") }, { value: "closed", title: workStateTitle("closed") }, { value: "all", title: t("All") }, { value: "assigned", title: t("Assigned to you") }];
  const openPage = t("Open in Issues");
  return (
    <Section
      id="issues"
      title={t("Issues")}
      count={st.kind === "loaded" ? store.issues.length : undefined}
      actions={
        <>
          {st.kind === "loading" && store.issues.length > 0 && <Spinner size={11} />}
          {/* the sidebar keeps two icons; refreshing and searching belong to the page */}
          <IconButton small icon={<SquareArrowOutUpRight size={12} />} tip={openPage} aria-label={openPage} onClick={() => store.navigate("issues")} />
          <IconButton small icon={<Plus size={13} />} tip={t("New issue")} aria-label={t("New issue")} disabled={!store.hostingAccount} onClick={() => store.openSheet({ kind: "issueEditor", title: "", body: "" })} />
        </>
      }
    >
      {(store.issueScope !== "open" || store.issueLoadedSearch.trim()) && <ListFilterCaption
        state={filters.find((f) => f.value === store.issueScope)?.title ?? store.issueScope}
        search={store.issueLoadedSearch.trim()}
        onClear={() => void store.filterIssues("open", "")}
      />}
      <div style={{ padding: "0 6px" }}>
        {st.kind === "needsAccount" && !store.hostingAccount && <button className="link" onClick={openSettings}>{t("Connect account…")}</button>}
        {st.kind === "needsAccount" && store.hostingAccount && <FailureRow title={t("Couldn't read the saved account credentials")} caption={t("Unlock your credentials, then retry.")} retry={() => void store.loadIssues()} />}
        {st.kind === "failed" && <FailureRow title={t("Couldn't reach {0}", store.target?.host ?? "")} caption={st.message} retry={() => void store.loadIssues()} />}
        {st.kind === "loading" && !store.issues.length && <Spinner size={12} />}
        {st.kind === "loaded" && !store.issues.length && <div className="muted">{t("No issues match this filter.")}</div>}
      </div>
      {store.issues.map((issue) => (
        <div
          key={issue.id}
          className="side-row"
          data-issue={issue.number}
          style={{ alignItems: "flex-start" }}
          onClick={() => store.openIssue(issue)}
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
