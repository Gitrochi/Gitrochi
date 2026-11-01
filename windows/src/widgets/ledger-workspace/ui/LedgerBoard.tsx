import { Archive, CircleCheck, Clock, X } from "lucide-react";
import { type CSSProperties, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { filterSessions, type LedgerStore, stepIndex, streamCount, verdictCounts, verdictLook, visibleRows } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Checkbox, Empty } from "@/shared/ui";
import { BaseLine, onScreen, SessionId, typing, VerdictBadge, verdictIcon, When } from "./parts";

const ROW = 34;
const HOUR = 3_600_000;

/**
 * Every session of the project as a dense list: verdict chips with counts, multi-select with Shift and Ctrl (Space
 * from the keyboard) and a bar of bulk actions that undo as one. Streams are listed under Streams instead.
 * Windowed, so a thousand sessions scroll as smoothly as ten. (macOS: Views/Ledger/LedgerBoard.swift)
 */
export function LedgerBoard({ store, onOpen }: { store: LedgerStore; onOpen: (sessionId: string) => void }) {
  useObserve(store);
  const state = store.state!;
  const project = store.project;
  const rows = useMemo(
    () => filterSessions(state.sessions, { project, verdicts: store.verdicts, text: store.filterText, showArchived: store.showArchived }),
    [state, project, store.verdicts, store.verdicts.size, store.filterText, store.showArchived],
  );
  const counts = useMemo(() => verdictCounts(state.sessions, project), [state, project]);
  const streams = streamCount(state.sessions, project);
  const scroll = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ top: 0, height: 600 });
  const [active, setActive] = useState(-1);
  const anchor = useRef(-1);
  useLayoutEffect(() => {
    const el = scroll.current;
    if (!el) return;
    const measure = () => setView({ top: el.scrollTop, height: el.clientHeight });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const { first, last } = visibleRows(view.top, view.height, rows.length, ROW, 8);

  const click = (index: number, e: React.MouseEvent) => {
    const id = rows[index].id;
    setActive(index);
    if (e.shiftKey && anchor.current >= 0) {
      const [a, b] = [Math.min(anchor.current, index), Math.max(anchor.current, index)];
      store.setChecked([...store.checked, ...rows.slice(a, b + 1).map((s) => s.id)]);
    } else if (e.ctrlKey || e.metaKey) {
      store.toggleChecked(id);
      anchor.current = index;
    } else {
      anchor.current = index;
      onOpen(id);
    }
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || typing(e) || !rows.length || !onScreen(scroll.current)) return;
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const next = stepIndex(active, e.key === "ArrowDown" ? 1 : -1, rows.length);
        setActive(next);
        const el = scroll.current;
        if (el && (next * ROW < el.scrollTop || (next + 1) * ROW > el.scrollTop + el.clientHeight)) el.scrollTop = Math.max(0, next * ROW - el.clientHeight / 2);
      } else if (e.key === " " && rows[active] && !(e.target as HTMLElement).closest?.("button")) {
        e.preventDefault();
        store.toggleChecked(rows[active].id);
      } else if (e.key === "Enter" && rows[active] && !(e.target as HTMLElement).closest?.("button")) {
        e.preventDefault();
        onOpen(rows[active].id);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const checked = rows.filter((s) => store.checked.has(s.id)).map((s) => s.id);
  const all = rows.length > 0 && checked.length === rows.length;
  const busy = store.busy > 0;
  return (
    <div className="ledger-board">
      <div className="ledger-board-bar" role="toolbar" aria-label={t("Verdicts")}>
        {counts.filter((c) => c.count || store.verdicts.has(c.verdict)).map(({ verdict, count }) => {
          const look = verdictLook(verdict), Icon = verdictIcon(verdict), on = store.verdicts.has(verdict);
          return (
            <button key={verdict} type="button" className={`ledger-chip${on ? " on" : ""}`} aria-pressed={on} style={{ "--verdict": `var(${look.color})` } as CSSProperties} onClick={(e) => store.toggleVerdict(verdict, !(e.ctrlKey || e.metaKey))} data-tip={`${t(look.label)}|${t("Click to show only these; Ctrl+click to add them.")}`}>
              <Icon size={12} />
              {t(look.label)}
              <span className="count">{count}</span>
            </button>
          );
        })}
        {store.verdicts.size > 0 && <Button size="small" onClick={() => { store.verdicts.clear(); store.changed(); }}>{t("Show all")}</Button>}
        <span className="spacer" />
        <Checkbox checked={store.showArchived} onChange={(on) => { store.showArchived = on; store.changed(); }} label={t("Show cleaned up")} />
      </div>
      {checked.length > 0 && (
        <div className="ledger-bulk" role="toolbar" aria-label={t("Selected sessions")}>
          <strong>{t("{0} selected", checked.length)}</strong>
          <Button size="small" disabled={busy} onClick={() => void store.bulk("ack", checked)}><CircleCheck size={13} />{t("Confirm")}</Button>
          <Button size="small" disabled={busy} onClick={() => void store.bulk("archive", checked)}><Archive size={13} />{t("Clean up")}</Button>
          <Button size="small" disabled={busy} onClick={() => void store.bulk("snooze", checked, { until: Date.now() + 72 * HOUR })}><Clock size={13} />{t("Still active")}</Button>
          <Button size="small" disabled={busy} onClick={() => void store.bulk("set_status", checked, { status: "closed" })}>{t("Mark closed")}</Button>
          <span className="spacer" />
          <Button size="small" onClick={() => store.setChecked([])}><X size={13} />{t("Clear selection")}</Button>
        </div>
      )}
      {streams > 0 && <div className="ledger-note">{streams === 1 ? t("1 stream is listed under Streams, not here.") : t("{0} streams are listed under Streams, not here.", streams)}</div>}
      <div className="ledger-table-head" role="row">
        <input type="checkbox" className="ledger-check" checked={all} aria-label={t("Select all")} data-tip={t("Select all")} onChange={(e) => store.setChecked(e.target.checked ? rows.map((s) => s.id) : [])} />
        <span>{t("Session")}</span>
        <span>{t("Title")}</span>
        <span className="ledger-wide-only">{t("Baseline")}</span>
        <span>{t("Verdict")}</span>
        <span className="ledger-wide-only">{t("Kind")}</span>
        <span>{t("Last report")}</span>
      </div>
      <div className="ledger-table-scroll" ref={scroll} role="grid" aria-rowcount={rows.length} aria-label={t("Sessions")} onScroll={(e) => setView({ top: e.currentTarget.scrollTop, height: e.currentTarget.clientHeight })}>
        {!rows.length ? (
          <Empty title={t("No sessions match")} detail={t("Change the verdict chips, the filter or the project.")} />
        ) : (
          <div style={{ height: rows.length * ROW, position: "relative" }}>
            {rows.slice(first, last).map((s, i) => {
              const index = first + i;
              return (
                <div key={s.id} role="row" aria-rowindex={index + 1} data-session={s.id} className={`ledger-table-row${store.checked.has(s.id) ? " checked" : ""}${index === active ? " active" : ""}${s.id === store.selectedId ? " selected" : ""}`} style={{ top: index * ROW }} onClick={(e) => { if (!(e.target as HTMLElement).closest("input")) click(index, e); }}>
                  <input type="checkbox" className="ledger-check" checked={store.checked.has(s.id)} aria-label={t("Select {0}", s.id)} onChange={(e) => { store.toggleChecked(s.id, e.target.checked); anchor.current = index; }} />
                  <SessionId session={s} />
                  <span className="ledger-cell" title={s.title}>{s.title}</span>
                  <span className="ledger-wide-only ledger-cell"><BaseLine session={s} /></span>
                  <span className="ledger-cell"><VerdictBadge verdict={s.verdict} /></span>
                  <span className="ledger-wide-only ledger-cell muted">{s.kind}</span>
                  <span className="ledger-cell"><When at={s.lastAt} /></span>
                </div>
              );
            })}
          </div>
        )}
        {state.hiddenBefore > 0 && store.range !== "all" && (
          <div className="ledger-graph-foot">
            {t("{0} quiet sessions older than this period are hidden.", state.hiddenBefore)}
            <Button size="small" onClick={() => store.setRange(store.range === "7d" ? "30d" : "all")}>{store.range === "7d" ? t("Show 30 days") : t("Show all")}</Button>
          </div>
        )}
      </div>
    </div>
  );
}
