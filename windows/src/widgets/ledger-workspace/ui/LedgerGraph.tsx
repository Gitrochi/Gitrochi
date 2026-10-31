import { CircleHelp } from "lucide-react";
import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { GRAPH_ROW_H, type LedgerGraphNode, type LedgerRange, type LedgerSession, type LedgerStore, pathsInBand, type PlacedNode, plotLedgerGraph, visibleRows } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { laneColor, longDate, shortDate, useObserve } from "@/shared/lib";
import { Button, Empty, IconButton, Modal, Segmented } from "@/shared/ui";
import { SessionId, VerdictBadge } from "./parts";

const ranges: { value: LedgerRange; label: string }[] = [{ value: "7d", label: "7 days" }, { value: "30d", label: "30 days" }, { value: "all", label: "All" }];

/** A node in the commit graph's style: baselines are rings on the trunk, releases filled rings, ends squares */
function NodeMark({ p, highlight }: { p: PlacedNode; highlight: boolean }) {
  const color = laneColor(p.node.color), { x, y } = p;
  const ring = highlight ? <circle cx={x} cy={y} r={9} fill="none" stroke={color} strokeWidth={1.5} /> : null;
  switch (p.node.kind) {
    case "baseline":
      return <g>{ring}<circle cx={x} cy={y} r={5.5} fill="var(--surface)" stroke={color} strokeWidth={2} /></g>;
    case "release":
    case "merge":
      return <g>{ring}<circle cx={x} cy={y} r={6} fill="var(--surface)" stroke={color} strokeWidth={2} /><circle cx={x} cy={y} r={3} fill={color} /></g>;
    case "end":
      return <g>{ring}<rect x={x - 4.5} y={y - 4.5} width={9} height={9} rx={1.5} fill={color} /></g>;
    case "start":
      return <g>{ring}<circle cx={x} cy={y} r={5.5} fill="var(--surface)" /><circle cx={x} cy={y} r={4} fill="var(--surface)" stroke={color} strokeWidth={2} /></g>;
    default:
      return <g>{ring}<circle cx={x} cy={y} r={5.5} fill="var(--surface)" /><circle cx={x} cy={y} r={4} fill={color} /></g>;
  }
}

/**
 * Sessions as branches off the baseline trunk, drawn with the commit graph's lanes, colours, line width and row height:
 * a session forks from its base and joins the version it merged into; open sessions continue upward, dashed. Only
 * the rows on screen are drawn. (macOS: Views/Ledger/LedgerGraph.swift)
 */
