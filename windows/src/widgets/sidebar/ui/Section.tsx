import { ChevronDown } from "@/shared/icons";
import { createContext, type ReactNode, useContext } from "react";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";
import { SharedPane } from "@/shared/ui";

export const SectionFlyout = createContext(false);

/**
 * A sidebar list with a header; `collapsible={false}` keeps it open without a chevron (a page's own list).
 * `open` with `onToggle` lets the caller keep the state, for a section that starts folded.
 */
export function Section({ id, title, count, actions, children, defaultOpen = true, collapsible = true, open, onToggle }: { id: string; title: string; count?: number; actions?: ReactNode; children: ReactNode; defaultOpen?: boolean; collapsible?: boolean; open?: boolean; onToggle?: () => void }) {
  useObserve(settings);
  const fixed = useContext(SectionFlyout) || !collapsible;
  const collapsed = settings.get<string[]>("collapsedSections", defaultOpen ? [] : [id]);
  const isCollapsed = !fixed && (open !== undefined ? !open : collapsed.includes(id));
  const toggle = onToggle ?? (() => settings.set("collapsedSections", isCollapsed ? collapsed.filter((x) => x !== id) : [...collapsed, id]));
  return (
    <div className="side-section" data-section={id}>
      <div className={`side-head ${isCollapsed ? "collapsed" : ""}`}>
        <span className="row grow" onClick={fixed ? undefined : toggle}>
          {!fixed && <ChevronDown size={12} className="chev" />}
          <span className="ellipsis">{title}</span>
          {count !== undefined && <span className="side-count" style={{ fontWeight: 500 }}>{count}</span>}
        </span>
        {actions}
      </div>
      {!isCollapsed && <SharedPane id={id}>{children}</SharedPane>}
    </div>
  );
}
