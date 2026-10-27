import { ChevronDown, ChevronUp, CircleDashed, Columns3, ListFilter, Search, X } from "lucide-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { type Commit, emptyStatus, isWIP, type SearchScope, searchScopes, statusFiles, wipWorktree } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { basename, samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, IconButton, type MenuItem, showContextMenu, showMenuBelow, Spinner } from "@/shared/ui";
import { AUTHOR_W, clampLaneOffset, type GraphColumnId, graphColumns, graphFullWidth, graphWidth, laneOffsetForThumb, laneThumb, type OptionalColumnId, revealLaneOffset, ROW_H, TIME_W, toggleColumn } from "../lib/metrics";
import { CommitRow } from "./CommitRow";
import "./commit-graph.css";

export function GraphView({ store }: { store: RepoStore }) {
  useObserve(store);
  useObserve(store.ci);
  useObserve(settings);
  const gw = graphWidth(store.maxLanes);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [viewport, setViewport] = useState({ top: 0, height: 800, width: 1000, scrollbar: 0 });

  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    // the list's vertical scrollbar narrows the rows but not the header; the header pads by it so columns line up
    const update = () => setViewport({ top: el.scrollTop, height: el.clientHeight, width: el.clientWidth, scrollbar: el.offsetWidth - el.clientWidth });
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

  // the columns turned off, and the optional author and time turned on (a separate list, so both stay off by default);
  // narrow windows drop time and author before the branch and graph columns shrink
  const hiddenColumns = settings.get<GraphColumnId[]>("graphHiddenColumns", []);
  const shownColumns = settings.get<OptionalColumnId[]>("graphShownColumns", []);
  const hiddenKey = hiddenColumns.join(","), shownKey = shownColumns.join(",");
  const cols = useMemo(
    () => graphColumns(viewport.width, gw, new Set(hiddenKey.split(",").filter(Boolean)), new Set(shownKey.split(",").filter(Boolean))),
    [viewport.width, gw, hiddenKey, shownKey],
  );
  // lanes beyond the column scroll sideways, all rows together, with one offset clamped to what does not fit
  const fullWidth = graphFullWidth(store.maxLanes);
  const laneOverflow = cols.graph > 0 ? Math.max(0, fullWidth - cols.graph) : 0;
  const [laneOffsetState, setLaneOffset] = useState(0);
  const laneOffset = clampLaneOffset(laneOffsetState, laneOverflow);
  useEffect(() => { if (laneOffset !== laneOffsetState) setLaneOffset(laneOffset); }, [laneOffset, laneOffsetState]);
  const laneOffsetRef = useRef(laneOffset);
  laneOffsetRef.current = laneOffset;
  // a newly selected commit whose node is outside the visible lanes scrolls them into view
  useEffect(() => {
    const id = store.selectedID, i = id ? store.commitIndex.get(id) : undefined, entry = i === undefined ? undefined : store.entries[i];
    if (!entry || laneOverflow <= 0) return;
    const next = revealLaneOffset(laneOffsetRef.current, entry.row.column, cols.graph, laneOverflow);
    if (next !== laneOffsetRef.current) setLaneOffset(next);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [store.selectedID]);
  // the header's menu: which columns show (the message column always does)
  const columnMenu = (): MenuItem[] => [
    ...([
      ["ref", t("Branch / Tag")],
      ["graph", t("Graph")],
    ] as [GraphColumnId, string][]).map(([id, label]) => ({ label, checked: !hiddenColumns.includes(id), onClick: () => settings.set("graphHiddenColumns", toggleColumn(hiddenColumns, id)) })),
    "divider",
    ...([
      ["author", t("Author")],
      ["time", t("Time")],
    ] as [OptionalColumnId, string][]).map(([id, label]) => ({ label, checked: shownColumns.includes(id), onClick: () => settings.set("graphShownColumns", toggleColumn(shownColumns, id)) })),
  ];
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
      {(store.showSearchBar || store.isSearching) && <SearchBar store={store} />}
      <div className="graph-header" style={{ paddingRight: 12 + viewport.scrollbar }} onContextMenu={(e) => showContextMenu(e, columnMenu())}>
        {cols.ref > 0 && <span style={{ width: cols.ref, paddingLeft: 10 }}>{t("Branch / Tag")}</span>}
        {cols.graph > 0 && <LaneHeader width={cols.graph} total={fullWidth} offset={laneOffset} onOffset={(value) => setLaneOffset(clampLaneOffset(value, laneOverflow))} />}
        <span className="graph-head-message">
          <span className="graph-head-label">{t("Commit message")}</span>
          {/* the filter is not part of searching, so it stays here while the search bar is hidden; next to the label, it leaves the right end to the column labels */}
          <GraphFilterButton store={store} />
          <IconButton small icon={<Columns3 size={13} />} tip={t("Columns")} aria-label={t("Columns")} onClick={(e) => showMenuBelow(e.currentTarget, columnMenu())} />
        </span>
        {cols.author && <span className="head-author" style={{ width: AUTHOR_W }}>{t("Author")}</span>}
        {cols.time && <span className="head-time" style={{ width: TIME_W }}>{t("Time")}</span>}
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
                  gw={fullWidth}
                  laneOffset={laneOffset}
                  cols={cols}
                  refs={store.refsByCommit.get(e.commit.id)}
                  selected={selected === e.commit.id}
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

/**
 * The graph column's header cell. When the lanes are wider than the column it carries a thin scrollbar
 * (thumb sized visible/total); dragging it, or scrolling sideways or with Shift+wheel over the cell, moves every row's lanes.
 */
function LaneHeader({ width, total, offset, onOffset }: { width: number; total: number; offset: number; onOffset: (offset: number) => void }) {
  const cell = useRef<HTMLSpanElement>(null);
  const latest = useRef({ offset, onOffset });
  latest.current = { offset, onOffset };
  const overflow = Math.max(0, total - width);
  // a native listener: React's wheel handlers are passive and could not keep the page from scrolling
  useEffect(() => {
    const el = cell.current;
    if (!el) return;
    const wheel = (e: WheelEvent) => {
      const delta = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.shiftKey ? e.deltaY : 0;
      if (!delta) return;
      e.preventDefault();
      latest.current.onOffset(latest.current.offset + delta);
    };
    el.addEventListener("wheel", wheel, { passive: false });
    return () => el.removeEventListener("wheel", wheel);
  }, []);
  const track = Math.max(0, width - 12);
  const thumb = laneThumb(offset, width, total, track);
  const dragFrom = (e: React.PointerEvent<HTMLElement>, start: number) => {
    e.preventDefault();
    e.stopPropagation();
    const target = e.currentTarget, x0 = e.clientX;
    target.setPointerCapture(e.pointerId);
    const move = (ev: PointerEvent) => latest.current.onOffset(laneOffsetForThumb(start + ev.clientX - x0, track, thumb.size, overflow));
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
      target.removeEventListener("pointercancel", up);
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
    target.addEventListener("pointercancel", up);
  };
  return (
    <span ref={cell} className="graph-head-cell" style={{ width }}>
      <span className="graph-head-label">{t("Graph")}</span>
      {overflow > 0 && (
        <span
          className="lane-scrollbar"
          role="scrollbar"
          aria-orientation="horizontal"
          aria-label={t("Graph lanes")}
          aria-valuemin={0}
          aria-valuemax={overflow}
          aria-valuenow={offset}
          data-tip={t("Drag, or scroll sideways or with Shift+wheel here, to see more lanes")}
          // a click on the track centres the thumb there and keeps dragging from that point
          onPointerDown={(e) => {
            const start = e.clientX - e.currentTarget.getBoundingClientRect().left - thumb.size / 2;
            onOffset(laneOffsetForThumb(start, track, thumb.size, overflow));
            dragFrom(e, Math.min(Math.max(0, start), track - thumb.size));
          }}
        >
          <span className="lane-scrollbar-thumb" style={{ width: thumb.size, left: thumb.start }} onPointerDown={(e) => dragFrom(e, thumb.start)} />
        </span>
      )}
    </span>
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
              e.preventDefault();
              store.closeSearchBar();
            }
          }}
        />
        {store.searching && <Spinner size={12} />}
        {store.searchText && (
          <button className="icon-btn small" aria-label={t("Clear search")} data-tip={t("Clear search")} onClick={() => store.clearSearch()}>
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
      <span className="spacer" />
      <IconButton small icon={<X size={14} />} className="search-close" aria-label={t("Close search")} tip={t("Close search (Esc)")} onClick={() => store.closeSearchBar()} />
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
      className={`tool graph-filter ${active ? "on" : ""}`}
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
      <ListFilter size={13} />
      {store.graphCurrentOnly ? <span style={{ fontSize: 11.5 }}>{t("Current branch only")}</span> : hidden > 0 ? <span style={{ fontSize: 11.5 }}>{t("Hidden {0}", hidden)}</span> : null}
    </button>
  );
}
