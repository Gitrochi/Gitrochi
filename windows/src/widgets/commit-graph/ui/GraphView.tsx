import { ChevronDown, ChevronUp, CircleDashed, Columns3, ListFilter, Search, X } from "lucide-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { type Commit, emptyStatus, isWIP, type SearchScope, searchScopes, statusFiles, wipWorktree } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { basename, samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, IconButton, type MenuItem, showContextMenu, showMenuBelow, Spinner } from "@/shared/ui";
import { type GraphColumnId, graphColumns, graphWidth, ROW_H } from "../lib/metrics";
import { CommitRow } from "./CommitRow";
import "./commit-graph.css";

export function GraphView({ store }: { store: RepoStore }) {
  useObserve(store);
  useObserve(store.ci);
  useObserve(settings);
  const gw = graphWidth(store.maxLanes);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [viewport, setViewport] = useState({ top: 0, height: 800, width: 1000 });

  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const update = () => setViewport({ top: el.scrollTop, height: el.clientHeight, width: el.clientWidth });
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    el.addEventListener("scroll", update, { passive: true });
    return () => {
      ro.disconnect();
      el.removeEventListener("scroll", update);
    };
  }, []);

  // 선택한 커밋으로 스크롤(가운데)
  useEffect(() => {
    const target = store.scrollTarget;
    const el = scrollRef.current;
    if (!target || !el) return;
    const i = store.commitIndex.get(target);
    store.scrollTarget = null;
    if (i === undefined) return;
    const y = i * ROW_H;
    if (y < el.scrollTop + ROW_H || y > el.scrollTop + el.clientHeight - ROW_H * 2) {
      el.scrollTo({ top: Math.max(0, y - el.clientHeight / 2 + ROW_H / 2), behavior: "smooth" });
    }
  });

  // 좁은 화면에서는 SHA·날짜·작성자 칸을 숨기고 브랜치·그래프 칸을 줄여 커밋 메시지 칸을 지킨다
  const hiddenColumns = settings.get<GraphColumnId[]>("graphHiddenColumns", []);
  const hiddenKey = hiddenColumns.join(",");
  const cols = useMemo(() => graphColumns(viewport.width, gw, new Set(hiddenKey.split(",").filter(Boolean))), [viewport.width, gw, hiddenKey]);
  // the header's menu: which columns show (the message column always does)
  const columnMenu = (): MenuItem[] => {
    const toggle = (id: GraphColumnId) => settings.set("graphHiddenColumns", hiddenColumns.includes(id) ? hiddenColumns.filter((x) => x !== id) : [...hiddenColumns, id]);
    return (
      [
        ["ref", t("Branch / Tag")],
        ["graph", t("Graph")],
        ["time", t("Time")],
      ] as [GraphColumnId, string][]
    ).map(([id, label]) => ({ label, checked: !hiddenColumns.includes(id), onClick: () => toggle(id) }));
  };
  const entries = store.entries;
  const first = Math.max(0, Math.floor(viewport.top / ROW_H) - 10);
  const last = Math.min(entries.length, Math.ceil((viewport.top + viewport.height) / ROW_H) + 10);
  const searching = store.isSearching && (!store.searching || store.searchMatchSet.size > 0);
  const selected = store.selectedID;
  const wipCount = store.wipCount;
  /** Another worktree's row: its branch and number of changed files */
  const worktreeRow = (c: Commit) => {
    const wt = wipWorktree(c);
    if (wt === null) return null;
    const w = store.worktrees.find((x) => samePath(x.path, wt));
    return { label: w?.branch ?? basename(wt), count: statusFiles(store.worktreeStatus[wt] ?? emptyStatus()).length };
  };

  return (
    <div className="col grow" style={{ background: "var(--surface)" }}>
      <SearchBar store={store} />
      <div className="row" style={{ padding: "5px 10px", gap: 10, borderBottom: "1px solid var(--border)" }}>
        <Button size="small" onClick={() => store.openRevisionComparison()}>{t("Compare revisions…")}</Button>
        {!!store.historyTools.selected.length && <>
          <span className="hint">{t("{0} selected", store.historyTools.selected.length)}</span>
          <Button size="small" disabled={!!store.busy} onClick={() => void store.openBatchCommits()}>{t("Selected commits…")}</Button>
          <Button size="small" onClick={() => store.clearGraphSelection()}>{t("Clear selection")}</Button>
        </>}
      </div>
      <div className="graph-header" onContextMenu={(e) => showContextMenu(e, columnMenu())}>
        {cols.ref > 0 && <span style={{ width: cols.ref, paddingLeft: 10 }}>{t("Branch / Tag")}</span>}
        {cols.graph > 0 && <span style={{ width: cols.graph, paddingLeft: 6 }}>{t("Graph")}</span>}
        <span className="grow" style={{ paddingLeft: 20, flex: 1, minWidth: 0 }}>
          {t("Commit message")}
        </span>
        <IconButton small icon={<Columns3 size={13} />} tip={t("Columns")} onClick={(e) => showMenuBelow(e.currentTarget, columnMenu())} />
      </div>
      <div
        ref={scrollRef}
        className="graph-scroll"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === "ArrowUp") {
            store.moveSelection(-1);
            e.preventDefault();
          } else if (e.key === "ArrowDown") {
            store.moveSelection(1);
            e.preventDefault();
          }
        }}
      >
        {entries.length === 0 ? (
          <Empty icon={<CircleDashed size={34} strokeWidth={1.4} />} title={t("No commits yet")} detail={t("Create a file and make your first commit on the right.")} />
        ) : (
          <div style={{ height: entries.length * ROW_H + (store.hasMore ? 56 : 0), position: "relative" }}>
            {entries.slice(first, last).map((e, k) => {
              const i = first + k;
              return (
                <CommitRow
                  key={e.commit.id}
                  store={store}
                  entry={e}
                  top={i * ROW_H}
                  gw={gw}
                  cols={cols}
                  refs={store.refsByCommit.get(e.commit.id)}
                  selected={selected === e.commit.id || store.historyTools.selected.includes(e.commit.id)}
                  isHead={e.commit.id === store.headHash}
                  wipCount={isWIP(e.commit) ? wipCount : worktreeRow(e.commit)?.count ?? 0}
                  wipLabel={worktreeRow(e.commit)?.label}
                  match={!searching ? 0 : store.searchMatchSet.has(e.commit.id) ? 1 : 2}
                  ci={store.ci.bySha.get(e.commit.id)}
                />
              );
            })}
            {store.hasMore && (
              <div style={{ position: "absolute", top: entries.length * ROW_H + 12, left: 0, right: 0, textAlign: "center" }}>
                <Button onClick={() => void store.loadMore()}>{t("Load more commits")}</Button>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function SearchBar({ store }: { store: RepoStore }) {
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (store.searchFocusRequest) {
      input.current?.focus();
      input.current?.select();
    }
  }, [store.searchFocusRequest]);
  const scope = searchScopes.find((s) => s.id === store.searchScope)!;
  let result = "";
  if (store.isSearching) {
    if (!store.searchMatches.length) result = store.searching ? t("Searching…") : t("No results");
    else {
      result = `${store.searchPosition ?? "–"}/${store.searchMatches.length}`;
      if (store.searchUnloaded > 0) result += t(" · {0} outside the graph", store.searchUnloaded);
    }
  }
  return (
    <div className="searchbar">
      <div className="search-field">
        <Search size={14} className="muted" />
        <input
          ref={input}
          value={store.searchText}
          placeholder={scope.prompt}
          spellCheck={false}
          onChange={(e) => store.setSearch(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              if (e.shiftKey) store.previousMatch();
              else store.nextMatch();
            } else if (e.key === "Escape") {
              store.clearSearch();
              input.current?.blur();
            }
          }}
        />
        {store.searching && <Spinner size={12} />}
        {store.searchText && (
          <button className="icon-btn small" data-tip={t("Clear search (Esc)")} onClick={() => store.clearSearch()}>
            <X size={13} />
          </button>
        )}
      </div>
      <select
        className="select"
        style={{ width: 110, height: 28, padding: "0 6px", flex: "none" }}
        value={store.searchScope}
        data-tip={t("Search in")}
        onChange={(e) => store.setSearch(store.searchText, e.target.value as SearchScope)}
      >
        {searchScopes.map((s) => (
          <option key={s.id} value={s.id}>
            {s.title}
          </option>
        ))}
      </select>
      <GraphFilterButton store={store} />
      {store.isSearching && (
        <>
          <span className="muted" style={{ fontSize: 12, whiteSpace: "nowrap", fontVariantNumeric: "tabular-nums" }}>
            {result}
          </span>
          <div className="tool-group">
            <button className="tool" disabled={!store.searchMatches.length} data-tip={t("Previous result (Shift+Enter · Shift+F3)")} onClick={() => store.previousMatch()}>
              <ChevronUp size={15} />
            </button>
            <button className="tool" disabled={!store.searchMatches.length} data-tip={t("Next result (Enter · F3)")} onClick={() => store.nextMatch()}>
              <ChevronDown size={15} />
            </button>
          </div>
          {store.searchUnloaded > 0 && store.hasMore && (
            <Button size="small" onClick={() => void store.loadMoreForSearch()}>
              {t("Load more and search")}</Button>
          )}
        </>
      )}
    </div>
  );
}

/** 그래프 거르기: 현재 브랜치만 보기, 숨긴 브랜치 다시 보이기 */
function GraphFilterButton({ store }: { store: RepoStore }) {
  const hidden = store.hiddenRefs.size;
  const active = store.graphCurrentOnly || hidden > 0;
  return (
    <button
      type="button"
      className={`tool ${active ? "on" : ""}`}
      style={{ gap: 4, color: active ? "var(--accent)" : undefined }}
      aria-label={t("Filter graph")}
      data-tip={t("Filter graph|Show only the current branch, show hidden branches again (hide them by right-clicking in the sidebar)")}
      onClick={(e) =>
        showMenuBelow(e.currentTarget, [
          { label: t("Show only the current branch"), checked: store.graphCurrentOnly, onClick: () => void store.setCurrentOnly(!store.graphCurrentOnly) },
          "divider",
          { label: hidden ? t("Show all {0} hidden branches", hidden) : t("No hidden branches"), disabled: !hidden, onClick: () => void store.showAllBranches() },
        ])
      }
    >
      <ListFilter size={15} />
      {store.graphCurrentOnly ? <span style={{ fontSize: 11.5 }}>{t("Current branch only")}</span> : hidden > 0 ? <span style={{ fontSize: 11.5 }}>{t("Hidden {0}", hidden)}</span> : null}
    </button>
  );
}
