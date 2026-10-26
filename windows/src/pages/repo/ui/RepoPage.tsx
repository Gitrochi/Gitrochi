import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { ArrowLeft, ArrowRight, Code2, FileDiff, GitBranch, GitCommitHorizontal, GitCompareArrows, ListOrdered, Pin } from "lucide-react";
import { Inspector } from "@/widgets/inspector";
import { NavigationSidebar, destinationTitle } from "@/widgets/sidebar";
import { TerminalPanel } from "@/widgets/terminal-panel";
import { Toolbar } from "@/widgets/toolbar";
import type { RepoStore } from "@/entities/repo";
import { repositorySections, type RepositorySection } from "@/entities/git";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { RepositoryDocument, WorkspaceContent } from "./WorkspaceContent";
import "./repo-page.css";

/** 저장소를 연 뒤의 메인 화면: 사이드바 | 그래프 또는 diff (+ 터미널) | 상세 */
export function RepoPage({ store, openSettings, gitMissing = false }: { store: RepoStore; openSettings: () => void; gitMissing?: boolean }) {
  useObserve(store);
  useObserve(settings);
  const sidebarW = settings.get("sidebarWidth", 250);
  const inspectorW = settings.get("inspectorWidth", 380);
  const repository = store.destination === "repository";
  const section = store.repositorySection;
  const centerRef = useRef<HTMLDivElement>(null);
  const mainRef = useRef<HTMLDivElement>(null);
  const [centerH, setCenterH] = useState(800);
  const [workspaceWidth, setWorkspaceWidth] = useState(() => window.innerWidth);
  const [narrowExpanded, setNarrowExpanded] = useState(false);
  const narrow = workspaceWidth < 1000;
  const sidebarCollapsed = settings.get("navigationSidebarCollapsed", false);
  const compact = sidebarCollapsed || (narrow && !narrowExpanded);
  const toggleSidebar = () => {
    if (narrow) { settings.set("navigationSidebarCollapsed", false); setNarrowExpanded(compact); }
    else settings.set("navigationSidebarCollapsed", !compact);
  };
  useEffect(() => { setNarrowExpanded(false); }, [narrow]);
  useLayoutEffect(() => {
    const el = centerRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => { setCenterH(el.clientHeight); if (mainRef.current) setWorkspaceWidth(mainRef.current.clientWidth); });
    ro.observe(el);
    if (mainRef.current) ro.observe(mainRef.current);
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
      {store.path && <Toolbar store={store} />}
      <div className="main" ref={mainRef} data-navigation-mode={compact ? "compact" : "expanded"}>
        <div className={`sidebar${compact ? " compact" : ""}`} style={{ width: compact ? 56 : sidebarW }}>
          <NavigationSidebar store={store} openSettings={openSettings} compact={compact} onToggle={toggleSidebar} />
        </div>
        {!compact && <div className="splitter sidebar-splitter" onMouseDown={resize("sidebarWidth", sidebarW, 200, 420, 1)} />}
        <div className="workspace-main" ref={centerRef}>
          <header className="workspace-location">
            <button aria-label={t("Previous page")} disabled={store.navigationPosition === 0} onClick={() => store.moveWorkspaceHistory(-1)}><ArrowLeft size={15} /></button>
            <button aria-label={t("Next page")} disabled={store.navigationPosition + 1 >= store.navigationTrail.length} onClick={() => store.moveWorkspaceHistory(1)}><ArrowRight size={15} /></button>
            <strong>{destinationTitle(store.destination, store.target?.provider === "gitlab")}</strong><span className="spacer" /><span className="workspace-repository-context hint ellipsis" data-tip={store.path ?? ""}>{store.path ? `${store.name} · ${store.headBranch ?? t("Detached HEAD")}` : "Gitrochi"}</span>
          </header>
          {gitMissing && <div className="workspace-git-notice"><span>{t("Install Git or locate the existing executable to work with local repositories.")}</span><Button onClick={() => window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "tools" }))}>{t("Locate Git…")}</Button></div>}
          {repository && <RepositoryTabs store={store} />}
          {repository && (section === "changes" || section === "commits") ? <div className={`workspace-git-layout ${section}`}>
            {section === "changes" && <div className="workspace-changes-list"><Inspector store={store} /></div>}
            <div className="center"><RepositoryDocument store={store} /></div>
            {section === "commits" && <><div className="splitter" onMouseDown={resize("inspectorWidth", inspectorW, 260, 520, -1)} /><div className="inspector" style={{ width: inspectorW }}><Inspector store={store} /></div></>}
          </div> : <div className="workspace-pane" key={store.path ?? "empty"}><WorkspaceContent store={store} openSettings={openSettings} /></div>}
          {store.showTerminal && store.path && <TerminalPanel store={store} columnHeight={centerH} />}
        </div>
      </div>
    </div>
  );
}

const sectionIcons = { changes: FileDiff, commits: GitCommitHorizontal, branches: GitBranch, compare: GitCompareArrows, rebase: ListOrdered, code: Code2 };

/** 한 저장소의 작업 탭과 바로가기 선택을 같은 위치에서 제공한다. */
export function RepositoryTabs({ store }: { store: RepoStore }) {
  const tabs = useRef<HTMLDivElement>(null);
  const select = (section: RepositorySection) => {
    store.selectRepositorySection(section);
    tabs.current?.querySelector<HTMLButtonElement>(`[data-section="${section}"]`)?.focus();
  };
  const keyboard = (event: React.KeyboardEvent, section: RepositorySection) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const index = repositorySections.indexOf(section);
    const next = event.key === "Home" ? 0 : event.key === "End" ? repositorySections.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + repositorySections.length) % repositorySections.length;
    select(repositorySections[next]);
  };
  return <div className="repository-workspace-tabs">
    <div ref={tabs} className="repository-tab-list" role="tablist" aria-label={t("Repository")}>
      {repositorySections.map((section) => {
        const Icon = sectionIcons[section], selected = store.repositorySection === section;
        return <button key={section} type="button" role="tab" aria-selected={selected} tabIndex={selected ? 0 : -1} data-section={section} onKeyDown={(event) => keyboard(event, section)} onClick={() => store.selectRepositorySection(section)} className={`repository-tab${selected ? " selected" : ""}`}><Icon size={16} /><span>{destinationTitle(section)}</span>{section === "changes" && store.wipCount > 0 && <span className="repository-tab-count">{store.wipCount > 999 ? "999+" : store.wipCount}</span>}</button>;
      })}
    </div>
    <Button className={`repository-tab-pin${store.isRepositoryPagePinned(store.repositorySection) ? " pinned" : ""}`} aria-label={t(store.isRepositoryPagePinned(store.repositorySection) ? "Remove shortcut" : "Pin to sidebar")} tip={t(store.isRepositoryPagePinned(store.repositorySection) ? "Remove shortcut" : "Pin to sidebar")} onClick={() => store.toggleRepositoryPagePin(store.repositorySection)}><Pin size={15} /></Button>
  </div>;
}
