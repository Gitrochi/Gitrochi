import { ChevronDown } from "lucide-react";
import { createContext, type ReactNode, useContext } from "react";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";
import { SharedPane } from "@/shared/ui";

export const SectionFlyout = createContext(false);

export function Section({ id, title, count, actions, children, defaultOpen = true }: { id: string; title: string; count?: number; actions?: ReactNode; children: ReactNode; defaultOpen?: boolean }) {
  useObserve(settings);
  const flyout = useContext(SectionFlyout);
  const collapsed = settings.get<string[]>("collapsedSections", defaultOpen ? [] : [id]);
  const isCollapsed = !flyout && collapsed.includes(id);
  const toggle = () => settings.set("collapsedSections", isCollapsed ? collapsed.filter((x) => x !== id) : [...collapsed, id]);
  return (
    <div className="side-section">
      <div className={`side-head ${isCollapsed ? "collapsed" : ""}`}>
        <span className="row grow" onClick={flyout ? undefined : toggle}>
          {!flyout && <ChevronDown size={12} className="chev" />}
          <span className="ellipsis">{title}</span>
          {count !== undefined && <span style={{ fontWeight: 500 }}>{count}</span>}
        </span>
        {actions}
      </div>
      {!isCollapsed && <SharedPane id={id}>{children}</SharedPane>}
    </div>
  );
}
