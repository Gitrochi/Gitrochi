import { ChevronDown } from "lucide-react";
import { createContext, type ReactNode, useContext } from "react";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";
import { SharedPane } from "@/shared/ui";

export const SectionFlyout = createContext(false);

/** A sidebar list with a header; `collapsible={false}` keeps it open without a chevron (a page's own list) */
export function Section({ id, title, count, actions, children, defaultOpen = true, collapsible = true }: { id: string; title: string; count?: number; actions?: ReactNode; children: ReactNode; defaultOpen?: boolean; collapsible?: boolean }) {
  useObserve(settings);
  const fixed = useContext(SectionFlyout) || !collapsible;
  const collapsed = settings.get<string[]>("collapsedSections", defaultOpen ? [] : [id]);
  const isCollapsed = !fixed && collapsed.includes(id);
  const toggle = () => settings.set("collapsedSections", isCollapsed ? collapsed.filter((x) => x !== id) : [...collapsed, id]);
  return (
    <div className="side-section" data-section={id}>
      <div className={`side-head ${isCollapsed ? "collapsed" : ""}`}>
        <span className="row grow" onClick={fixed ? undefined : toggle}>
          {!fixed && <ChevronDown size={12} className="chev" />}
          <span className="ellipsis">{title}</span>
          {count !== undefined && <span style={{ fontWeight: 500 }}>{count}</span>}
        </span>
        {actions}
      </div>
      {!isCollapsed && <SharedPane id={id}>{children}</SharedPane>}
    </div>
  );
}
