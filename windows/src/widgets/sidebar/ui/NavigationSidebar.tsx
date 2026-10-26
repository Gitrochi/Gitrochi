import { Blocks, Bot, Check, ChevronDown, ChevronRight, CircleDot, Code2, ExternalLink, FileDiff, FolderGit2, GitBranch, GitCommitHorizontal, GitCompareArrows, GitPullRequest, Home, Inbox, ListOrdered, PanelLeftClose, PanelLeftOpen, Pin, PlayCircle, Search, Settings, SlidersHorizontal, Sparkles, Tag, UserRound, UsersRound, Workflow, Wrench, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { isRepositorySection, repositoryDestinations, repositorySections, type WorkspaceDestination } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { CompactNavigationPreview } from "./CompactNavigationPreview";
import "./navigation-sidebar.css";

export const destinationTitles: Record<WorkspaceDestination, string> = { home: "Home", repositories: "Repository library", repository: "Repository", changes: "Changes", commits: "Commits", branches: "Branches", compare: "Compare", rebase: "Rebase", code: "Code", inbox: "Inbox", myWork: "My work", pullRequests: "Pull requests", issues: "Issues", actions: "Actions", releases: "Releases", projects: "Projects", organizations: "Organizations", gists: "Gists", assistant: "Repository assistant", agents: "Agents", worktrees: "Worktrees", operations: "Tools and diagnosis" };
export const destinationTitle = (page: WorkspaceDestination, gitlab = false) => t(gitlab && page === "pullRequests" ? "Merge requests" : gitlab && page === "actions" ? "Pipelines" : gitlab && page === "organizations" ? "Groups" : gitlab && page === "gists" ? "Snippets" : destinationTitles[page]);
const icons = { home: Home, repositories: FolderGit2, repository: FolderGit2, changes: FileDiff, commits: GitCommitHorizontal, branches: GitBranch, compare: GitCompareArrows, rebase: ListOrdered, code: Code2, inbox: Inbox, myWork: UserRound, pullRequests: GitPullRequest, issues: CircleDot, actions: PlayCircle, releases: Tag, projects: Blocks, organizations: UsersRound, gists: Code2, assistant: Sparkles, agents: Bot, worktrees: Workflow, operations: Wrench };

export function NavigationSidebar({ store, openSettings, compact = false, onToggle }: { store: RepoStore; openSettings: () => void; compact?: boolean; onToggle?: () => void }) {
  useObserve(store); useObserve(settings);
  const [query, setQuery] = useState(""), [customizing, setCustomizing] = useState(false);
  const input = useRef<HTMLInputElement>(null), customize = useRef<HTMLDivElement>(null), searchAfterExpand = useRef(false);
  const [preview, setPreview] = useState<{ page: WorkspaceDestination; trigger: HTMLElement; focusFirst: boolean } | null>(null);
  const closeTimer = useRef<ReturnType<typeof setTimeout>>();
  const keepPreview = () => { if (closeTimer.current) clearTimeout(closeTimer.current); };
  const dismissPreview = (restoreFocus = false, delayed = false) => {
    keepPreview();
    const close = () => {
      const panel = document.getElementById("workspace-navigation-preview");
      if (delayed && panel?.contains(document.activeElement)) return;
      if (restoreFocus) preview?.trigger.focus();
      setPreview(null);
    };
    if (delayed) closeTimer.current = setTimeout(close, 160); else close();
  };
  const openPreview = (page: WorkspaceDestination, trigger: HTMLElement, focusFirst = false) => {
    keepPreview();
    if (compact && !trigger.hasAttribute("disabled")) setPreview({ page, trigger, focusFirst });
  };
  useEffect(() => () => { if (closeTimer.current) clearTimeout(closeTimer.current); }, []);
  useEffect(() => { setPreview(null); }, [compact, store.destination, store.repositorySection]);
  const expanded = settings.get("navigationToolsExpanded", true);
  const gitlab = store.target?.provider === "gitlab";
  const title = (page: WorkspaceDestination) => destinationTitle(page, gitlab);
  const focusSearch = () => {
    if (compact) { searchAfterExpand.current = true; onToggle?.(); }
    else { input.current?.focus(); input.current?.select(); }
  };
  useEffect(() => {
    if (!compact && searchAfterExpand.current) { searchAfterExpand.current = false; input.current?.focus(); input.current?.select(); }
    if (compact) { setCustomizing(false); setQuery(""); }
  }, [compact]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return;
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") { event.preventDefault(); focusSearch(); }
      if ((event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "b") { event.preventDefault(); onToggle?.(); }
      if (event.key === "Escape") { setCustomizing(false); setPreview(null); }
    };
    const dismiss = (event: MouseEvent) => {
      if (!customize.current?.contains(event.target as Node)) setCustomizing(false);
      if (!(event.target as HTMLElement)?.closest(".workspace-nav-preview, .workspace-nav-row")) setPreview(null);
    };
    window.addEventListener("keydown", key); document.addEventListener("mousedown", dismiss);
    return () => { window.removeEventListener("keydown", key); document.removeEventListener("mousedown", dismiss); };
  }, [compact, onToggle]);
  const rows = (pages: readonly WorkspaceDestination[], shortcut = false) => pages.filter((page) => !query || `${title(page)} ${page}`.toLowerCase().includes(query.toLowerCase())).map((page) => {
    const Icon = icons[page], section = isRepositorySection(page) ? page : null;
    const selected = section ? store.destination === "repository" && store.repositorySection === section : store.destination === page && (page !== "repository" || !store.isRepositoryPagePinned(store.repositorySection));
    const disabled = repositoryDestinations.has(page) && !store.path;
    const count = page === "changes" || page === "repository" ? store.wipCount : page === "pullRequests" ? store.pullRequests.length : 0;
    return <div className={`workspace-nav-row${shortcut ? " shortcut" : ""}`} key={page} onMouseEnter={(event) => { const button = event.currentTarget.querySelector<HTMLButtonElement>("button"); if (button) openPreview(page, button); }} onMouseLeave={() => dismissPreview(false, true)}>
      <button type="button" className={`workspace-nav-item${selected ? " selected" : ""}${page === "repository" ? " repository-entry" : ""}`} aria-label={title(page)} aria-current={selected ? "page" : undefined} disabled={disabled} aria-haspopup={compact ? "true" : undefined} aria-expanded={compact ? preview?.page === page : undefined} aria-controls={compact && preview?.page === page ? "workspace-navigation-preview" : undefined}
        onFocus={(event) => openPreview(page, event.currentTarget)} onBlur={(event) => { if (!(event.relatedTarget as HTMLElement | null)?.closest(".workspace-nav-preview")) dismissPreview(); }}
        onKeyDown={(event) => { if (compact && event.key === "ArrowRight") { event.preventDefault(); openPreview(page, event.currentTarget, true); } }}
        onClick={() => { setPreview(null); store.navigate(page); }} data-page={page} data-tip={disabled ? t("Open a repository to use this page.") : title(page)}>
        <Icon size={18} strokeWidth={selected ? 2 : 1.7} /><span className="workspace-nav-copy"><span className="ellipsis">{title(page)}</span>{page === "repository" && <small className="ellipsis">{store.path ? `${store.name} · ${title(store.repositorySection)}` : t("Open a repository to get started")}</small>}</span>{count > 0 && <span className="workspace-nav-badge">{count > 999 ? "999+" : count}</span>}
      </button>
      {!compact && section && store.isRepositoryPagePinned(section) && <button type="button" className="workspace-nav-unpin" aria-label={`${t("Remove shortcut")}: ${title(page)}`} data-tip={t("Remove shortcut")} onClick={() => store.toggleRepositoryPagePin(section)}><Pin size={12} /></button>}
    </div>;
  });
  const label = (text: string) => <div className="workspace-nav-group"><span className="ellipsis">{text}</span><span /></div>;
  return <nav className={`workspace-navigation${compact ? " compact" : ""}`} aria-label={t("Workspace navigation")}>
    {onToggle && <div className="workspace-nav-header"><span>{t("Workspace")}</span><button type="button" className="workspace-nav-toggle" aria-label={t(compact ? "Expand sidebar" : "Collapse sidebar")} aria-expanded={!compact} onClick={onToggle} data-tip={`${t(compact ? "Show sidebar" : "Hide sidebar")} · ${navigator.platform.includes("Mac") ? "⌘" : "Ctrl"} B\n${t("The sections stay at hand as a rail of icons; hover one to open it.")}`}>{compact ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}</button></div>}
    {compact ? <button type="button" className="workspace-nav-search-compact" aria-label={t("Find a workspace page")} onClick={focusSearch} data-tip={t("Go to a page…")}><Search size={18} /></button> : <div className="workspace-nav-search"><Search size={14} /><input ref={input} value={query} onChange={(e) => setQuery(e.target.value)} placeholder={t("Go to a page…")} aria-label={t("Find a workspace page")} />{query ? <button aria-label={t("Clear search")} onClick={() => setQuery("")}><X size={12} /></button> : <kbd>{navigator.platform.includes("Mac") ? "⌘" : "Ctrl"} K</kbd>}</div>}
    <div className="workspace-nav-scroll">
      {rows(["home", "repositories"])}
      <div className="workspace-nav-repository-group" ref={customize}>
        <div className="workspace-nav-group"><span>{t("Workspace")}</span><span />{!compact && <button className="workspace-nav-customize" aria-label={t("Choose repository shortcuts")} aria-expanded={customizing} onClick={() => setCustomizing(!customizing)} data-tip={t("Choose repository shortcuts")}><SlidersHorizontal size={13} /></button>}</div>
        {customizing && <div className="workspace-nav-customization" role="dialog" aria-label={t("Choose repository shortcuts")}><strong>{t("Repository shortcuts")}</strong><p>{t("Keep your favorite tools in the sidebar. All tools stay available in Repository.")}</p>{repositorySections.map((section) => <button key={section} type="button" role="checkbox" aria-checked={store.isRepositoryPagePinned(section)} onClick={() => store.toggleRepositoryPagePin(section)}><span className={`workspace-nav-check${store.isRepositoryPagePinned(section) ? " checked" : ""}`}>{store.isRepositoryPagePinned(section) && <Check size={11} />}</span><span>{title(section)}</span><Pin size={12} /></button>)}</div>}
      </div>
      {rows(["repository"])}
      {rows(query ? repositorySections : store.pinnedRepositoryPages, true)}
      {label(gitlab ? "GitLab" : "GitHub")}
      {rows(["inbox", "myWork", "pullRequests", "issues", "actions", "releases", "projects", "organizations", "gists"])}
      {compact ? label(t("Workspace tools")) : <button className="workspace-nav-tools" aria-expanded={expanded || !!query} onClick={() => settings.set("navigationToolsExpanded", !expanded)}><span>{t("Workspace tools")}</span>{expanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}</button>}
      {(compact || expanded || !!query) && rows(["assistant", "agents", "worktrees", "operations"])}
    </div>
    <div className="workspace-nav-footer"><button className="workspace-nav-item" aria-label={t("Settings")} data-tip={t("Settings")} onClick={openSettings}><Settings size={18} strokeWidth={1.7} /><span>{t("Settings")}</span><span className="grow" /><ExternalLink size={11} /></button></div>
    {compact && preview && <CompactNavigationPreview {...preview} title={title(preview.page)} store={store} openSettings={openSettings} keepOpen={keepPreview} dismiss={dismissPreview} />}
  </nav>;
}
