import { Clock3, Hand, Maximize, Minus, Plus, RotateCcw, Workflow } from "lucide-react";
import { type PointerEvent, useEffect, useId, useMemo, useRef, useState } from "react";
import { fitFlowGraph, flowZoomAnchor, formatDuration, layoutFlowGraph } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { IconButton } from "@/shared/ui";
import { FlowBlockIcon, FlowStatePill, flowBlockKind, flowStateTone } from "./FlowState";

interface GraphNode {
  id: string;
  title?: string | null;
  block: string;
  needs: string[];
  run?: string | null;
  state?: string;
  decision?: string;
  durationMs?: number | null;
}

/** A scrollable dependency canvas shared by plans, live runs and saved runs. */
export function FlowGraph({ nodes, selected, onSelect, fitOnMount = false }: { nodes: GraphNode[]; selected: string | null; onSelect: (id: string) => void; fitOnMount?: boolean }) {
  const graph = useMemo(() => layoutFlowGraph(nodes), [nodes]);
  const [zoom, setZoom] = useState(1);
  const zoomRef = useRef(1);
  const [moved, setMoved] = useState<Record<string, { x: number; y: number }>>({});
  const [panning, setPanning] = useState(false);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const panRef = useRef({ x: 0, y: 0 });
  const gesture = useRef<{ kind: "node" | "pan"; id?: string; x: number; y: number; startX: number; startY: number; moved: boolean } | null>(null);
  const suppressClick = useRef(false);
  const viewport = useRef<HTMLDivElement>(null);
  const marker = useId().replace(/:/g, "");
  const byID = new Map(nodes.map((node) => [node.id, node]));
  const arranged = graph.nodes.map((node) => ({ ...node, ...(moved[node.id] ?? {}) }));
  const positions = new Map(arranged.map((node) => [node.id, node]));
  const width = arranged.reduce((max, node) => Math.max(max, node.x + 260), graph.width);
  const height = arranged.reduce((max, node) => Math.max(max, node.y + 142), graph.height);
  const outputs = new Set(graph.edges.map((edge) => edge.from));
  const zoomTo = (value: number, pointer?: { x: number; y: number }) => {
    const element = viewport.current;
    if (!element) return;
    const at = pointer ?? { x: element.clientWidth / 2, y: element.clientHeight / 2 };
    const anchor = flowZoomAnchor(zoomRef.current, value, { x: element.scrollLeft, y: element.scrollTop }, { x: at.x - panRef.current.x, y: at.y - panRef.current.y });
    zoomRef.current = anchor.zoom;
    setZoom(anchor.zoom);
    requestAnimationFrame(() => element.scrollTo({ left: anchor.x, top: anchor.y }));
  };
  const fit = () => {
    const element = viewport.current;
    if (!element) return;
    const value = fitFlowGraph(width, height, element.clientWidth, element.clientHeight);
    zoomRef.current = value; setZoom(value);
    panRef.current = { x: 0, y: 0 }; setPan(panRef.current);
    element.scrollTo({ left: 0, top: 0 });
  };
  const reset = () => {
    setMoved({}); zoomRef.current = 1; setZoom(1); panRef.current = { x: 0, y: 0 }; setPan(panRef.current);
    viewport.current?.scrollTo({ left: 0, top: 0 });
  };
  const initialized = useRef(false);
  const identity = nodes.map((node) => node.id).join(";");
  useEffect(() => {
    if (!initialized.current) {
      initialized.current = true;
      reset();
      if (fitOnMount) requestAnimationFrame(fit);
    }
  }, [identity]);
  useEffect(() => {
    const element = viewport.current;
    if (!element) return;
    const wheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      const rect = element.getBoundingClientRect();
      zoomTo(zoomRef.current * Math.exp(-event.deltaY * 0.008), { x: event.clientX - rect.left, y: event.clientY - rect.top });
    };
    element.addEventListener("wheel", wheel, { passive: false });
    return () => element.removeEventListener("wheel", wheel);
  }, []);
  const startNode = (event: PointerEvent<HTMLButtonElement>, id: string) => {
    if (event.button !== 0) return;
    event.stopPropagation();
    const point = positions.get(id)!;
    gesture.current = { kind: "node", id, x: event.clientX, y: event.clientY, startX: point.x, startY: point.y, moved: false };
    event.currentTarget.setPointerCapture(event.pointerId);
    onSelect(id);
  };
  const moveNode = (event: PointerEvent<HTMLButtonElement>) => {
    const current = gesture.current;
    if (!current || current.kind !== "node" || !current.id) return;
    const dx = event.clientX - current.x, dy = event.clientY - current.y;
    if (Math.abs(dx) + Math.abs(dy) < 3 && !current.moved) return;
    current.moved = true;
    setMoved((previous) => ({ ...previous, [current.id!]: { x: Math.max(24, current.startX + dx / zoomRef.current), y: Math.max(24, current.startY + dy / zoomRef.current) } }));
  };
  const endNode = () => { suppressClick.current = gesture.current?.moved ?? false; gesture.current = null; };
  const startPan = (event: PointerEvent<HTMLDivElement>) => {
    if (event.button !== 0 && event.button !== 1) return;
    if ((event.target as HTMLElement).closest("button")) return;
    event.preventDefault();
    gesture.current = { kind: "pan", x: event.clientX, y: event.clientY, startX: panRef.current.x, startY: panRef.current.y, moved: false };
    event.currentTarget.setPointerCapture(event.pointerId); setPanning(true);
  };
  const movePan = (event: PointerEvent<HTMLDivElement>) => {
    const current = gesture.current;
    if (current?.kind !== "pan") return;
    panRef.current = { x: current.startX + event.clientX - current.x, y: current.startY + event.clientY - current.y };
    setPan(panRef.current);
  };
  const endPan = () => { if (gesture.current?.kind === "pan") gesture.current = null; setPanning(false); };
  return (
    <div className="flow-graph" data-flow-graph>
      <div className="flow-canvas-toolbar">
        <span className="flow-canvas-title"><Workflow size={14} />{t("Dependency graph")}<span className="flow-count">{nodes.length}</span></span>
        <span className="spacer" />
        <span className="flow-canvas-help" data-tip={t("Drag empty space to pan. Pinch or Ctrl+scroll to zoom. Drag modules to arrange them.")}><Hand size={13} /></span>
        <span className="flow-canvas-zoom-controls">
        <IconButton small icon={<Minus size={13} />} tip={t("Zoom out")} aria-label={t("Zoom out")} onClick={() => zoomTo(zoomRef.current / 1.2)} />
        <button className="flow-zoom mono" aria-label={t("Reset zoom")} data-tip={t("Reset zoom")} onClick={() => zoomTo(1)}>{Math.round(zoom * 100)}%</button>
        <IconButton small icon={<Plus size={13} />} tip={t("Zoom in")} aria-label={t("Zoom in")} onClick={() => zoomTo(zoomRef.current * 1.2)} />
        </span>
        <IconButton small icon={<Maximize size={13} />} tip={t("Fit graph")} aria-label={t("Fit graph")} onClick={fit} />
      <IconButton small icon={<RotateCcw size={13} />} tip={t("Reset layout")} aria-label={t("Reset layout")} onClick={reset} />
      </div>
      <div className={`flow-canvas-scroll ${panning ? "panning" : ""}`} ref={viewport} onPointerDown={startPan} onPointerMove={movePan} onPointerUp={endPan} onPointerCancel={endPan}>
        <div style={{ width: width * zoom, height: height * zoom, minWidth: "100%" }}>
          <div className="flow-canvas" style={{ width, height, transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})` }}>
            <svg width={width} height={height} aria-hidden="true" className="flow-edges">
              <defs>{["neutral", "success", "failure", "active", "warning"].map((tone) => <marker key={tone} id={`${marker}-${tone}`} className={`flow-edge-marker ${tone}`} viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker>)}</defs>
              {graph.edges.map((edge) => {
                const from = positions.get(edge.from)!;
                const to = positions.get(edge.to)!;
                const x1 = from.x + 220, y1 = from.y + 56, x2 = to.x, y2 = to.y + 56;
                const middle = (x1 + x2) / 2;
                const state = byID.get(edge.to)?.state;
                const tone = flowStateTone(state);
                const connected = selected === edge.from || selected === edge.to;
                return <path key={`${edge.from}:${edge.to}`} className={`${tone} ${state === "RUNNING" ? "running" : ""} ${connected ? "connected" : ""}`} d={`M ${x1} ${y1} C ${middle} ${y1}, ${middle} ${y2}, ${x2} ${y2}`} markerEnd={`url(#${marker}-${tone})`} />;
              })}
            </svg>
            {arranged.map((position) => {
              const node = byID.get(position.id)!;
              const state = node.state ?? (node.decision === "skip" ? "SKIPPED" : node.decision === "rejected" ? "REJECTED" : null);
              return <button key={node.id} type="button" className={`flow-node kind-${flowBlockKind(node.block)} ${selected === node.id ? "selected" : ""} ${state?.toLowerCase() ?? ""}`} style={{ left: position.x, top: position.y }} aria-pressed={selected === node.id} data-flow-node={node.id} onPointerDown={(event) => startNode(event, node.id)} onPointerMove={moveNode} onPointerUp={endNode} onPointerCancel={endNode} onKeyDown={(event) => {
                if (!event.altKey || !["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)) return;
                event.preventDefault();
                setMoved((previous) => ({ ...previous, [node.id]: { x: Math.max(24, position.x + (event.key === "ArrowRight" ? 16 : event.key === "ArrowLeft" ? -16 : 0)), y: Math.max(24, position.y + (event.key === "ArrowDown" ? 16 : event.key === "ArrowUp" ? -16 : 0)) } }));
              }} onClick={() => { if (suppressClick.current) { suppressClick.current = false; return; } onSelect(node.id); }}>
                {node.needs.length > 0 && <span className="flow-node-port input" aria-hidden="true" />}
                {outputs.has(node.id) && <span className="flow-node-port output" aria-hidden="true" />}
                <span className="flow-node-heading"><span className="flow-node-type"><FlowBlockIcon block={node.block} size={15} /></span><strong>{node.id}</strong><span className="flow-node-order mono" aria-hidden="true">{String(position.column + 1).padStart(2, "0")}</span></span>
                <span className="flow-node-command mono">{node.run?.split("\n").find((line) => line.trim()) || node.block}</span>
                <span className="flow-node-footer">{state ? <FlowStatePill state={state} compact /> : <span className="flow-node-category mono">{node.block}</span>}<span className="flow-node-duration">{node.durationMs != null ? <><Clock3 size={10} />{formatDuration(node.durationMs)}</> : <span className="flow-node-caption">{node.title || t("Script")}</span>}</span></span>
              </button>;
            })}
            {nodes.length === 0 && <div className="flow-empty">{t("This flow has no steps.")}</div>}
          </div>
        </div>
      </div>
      {(graph.unresolved.length > 0 || graph.missing.length > 0) && <div className="flow-graph-warning">{t("Some dependencies could not be arranged. Check the flow configuration.")}</div>}
    </div>
  );
}
