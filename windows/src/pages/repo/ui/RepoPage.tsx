import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { NavigationSidebar } from "@/widgets/sidebar";
import { TerminalPanel } from "@/widgets/terminal-panel";
import { Toolbar } from "@/widgets/toolbar";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { resizeColumn } from "../lib/resize-column";
import { RepositoryScreen } from "./RepositoryScreen";
import { WorkspaceContent } from "./WorkspaceContent";
import "./repo-page.css";

/**
 * A tab's window: the page list on the left (an icon rail while the repository screen is open), the page on the right.
 * The repository screen has its own terminal under the graph; the other pages get one below. (macOS: RepoView.swift)
 */
export function RepoPage({ store, openSettings, gitMissing = false }: { store: RepoStore; openSettings: () => void; gitMissing?: boolean }) {
  useObserve(store);
  useObserve(settings);
  const repository = store.destination === "repository";
  const compact = settings.get("navigationSidebarCollapsed", false);
  const navigationW = settings.get("navigationSidebarWidth", 240);
  const paneRef = useRef<HTMLDivElement>(null);
  const [paneH, setPaneH] = useState(800);
  // opening the repository screen folds the page list into the rail, so the branch list takes its place
  useEffect(() => { if (repository) settings.set("navigationSidebarCollapsed", true); }, [repository]);
  useLayoutEffect(() => {
    const el = paneRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setPaneH(el.clientHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, [repository]);

  return (
    <div className="repo">
      {store.path && <Toolbar store={store} />}
      <div className="main" data-navigation-mode={compact ? "compact" : "expanded"}>
        <div className={`navigation${compact ? " compact" : ""}`} style={{ width: compact ? 56 : navigationW }}>
          <NavigationSidebar store={store} openSettings={openSettings} compact={compact} onToggle={() => settings.set("navigationSidebarCollapsed", !compact)} />
        </div>
        {!compact && <div className="splitter navigation-splitter" onMouseDown={resizeColumn("navigationSidebarWidth", navigationW, 200, 320, 1)} />}
        <div className="workspace-main">
          {gitMissing && <div className="workspace-git-notice"><span>{t("Install Git or locate the existing executable to work with local repositories.")}</span><Button onClick={() => window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "tools" }))}>{t("Locate Git…")}</Button></div>}
          {repository ? <RepositoryScreen store={store} openSettings={openSettings} /> : <div className="workspace-pane" ref={paneRef} key={store.path ?? "empty"}>
            <WorkspaceContent store={store} openSettings={openSettings} />
            {store.showTerminal && store.path && <TerminalPanel store={store} columnHeight={paneH} />}
          </div>}
        </div>
      </div>
    </div>
  );
}
