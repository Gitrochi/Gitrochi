import { useLayoutEffect, useRef, useState } from "react";
import { GraphView } from "@/widgets/commit-graph";
import { DiffView, FileInspectView } from "@/widgets/diff-viewer";
import { Inspector } from "@/widgets/inspector";
import { Sidebar, SidebarRail } from "@/widgets/sidebar";
import { TerminalPanel } from "@/widgets/terminal-panel";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";
import { resizeColumn } from "../lib/resize-column";

/**
 * The repository screen: branches and refs | graph or diff with the terminal below | uncommitted changes or details
 * (macOS: RepositoryScreen in WorkspaceDestinationContent.swift)
 */
export function RepositoryScreen({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  useObserve(settings);
  const sidebarW = settings.get("sidebarWidth", 250);
  const sidebarCollapsed = settings.get("sidebarCollapsed", false);
  const inspectorW = settings.get("inspectorWidth", 380);
  const inspectorCollapsed = settings.get("inspectorCollapsed", false);
  const centerRef = useRef<HTMLDivElement>(null);
  const [centerH, setCenterH] = useState(800);
  useLayoutEffect(() => {
    const el = centerRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setCenterH(el.clientHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return (
    <div className="repository-screen">
      {sidebarCollapsed ? (
        <SidebarRail store={store} openSettings={openSettings} />
      ) : (
        <>
          <div className="sidebar" style={{ width: sidebarW }}>
            <Sidebar store={store} openSettings={openSettings} />
          </div>
          <div className="splitter" onMouseDown={resizeColumn("sidebarWidth", sidebarW, 200, 420, 1)} />
        </>
      )}
      <div className="center" ref={centerRef}>
        {store.fileInspect ? <FileInspectView store={store} /> : store.diffSource ? <DiffView store={store} /> : <GraphView store={store} />}
        {store.showTerminal && <TerminalPanel store={store} columnHeight={centerH} />}
      </div>
      <div className="splitter" hidden={inspectorCollapsed} onMouseDown={resizeColumn("inspectorWidth", inspectorW, 320, 600, -1)} />
      <div className="inspector" hidden={inspectorCollapsed} style={{ width: inspectorW }}>
        <Inspector store={store} />
      </div>
    </div>
  );
}
