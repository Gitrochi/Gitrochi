import { RotateCcw } from "lucide-react";
import { Minus, Plus } from "@/shared/icons";
import { type PointerEvent, useEffect, useMemo, useRef, useState } from "react";
import { FLOW_CARD, fitFlowGraph, flowEdgeLook, flowStepCommand, flowStepSummary, flowZoomAnchor, formatDuration, layoutFlowGraph } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { IconButton } from "@/shared/ui";
import { FlowStateIcon, flowStepKindTitle, stateTitle } from "./FlowState";
import "./flow-graph.css";

interface GraphNode {
  id: string;
  title?: string | null;
  block: string;
  needs: string[];
  run?: string | null;
  state?: string | null;
  decision?: string;
  durationMs?: number | null;
}

/** What a step shows before the engine has a result for it: only what the plan already decided */
const shownState = (node: GraphNode) => node.state ?? (node.decision === "skip" ? "SKIPPED" : node.decision === "rejected" ? "REJECTED" : null);

/**
 * A scrollable dependency canvas shared by plans, live runs and saved runs. Each card reads top to bottom: how the
 * step did, its name, what it is for, and the command it runs. A connector means "needs": the step on the right
 * starts only after the step on the left has passed.
 */
export function FlowGraph({ nodes, selected, onSelect, fitOnMount = false }: { nodes: GraphNode[]; selected: string | null; onSelect: (id: string) => void; fitOnMount?: boolean }) {
  const graph = useMemo(() => layoutFlowGraph(nodes), [nodes]);
  const [zoom, setZoom] = useState(1);
  const zoomRef = useRef(1);
  const autoFit = useRef(fitOnMount);
  const [moved, setMoved] = useState<Record<string, { x: number; y: number }>>({});
  const [panning, setPanning] = useState(false);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const panRef = useRef({ x: 0, y: 0 });
  const gesture = useRef<{ kind: "node" | "pan"; id?: string; x: number; y: number; startX: number; startY: number; moved: boolean } | null>(null);
  const suppressClick = useRef(false);
  const viewport = useRef<HTMLDivElement>(null);
  const byID = new Map(nodes.map((node) => [node.id, node]));
  const arranged = graph.nodes.map((node) => ({ ...node, ...(moved[node.id] ?? {}) }));
  const positions = new Map(arranged.map((node) => [node.id, node]));
  const width = arranged.reduce((max, node) => Math.max(max, node.x + FLOW_CARD.width + FLOW_CARD.margin), graph.width);
  const height = arranged.reduce((max, node) => Math.max(max, node.y + FLOW_CARD.height + FLOW_CARD.margin), graph.height);
  const rearranged = Object.keys(moved).length > 0;
  const zoomTo = (value: number, pointer?: { x: number; y: number }) => {
    const element = viewport.current;
    if (!element) return;
    autoFit.current = false;
    const at = pointer ?? { x: element.clientWidth / 2, y: element.clientHeight / 2 };
    const anchor = flowZoomAnchor(zoomRef.current, value, { x: element.scrollLeft, y: element.scrollTop }, { x: at.x - panRef.current.x, y: at.y - panRef.current.y });
    zoomRef.current = anchor.zoom;
    setZoom(anchor.zoom);
    requestAnimationFrame(() => element.scrollTo({ left: anchor.x, top: anchor.y }));
  };
  const fit = () => {
    const element = viewport.current;
    if (!element) return;
    autoFit.current = true;
    const value = fitFlowGraph(width, height, element.clientWidth, element.clientHeight);
    zoomRef.current = value; setZoom(value);
    panRef.current = { x: 0, y: 0 }; setPan(panRef.current);
    element.scrollTo({ left: 0, top: 0 });
  };
  const reset = () => {
    autoFit.current = false;
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
    if (!element || !fitOnMount) return;
    // macOS keeps the canvas fitted on resize until the user adjusts the view.
    const observer = new ResizeObserver(() => { if (autoFit.current) fit(); });
    observer.observe(element);
    return () => observer.disconnect();
  }, [width, height, fitOnMount]);
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
    autoFit.current = false;
    current.moved = true;
    setMoved((previous) => ({ ...previous, [current.id!]: { x: Math.max(FLOW_CARD.margin, current.startX + dx / zoomRef.current), y: Math.max(FLOW_CARD.margin, current.startY + dy / zoomRef.current) } }));
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
    autoFit.current = false;
    panRef.current = { x: current.startX + event.clientX - current.x, y: current.startY + event.clientY - current.y };
    setPan(panRef.current);
  };
  const endPan = () => { if (gesture.current?.kind === "pan") gesture.current = null; setPanning(false); };
  return (
    <div className="flow-graph" data-flow-graph>
      <div className="flow-canvas-controls" role="group" aria-label={t("Dependency graph")}>
        <IconButton small icon={<Minus size={13} />} tip={t("Zoom out")} aria-label={t("Zoom out")} onClick={() => zoomTo(zoomRef.current / 1.2)} />
        <button className="flow-zoom mono" aria-label={t("Reset zoom")} data-tip={t("Reset zoom")} onClick={() => zoomTo(1)}>{Math.round(zoom * 100)}%</button>
        <IconButton small icon={<Plus size={13} />} tip={t("Zoom in")} aria-label={t("Zoom in")} onClick={() => zoomTo(zoomRef.current * 1.2)} />
        <span className="flow-canvas-divider" aria-hidden="true" />
        <button className="flow-fit" aria-label={t("Fit graph")} data-tip={t("Drag empty space to pan. Pinch or Ctrl+scroll to zoom. Drag modules to arrange them.")} onClick={fit}>{t("Fit")}</button>
        {rearranged && <IconButton small icon={<RotateCcw size={13} />} tip={t("Reset layout")} aria-label={t("Reset layout")} onClick={reset} />}
      </div>
      <div className={`flow-canvas-scroll ${panning ? "panning" : ""}`} ref={viewport} onPointerDown={startPan} onPointerMove={movePan} onPointerUp={endPan} onPointerCancel={endPan}>
        <div style={{ width: width * zoom, height: height * zoom, minWidth: "100%" }}>
          <div className="flow-canvas" style={{ width, height, transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})` }}>
            <svg width={width} height={height} aria-hidden="true" className="flow-edges">
              {graph.edges.map((edge) => {
                const from = positions.get(edge.from)!;
                const to = positions.get(edge.to)!;
                const x1 = from.x + FLOW_CARD.width, y1 = from.y + FLOW_CARD.height / 2, x2 = to.x, y2 = to.y + FLOW_CARD.height / 2;
                const middle = (x1 + x2) / 2;
                const look = flowEdgeLook(shownState(byID.get(edge.from)!), shownState(byID.get(edge.to)!));
                return <path key={`${edge.from}:${edge.to}`} className={`${look.tone} ${look.dashed ? "dashed" : ""}`} d={`M ${x1} ${y1} C ${middle} ${y1}, ${middle} ${y2}, ${x2} ${y2}`} />;
              })}
              {graph.edges.map((edge) => {
                const to = positions.get(edge.to)!;
                const look = flowEdgeLook(shownState(byID.get(edge.from)!), shownState(byID.get(edge.to)!));
                return <circle key={`${edge.from}:${edge.to}`} className={look.tone} cx={to.x} cy={to.y + FLOW_CARD.height / 2} r={3} />;
              })}
            </svg>
            {arranged.map((position) => {
              const node = byID.get(position.id)!;
              const state = shownState(node);
              const command = flowStepCommand(node);
              const duration = node.durationMs != null ? formatDuration(node.durationMs) : null;
              return <button key={node.id} type="button" className={`flow-node ${selected === node.id ? "selected" : ""} ${state?.toLowerCase() ?? ""}`} style={{ left: position.x, top: position.y, width: FLOW_CARD.width, height: FLOW_CARD.height }} aria-pressed={selected === node.id} aria-label={[node.id, stateTitle(state), duration].filter(Boolean).join(", ")} data-flow-node={node.id} onPointerDown={(event) => startNode(event, node.id)} onPointerMove={moveNode} onPointerUp={endNode} onPointerCancel={endNode} onKeyDown={(event) => {
                if (!event.altKey || !["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)) return;
                event.preventDefault();
                autoFit.current = false;
                setMoved((previous) => ({ ...previous, [node.id]: { x: Math.max(FLOW_CARD.margin, position.x + (event.key === "ArrowRight" ? 16 : event.key === "ArrowLeft" ? -16 : 0)), y: Math.max(FLOW_CARD.margin, position.y + (event.key === "ArrowDown" ? 16 : event.key === "ArrowUp" ? -16 : 0)) } }));
              }} onClick={() => { if (suppressClick.current) { suppressClick.current = false; return; } onSelect(node.id); }}>
                <span className="flow-node-heading">
                  <FlowStateIcon state={state} size={14} />
                  <strong className="mono">{node.id}</strong>
                  {duration && <span className="flow-node-duration mono">{duration}</span>}
                </span>
                <span className="flow-node-summary">{flowStepSummary(node) ?? flowStepKindTitle(node.block)}</span>
                {command && <span className="flow-node-command mono">{command}</span>}
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