export function LedgerGraph({ store, onOpen }: { store: LedgerStore; onOpen: (sessionId: string) => void }) {
  useObserve(store);
  const graph = store.graph;
  const plot = useMemo(() => (graph ? plotLedgerGraph(graph) : null), [graph]);
  const scroll = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ top: 0, height: 600 });
  const [hover, setHover] = useState<{ p: PlacedNode; top: number; left: number } | null>(null);
  const [legend, setLegend] = useState(false);
  useLayoutEffect(() => {
    const el = scroll.current;
    if (!el) return;
    const measure = () => setView({ top: el.scrollTop, height: el.clientHeight });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [plot !== null]);
  const state = store.state!;
  const project = store.graphProject;
  const projects = state.projects;
  const hidden = state.hiddenBefore;
  const sessionOf = (n: LedgerGraphNode): LedgerSession | undefined => store.session(n.sessionId ?? (n.version ? state.baselines.find((b) => b.project === project && b.version === n.version)?.bySession : undefined));

  const bar = (
    <div className="ledger-graph-bar">
      <Segmented value={store.range} options={ranges.map((r) => ({ value: r.value, label: t(r.label) }))} onChange={(range) => store.setRange(range)} />
      {!store.project && projects.length > 1 && (
        <select className="select" style={{ width: "auto" }} aria-label={t("Project")} value={project ?? ""} onChange={(e) => store.setProjectChoice(e.target.value)}>
          {projects.map((p) => <option key={p.key} value={p.key}>{p.name}</option>)}
        </select>
      )}
      <span className="spacer" />
      <span className="hint">{plot ? t("{0} rows", plot.nodes.length) : ""}</span>
      <IconButton icon={<CircleHelp size={16} />} tip={t("How to read the graph")} aria-label={t("How to read the graph")} onClick={() => setLegend(true)} />
    </div>
  );
  if (!project) return <div className="ledger-graph">{bar}<Empty title={t("No project yet")} detail={t("The graph appears once an agent reports a session.")} /></div>;
  if (store.graphError) return <div className="ledger-graph">{bar}<Empty title={t("The graph could not be read")} detail={store.graphError} /></div>;
  if (!plot) return <div className="ledger-graph">{bar}</div>;

  const { first, last } = visibleRows(view.top, view.height, plot.nodes.length);
  const top = first * GRAPH_ROW_H, bottom = last * GRAPH_ROW_H;
  const paths = pathsInBand(plot.paths, top, bottom);
  const rows = plot.nodes.slice(first, last);
  const enter = (p: PlacedNode, e: React.MouseEvent) => {
    const box = scroll.current!.getBoundingClientRect();
    setHover({ p, top: p.y + GRAPH_ROW_H / 2 + 6, left: Math.min(Math.max(8, e.clientX - box.left + scroll.current!.scrollLeft - 40), scroll.current!.scrollWidth - 310) });
  };
  const open = (n: LedgerGraphNode) => { const s = sessionOf(n); if (s) onOpen(s.id); };
  const hovered = hover ? sessionOf(hover.p.node) : undefined;
  return (
    <div className="ledger-graph">
      {bar}
      <div className="ledger-graph-scroll" ref={scroll} onScroll={(e) => { setHover(null); setView({ top: e.currentTarget.scrollTop, height: e.currentTarget.clientHeight }); }} onMouseLeave={() => setHover(null)} role="list" aria-label={t("Graph")}>
        {!plot.nodes.length ? (
          <Empty title={t("Nothing in this period")} detail={t("Choose a longer period to see older sessions.")} />
        ) : (
          <div className="ledger-graph-canvas" style={{ height: plot.height, minWidth: plot.width + 320 }}>
            <svg width={plot.width} height={plot.height} aria-hidden>
              {paths.map((p, i) => <path key={i} d={p.d} fill="none" stroke={laneColor(p.color)} strokeWidth={p.kind === "handoff" ? 1.5 : 2} strokeLinecap="round" strokeDasharray={p.dashed ? "3 3" : undefined} opacity={p.kind === "handoff" ? 0.75 : 1} />)}
              {rows.map((p) => <NodeMark key={p.node.id} p={p} highlight={!!p.node.sessionId && p.node.sessionId === store.selectedId} />)}
            </svg>
            {rows.map((p) => {
              const s = sessionOf(p.node), baseline = p.node.lane === 0;
              return (
                <div key={p.node.id} role="listitem" data-node={p.node.id} className={`ledger-graph-row${s && s.id === store.selectedId ? " selected" : ""}`} style={{ top: p.y - GRAPH_ROW_H / 2, left: plot.width }} onMouseEnter={(e) => enter(p, e)} onClick={() => open(p.node)}>
                  {baseline ? <span className="ledger-version">{p.node.version}</span> : s ? <SessionId session={s} /> : null}
                  <span className={`label${baseline ? "" : " quiet"}`}>{baseline ? baselineLabel(store, project, p.node) : p.node.label}</span>
                  <span className="ledger-when" title={longDate(p.node.ts / 1000)}>{shortDate(p.node.ts / 1000)}</span>
                </div>
              );
            })}
            {hover && (
              <div className="ledger-hover-card" style={{ top: hover.top, left: hover.left }} role="tooltip">
                {hovered ? <div className="row"><SessionId session={hovered} /><VerdictBadge verdict={hovered.verdict} /></div> : <span className="ledger-version" style={{ alignSelf: "flex-start" }}>{hover.p.node.version}</span>}
                {hovered && <span className="title">{hovered.title}</span>}
                <span className="muted">{hover.p.node.lane === 0 ? baselineLabel(store, project, hover.p.node) : hover.p.node.label}</span>
                <span className="faint">{longDate(hover.p.node.ts / 1000)}</span>
              </div>
            )}
          </div>
        )}
        {store.range !== "all" && (
          <div className="ledger-graph-foot">
            {hidden > 0 ? t("{0} quiet sessions older than this period are hidden.", hidden) : t("Showing the last {0}.", t(store.range === "7d" ? "7 days" : "30 days"))}
            <Button size="small" onClick={() => store.setRange(store.range === "7d" ? "30d" : "all")}>{store.range === "7d" ? t("Show 30 days") : t("Show all")}</Button>
          </div>
        )}
      </div>
      {legend && <GraphLegend onClose={() => setLegend(false)} />}
    </div>
  );
}

/** A baseline row: who released it, and how far the implementation side has taken it */
function baselineLabel(store: LedgerStore, project: string | null, node: LedgerGraphNode): string {
  const b = store.state?.baselines.find((x) => x.project === project && x.version === node.version);
  if (!b) return "";
  if (!b.bySession) return b.note ?? (b.source === "tag" ? t("Tagged") : b.source === "folder" ? t("Folder") : b.source === "inferred" ? t("Seen in a report") : t("Registered"));
  const cycles = (store.state?.streams ?? []).filter((c) => c.version === b.version);
  const applied = cycles.find((c) => c.appliedAt), synced = cycles.find((c) => c.syncedAt);
  const handoff = applied ? t("applied by {0}", applied.sessionId) : synced ? t("read by {0}", synced.sessionId) : t("waiting for the implementation side");
  return `${t("Released by {0}", b.bySession)} · ${handoff}`;
}

function GraphLegend({ onClose }: { onClose: () => void }) {
  const mark = (kind: LedgerGraphNode["kind"], color = 3) => <svg width={34} height={20}><NodeMark p={{ node: { id: kind, lane: 0, ts: 0, color, kind }, row: 0, x: 17, y: 10 }} highlight={false} /></svg>;
  const line = (dashed: boolean) => <svg width={34} height={20}><path d="M4,10L30,10" stroke={laneColor(3)} strokeWidth={2} strokeLinecap="round" strokeDasharray={dashed ? "3 3" : undefined} /></svg>;
  return (
    <Modal title={t("How to read the graph")} width={460} onClose={onClose} footer={<Button kind="primary" onClick={onClose}>{t("Done")}</Button>}>
      <div className="ledger-legend">
        {mark("baseline", 0)}<span>{t("A baseline on the trunk: a tag, folder or registered version")}</span>
        {mark("release", 0)}<span>{t("A baseline a session released")}</span>
        {mark("start")}<span>{t("A session starts from its baseline")}</span>
        {mark("event")}<span>{t("A report: artifact, question, decision, sync")}</span>
        {mark("end")}<span>{t("Finished without a merge: done, closed, dropped or shelved")}</span>
        {mark("merge")}<span>{t("Merged into a baseline, joining the trunk")}</span>
        {line(true)}<span>{t("Still open, or a hand-off to the implementation side")}</span>
      </div>
      <span className="hint">{t("Each session keeps its colour; rows are newest first. Click a row to open its session.")}</span>
    </Modal>
  );
}
