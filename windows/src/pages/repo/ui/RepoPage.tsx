import { useLayoutEffect, useRef, useState } from "react";
import { GraphView } from "@/widgets/commit-graph";
import { DiffView, FileInspectView } from "@/widgets/diff-viewer";
import { Inspector } from "@/widgets/inspector";
import { Sidebar, SidebarRail } from "@/widgets/sidebar";
import { TerminalPanel } from "@/widgets/terminal-panel";
import { Toolbar } from "@/widgets/toolbar";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";
import "./repo-page.css";

/** 저장소를 연 뒤의 메인 화면: 사이드바 | 그래프 또는 diff (+ 터미널) | 상세 */
export function RepoPage({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(settings);
  const sidebarW = settings.get("sidebarWidth", 250);
  const sidebarCollapsed = settings.get("sidebarCollapsed", false);
  const inspectorW = settings.get("inspectorWidth", 380);
  const centerRef = useRef<HTMLDivElement>(null);
  const [centerH, setCenterH] = useState(800);
  useLayoutEffect(() => {
    const el = centerRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setCenterH(el.clientHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const resize = (key: string, start: number, min: number, max: number, sign: 1 | -1) => (e: React.MouseEvent) => {
    e.preventDefault();
    const x0 = e.clientX;
    const move = (ev: MouseEvent) => settings.set(key, Math.min(max, Math.max(min, start + sign * (ev.clientX - x0))));
    const up = () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      document.body.style.cursor = "";
    };
    document.body.style.cursor = "col-resize";
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  };

  return (
    <div className="repo">
      <Toolbar store={store} />
      <div className="main">
        {sidebarCollapsed ? (
          <SidebarRail store={store} openSettings={openSettings} />
        ) : (
          <>
            <div className="sidebar" style={{ width: sidebarW }}>
              <Sidebar store={store} openSettings={openSettings} />
            </div>
            <div className="splitter" onMouseDown={resize("sidebarWidth", sidebarW, 200, 420, 1)} />
          </>
        )}
        <div className="center" ref={centerRef}>
          {store.fileInspect ? <FileInspectView store={store} /> : store.diffSource ? <DiffView store={store} /> : <GraphView store={store} />}
          {store.showTerminal && <TerminalPanel store={store} columnHeight={centerH} />}
        </div>
        <div className="splitter" onMouseDown={resize("inspectorWidth", inspectorW, 320, 600, -1)} />
        <div className="inspector" style={{ width: inspectorW }}>
          <Inspector store={store} />
        </div>
      </div>
    </div>
  );
}
