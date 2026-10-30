import { Maximize, Minus, Plus, Terminal, Workflow } from "lucide-react";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { formatDuration, layoutFlowGraph } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { IconButton } from "@/shared/ui";
import { FlowStateIcon, stateTitle } from "./FlowState";

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
export function FlowGraph({ nodes, selected, onSelect }: { nodes: GraphNode[]; selected: string | null; onSelect: (id: string) => void }) {
  const graph = useMemo(() => layoutFlowGraph(nodes), [nodes]);
  const [zoom, setZoom] = useState(1);
  const viewport = useRef<HTMLDivElement>(null);
  const marker = useId().replace(/:/g, "");
  const byID = new Map(nodes.map((node) => [node.id, node]));
  const positions = new Map(graph.nodes.map((node) => [node.id, node]));
  const fit = () => {
    const width = viewport.current?.clientWidth ?? 0;
    const height = viewport.current?.clientHeight ?? 0;
    setZoom(Math.max(0.35, Math.min(1, (width - 24) / graph.width, (height - 24) / graph.height)));
    viewport.current?.scrollTo({ left: 0, top: 0 });
  };
  const structure = nodes.map((node) => node.id + ":" + node.needs.join(",")).join(";");
  useEffect(() => {
    setZoom(1);
    viewport.current?.scrollTo({ left: 0, top: 0 });
  }, [structure]);
  return (
    <div className="flow-graph" data-flow-graph>
      <div className="flow-canvas-toolbar">
        <span><Workflow size={13} />{t("Dependency graph")}</span>
        <span className="spacer" />
        <IconButton small icon={<Minus size={13} />} tip={t("Zoom out")} onClick={() => setZoom((value) => Math.max(0.35, value - 0.15))} />
        <span className="flow-zoom mono">{Math.round(zoom * 100)}%</span>
        <IconButton small icon={<Plus size={13} />} tip={t("Zoom in")} onClick={() => setZoom((value) => Math.min(1.75, value + 0.15))} />
        <IconButton small icon={<Maximize size={13} />} tip={t("Fit graph")} onClick={fit} />
      </div>
      <div className="flow-canvas-scroll" ref={viewport}>
        <div style={{ width: graph.width * zoom, height: graph.height * zoom, minWidth: "100%" }}>
          <div className="flow-canvas" style={{ width: graph.width, height: graph.height, transform: `scale(${zoom})` }}>
            <svg width={graph.width} height={graph.height} aria-hidden="true" className="flow-edges">
              <defs><marker id={marker} viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor" /></marker></defs>
              {graph.edges.map((edge) => {
                const from = positions.get(edge.from)!;
                const to = positions.get(edge.to)!;
                const x1 = from.x + 220, y1 = from.y + 56, x2 = to.x, y2 = to.y + 56;
                const middle = (x1 + x2) / 2;
                return <path key={`${edge.from}:${edge.to}`} className={byID.get(edge.to)?.state === "RUNNING" ? "running" : ""} d={`M ${x1} ${y1} C ${middle} ${y1}, ${middle} ${y2}, ${x2} ${y2}`} markerEnd={`url(#${marker})`} />;
              })}
            </svg>
            {graph.nodes.map((position) => {
              const node = byID.get(position.id)!;
              const state = node.state ?? (node.decision === "skip" ? "SKIPPED" : node.decision === "rejected" ? "REJECTED" : null);
              return <button key={node.id} type="button" className={`flow-node ${selected === node.id ? "selected" : ""} ${state?.toLowerCase() ?? ""}`} style={{ left: position.x, top: position.y }} aria-pressed={selected === node.id} data-flow-node={node.id} onClick={() => onSelect(node.id)}>
                <span className="flow-node-heading"><span className="flow-node-type"><Terminal size={14} /></span><strong>{node.id}</strong><FlowStateIcon state={state} /></span>
                <span className="flow-node-command mono">{node.run?.split("\n").find((line) => line.trim()) || node.block}</span>
                <span className="flow-node-footer"><span>{node.title || node.block}</span><span>{node.durationMs != null ? formatDuration(node.durationMs) : state ? stateTitle(state) : node.block}</span></span>
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
