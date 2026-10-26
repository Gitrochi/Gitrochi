import { createContext, type CSSProperties, type ReactNode, useCallback, useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import { shareHeights } from "@/shared/lib";

/**
 * A column whose panes share its height: each pane gets its natural height when that fits, the long ones split what is left
 * and scroll inside (sidebar sections, the working copy's file lists). The column itself scrolls only when even the floors
 * do not fit. (macOS: Views/Shared/SharedStack.swift)
 */
const ReportCtx = createContext<((id: string, natural: number | null) => void) | null>(null);
const SharesCtx = createContext<Map<string, number>>(new Map());

export function SharedStack({
  className = "",
  bodyClassName = "",
  style,
  floor = 96,
  children,
}: {
  className?: string;
  bodyClassName?: string;
  style?: CSSProperties;
  floor?: number;
  children: ReactNode;
}) {
  const outer = useRef<HTMLDivElement>(null);
  const body = useRef<HTMLDivElement>(null);
  const [available, setAvailable] = useState(0);
  const [naturals, setNaturals] = useState(() => new Map<string, number>());
  const report = useCallback((id: string, natural: number | null) => {
    setNaturals((m) => {
      if ((m.has(id) ? m.get(id)! : null) === natural) return m;
      const n = new Map(m);
      if (natural === null) n.delete(id);
      else n.set(id, natural);
      return n;
    });
  }, []);
  const shares = useMemo(() => {
    const ids = [...naturals.keys()];
    const h = shareHeights(
      ids.map((id) => naturals.get(id)!),
      available,
      floor,
    );
    return new Map(ids.map((id, i) => [id, h[i]]));
  }, [naturals, available, floor]);

  // what the panes may take: the column minus its fixed parts (headers, gaps, padding, whatever is not a pane)
  const measure = useCallback(() => {
    const o = outer.current;
    const b = body.current;
    if (!o || !b) return;
    let panes = 0;
    b.querySelectorAll<HTMLElement>(".shared-pane").forEach((p) => {
      if (p.parentElement?.closest(".shared-stack") === o) panes += p.getBoundingClientRect().height;
    });
    const cs = getComputedStyle(o);
    const fixed = b.getBoundingClientRect().height - panes;
    const next = Math.max(0, Math.floor(o.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom) - fixed));
    // Fractional flex heights must not alternate the rounded measurement on every layout effect.
    setAvailable((previous) => Math.abs(previous - next) <= 1 ? previous : next);
  }, []);
  useLayoutEffect(measure); // after every render: the fixed parts may have changed
  useLayoutEffect(() => {
    const o = outer.current;
    if (!o) return;
    const ro = new ResizeObserver(measure);
    ro.observe(o);
    return () => ro.disconnect();
  }, [measure]);

  return (
    <ReportCtx.Provider value={report}>
      <SharesCtx.Provider value={shares}>
        <div ref={outer} className={`shared-stack ${className}`} style={style}>
          <div ref={body} className={bodyClassName}>
            {children}
          </div>
        </div>
      </SharesCtx.Provider>
    </ReportCtx.Provider>
  );
}

/** A pane in a SharedStack: scrolls inside when it got less than its natural height. Outside a stack it just grows. */
export function SharedPane({ id, gap, className = "", children }: { id: string; gap?: number; className?: string; children: ReactNode }) {
  const report = useContext(ReportCtx);
  const share = useContext(SharesCtx).get(id);
  const inner = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = inner.current;
    if (!report || !el) return;
    const tell = () => report(id, el.offsetHeight);
    tell();
    const ro = new ResizeObserver(tell);
    ro.observe(el);
    return () => {
      ro.disconnect();
      report(id, null);
    };
  }, [report, id]);
  return (
    <div className={`shared-pane ${className}`} style={share !== undefined ? { height: share, overflowY: "auto" } : undefined}>
      <div ref={inner} style={gap !== undefined ? { display: "flex", flexDirection: "column", gap } : undefined}>
        {children}
      </div>
    </div>
  );
}
