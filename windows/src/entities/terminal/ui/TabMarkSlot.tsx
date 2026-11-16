import type { TabMark } from "../lib/panel-layout";
import "./tab-mark.css";

/** The 12px slot a terminal tab and an agent session row reserve, so titles never shift when a mark appears */
export function TabMarkSlot({ mark }: { mark: TabMark }) {
  return (
    <span className="term-mark-slot" aria-hidden="true">
      <span className={`term-mark ${mark}`} data-mark={mark} />
    </span>
  );
}
