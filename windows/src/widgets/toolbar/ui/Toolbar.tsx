import { ArrowDown, ArrowUp, ChevronDown, ChevronLeft, Ellipsis, Folder, GitBranch, PanelLeft, PanelRightClose, PanelRightOpen, RefreshCcw, SquarePen, SquareTerminal } from "lucide-react";
import { agentKind, agents } from "@/entities/agent";
import { providerInfo, recommendedSync, returnsToRepository, statusIsEmpty, toolbarSet } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { basename, displayPath, keyLabel, recents, samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { type MenuItem, showMenuBelow, Spinner, tip } from "@/shared/ui";
import { AccountQuickControls } from "./AccountQuickControls";
import "./toolbar.css";

/**
 * The window toolbar (docs/design.md › App shell): the sidebar toggle and the repository button lead, the page's actions
 * trail, every group in a 36px capsule 8px from the next. Repository pages get the Git actions, other pages More and the
 * terminal, a window without a repository only the account. (macOS: RepoView.swift)
 */
export function Toolbar({ store }: { store: RepoStore }) {
  useObserve(store);
  useObserve(settings);
  const inspectorCollapsed = settings.get("inspectorCollapsed", false);
  const inspectorTitle = inspectorCollapsed ? t("Show right panel") : t("Hide right panel");
  const navigationCollapsed = settings.get("navigationSidebarCollapsed", false);
  const sidebarTitle = navigationCollapsed ? t("Expand sidebar") : t("Collapse sidebar");
  const st = store.status;
  const sheet = (s: RepoStore["sheet"]) => {
    store.sheet = s;
    store.changed();
  };
  const set = toolbarSet(store.destination, !!store.path);
  // the current branch, then a few others, pinned ones first
  const menuBranches = [
    ...store.localBranches.filter((b) => b.isCurrent),
    ...store.localBranches
      .filter((b) => !b.isCurrent)
      .sort((a, b) => Number(store.isPinned(b)) - Number(store.isPinned(a)) || a.name.localeCompare(b.name, undefined, { numeric: true }))
      .slice(0, 4),
  ];
  // the repository menu (docs/design.md › App shell): switch the branch, then the repository, then close the tab;
  // the repository-wide tools are under More
  const repositoryMenu = (): MenuItem[] => [
    ...(store.path
      ? ([
          ...menuBranches.map((b): MenuItem => ({ label: b.name, checked: b.isCurrent, onClick: () => void (b.isCurrent || store.checkout(b)) })),
          // a menu has no filter field; the repository screen lists every branch
          { label: t("All branches…"), onClick: () => store.navigate("repository") },
          { label: t("New branch…"), shortcut: "Ctrl+Shift+B", onClick: () => store.requestNewBranch() },
          ...(st.upstream ? [{ label: t("Compare with {0}", st.upstream), onClick: () => store.showRevisionComparison(st.upstream!, "HEAD") }] : []),
          "divider",
          { label: store.name, checked: true },
        ] as MenuItem[])
      : []),
    ...recents()
      .filter((p) => !samePath(p, store.path))
      .slice(0, 5)
      .map((p): MenuItem => ({ label: basename(p), tip: displayPath(p), onClick: () => void store.openOrReport(p) })),
    { label: t("Open repository…"), shortcut: "Ctrl+O", onClick: () => void store.pickAndOpen() },
    { label: t("Clone repository…"), shortcut: "Ctrl+Shift+O", onClick: () => sheet({ kind: "clone" }) },
    "divider",
    { label: t("Close tab"), shortcut: "Ctrl+W", onClick: () => workspace.closeTab(store.id) },
  ];
  // the repository button's second line: the branch with ↑↓ beside it, or what is in progress instead of the counts
  const branch = store.headBranch ?? (store.headHash ? t("Detached HEAD · {0}", store.headHash.slice(0, 7)) : "");
  const counts = st.upstream ? [st.ahead > 0 ? `↑${st.ahead}` : "", st.behind > 0 ? `↓${st.behind}` : ""].filter(Boolean) : [];
  const leading = (
    <>
      <div className="tool-group">
        <button type="button" className="tool sidebar-toggle" aria-label={sidebarTitle} aria-expanded={!navigationCollapsed} data-tip={tip(sidebarTitle, "", "Ctrl+B")} onClick={() => settings.set("navigationSidebarCollapsed", !navigationCollapsed)}>
          <PanelLeft size={16} />
        </button>
      </div>
      <div className="tool-group picker">
        <button
          type="button"
          className="title-menu"
          aria-haspopup="menu"
          data-tip={tip(t("Repository"), t("Switch branch or repository, open or clone one, or close the tab"))}
          onClick={(e) => showMenuBelow(e.currentTarget, repositoryMenu())}
        >
          <Folder size={16} />
          <span className="picker-text">
            <span className="name ellipsis">{store.path ? store.name : "Gitrochi"}</span>
            {store.path && (
              <span className="sub">
                <span className="ellipsis">{branch}</span>
                {store.repoState !== "clean" ? (
                  <span className="state">{store.repoStateTitle}</span>
                ) : (
                  counts.length > 0 && (
                    <span className="counts">
                      {counts.map((count) => (
                        <span key={count}>{count}</span>
                      ))}
                    </span>
                  )
                )}
              </span>
            )}
          </span>
          <ChevronDown size={9} strokeWidth={2.2} className="picker-chevron" />
        </button>
      </div>
    </>
  );
  // without a repository only the account control is useful; the Home page has the open and clone actions
  if (set === "noRepository")
    return (
      <div className="toolbar no-repository">
        {leading}
        <span className="toolbar-spacer" />
        <AccountQuickControls store={store} />
      </div>
    );

  const recommended = recommendedSync(st.ahead, st.behind, !!st.upstream);
  const changesOn = store.destination === "repository" && store.selection?.kind === "wip";
  const lastUndo = store.undoStack[store.undoStack.length - 1];
  // the same menu on every page (docs/design.md › App shell): Fetch, Pull and Push first so pages without those buttons
  // still reach them, then Undo naming what it undoes, the pull and push options, and the repository-wide tools
  const moreMenu = (): MenuItem[] => [
    { label: "Fetch", shortcut: "Ctrl+Shift+F", disabled: store.busy != null, onClick: () => void store.fetch() },
    { label: "Pull", shortcut: "Ctrl+Shift+L", disabled: store.busy != null || !st.upstream, onClick: () => void store.pull() },
    { label: "Push", shortcut: "Ctrl+Shift+P", disabled: store.busy != null, onClick: () => void store.push() },
    "divider",
    { label: lastUndo ? t("Undo: {0}", lastUndo.title) : t("Undo"), shortcut: "Ctrl+Z", disabled: !lastUndo || store.busy != null, onClick: () => store.confirmUndo() },
    "divider",
    ...(store.target
      ? [{ label: t("New {0}…", providerInfo[store.target.provider].requestShort), disabled: !store.headBranch, onClick: () => sheet({ kind: "createPullRequest" }) } as MenuItem]
      : []),
    {
      label: t("Pull options"),
      disabled: store.busy != null || !st.upstream,
      submenu: [
        { label: t("Pull as configured in git"), onClick: () => void store.pull("standard") },
        { label: t("Fast-forward only"), onClick: () => void store.pull("fastForward") },
        { label: t("Merge"), onClick: () => void store.pull("merge") },
        { label: t("Rebase"), onClick: () => void store.pull("rebase") },
      ],
    },
    { label: t("Force push (with lease)…"), disabled: store.busy != null, onClick: () => void store.push(true) },
    "divider",
    { label: t("Structure graph workspace"), disabled: !!store.busy || !!store.graphJob, onClick: () => void store.openStructureGraph("files") },
    { label: t("Repository tools…"), onClick: () => sheet({ kind: "localWorkflows" }) },
    { label: t("Work validation…"), onClick: () => sheet({ kind: "workValidation" }) },
    "divider",
    { label: t("Ask AI about changes…"), disabled: !!store.busy, onClick: () => void store.openChangeQuestion() },
    { label: t("Repository assistant…"), onClick: () => void store.openRepositoryAssistant() },
    { label: t("Connect external AI with MCP…"), onClick: () => sheet({ kind: "mcpConnection" }) },
  ];
  const branchMenu = (): MenuItem[] => [
    { label: t("New branch…"), shortcut: "Ctrl+Shift+B", onClick: () => store.requestNewBranch() },
    { label: t("New worktree…"), shortcut: "Ctrl+Alt+W", onClick: () => sheet({ kind: "addWorktree", branch: null, start: null }) },
    { label: t("Compare revisions…"), shortcut: "Ctrl+3", onClick: () => store.navigate("compare") },
    "divider",
    { label: t("Stash changes…"), shortcut: "Ctrl+Shift+S", disabled: statusIsEmpty(st), onClick: () => sheet({ kind: "stash" }) },
    { label: store.stashes.length ? t("Pop latest stash") : t("Pop latest stash (none saved)"), disabled: !store.stashes.length, onClick: () => void store.stashPop() },
    "divider",
    { label: t("Start {0} here", agentKind(agents.defaultKind).title), onClick: () => store.path && void store.startAgent(store.path) },
    { label: t("Start agent session…"), shortcut: "Ctrl+Alt+K", onClick: () => sheet({ kind: "startAgent", path: store.path }) },
  ];
  const fetchButton = (
    <button className="tool titled" disabled={store.busy != null} onClick={() => void store.fetch()} data-tip={tip("Fetch", t("Fetches new commits and branches from all remotes. Your branches aren't changed."), "Ctrl+Shift+F")}>
      <RefreshCcw size={16} />
      Fetch
    </button>
  );
  const pullButton = (
    <button
      className="tool titled"
      disabled={store.busy != null || !st.upstream}
      onClick={() => void store.pull()}
      data-tip={tip(
        "Pull",
        !st.upstream
          ? t("This branch has no remote tracking branch to pull from (push it first to create one).")
          : st.behind > 0
            ? t("Brings {0} new commits from the remote into the current branch.", st.behind)
            : t("Syncs the current branch with the remote (no commits to pull right now)."),
        "Ctrl+Shift+L",
      )}
    >
      <ArrowDown size={16} />
      Pull
    </button>
  );
  const pushButton = (
    <button
      className="tool titled"
      disabled={store.busy != null}
      onClick={() => void store.push()}
      data-tip={tip(
        "Push",
        !st.upstream
          ? t("Pushes the current branch to the remote for the first time and sets up tracking.")
          : st.ahead > 0
            ? t("Pushes {0} unpushed commits to the remote.", st.ahead)
            : t("Pushes the current branch to the remote (no commits to push right now)."),
        "Ctrl+Shift+P",
      )}
    >
      <ArrowUp size={16} />
      Push
    </button>
  );
  const back = store.cameFromRepository && returnsToRepository.has(store.destination);

  return (
    <div className="toolbar">
      {leading}
      {back && (
        <div className="tool-group">
          <button type="button" className="tool titled" aria-label={t("Back to the repository screen")} data-tip={keyLabel(t("Back to the repository screen (Ctrl+[)"))} onClick={() => store.returnToRepository()}>
            <ChevronLeft size={16} />
            {t("Repository")}
          </button>
        </div>
      )}
      <span className="toolbar-spacer" />

      {store.busy && (
        <span className="busy">
          <Spinner size={13} /> {store.busy}
        </span>
      )}
      {!store.busy && store.graphProgress && (
        <span className="busy">
          <Spinner size={13} /> {store.graphProgress}
        </span>
      )}

      {set === "repository" && (
        <>
          <div className="tool-group">
            <button
              className={`tool titled ${changesOn ? "on" : ""}`}
              aria-pressed={changesOn}
              onClick={() => {
                if (changesOn) {
                  if (store.headHash) store.select({ kind: "commit", sha: store.headHash });
                } else if (store.navigate("repository")) store.select({ kind: "wip" });
              }}
              data-tip={tip(
                t("Uncommitted changes"),
                statusIsEmpty(st) ? t("No modified files. When you edit files, you can stage and commit them here.") : t("{0} modified files — stage and commit them.", store.wipCount),
                "Ctrl+1",
              )}
            >
              <SquarePen size={16} />
              {statusIsEmpty(st) ? t("Changes") : t("Changes {0}", store.wipCount)}
            </button>
          </div>
          {/* Fetch, Pull and Push share a capsule; the recommended one moves into a filled capsule of its own */}
          {recommended === "pull" ? (
            <>
              <div className="tool-group">{fetchButton}</div>
              <div className="tool-group prominent">{pullButton}</div>
              <div className="tool-group">{pushButton}</div>
            </>
          ) : recommended === "push" ? (
            <>
              <div className="tool-group">
                {fetchButton}
                {pullButton}
              </div>
              <div className="tool-group prominent">{pushButton}</div>
            </>
          ) : (
            <div className="tool-group">
              {fetchButton}
              {pullButton}
              {pushButton}
            </div>
          )}
          <div className="tool-group">
            <button className="tool" aria-label={t("Branch")} aria-haspopup="menu" data-tip={t("Branch")} onClick={(e) => showMenuBelow(e.currentTarget, branchMenu())}>
              <GitBranch size={16} />
              <ChevronDown size={9} strokeWidth={2.2} />
            </button>
            <button className="tool" aria-label={t("More")} aria-haspopup="menu" data-tip={t("More")} onClick={(e) => showMenuBelow(e.currentTarget, moreMenu())}>
              <Ellipsis size={16} />
            </button>
          </div>
        </>
      )}
      {set === "page" && (
        <div className="tool-group">
          <button className="tool" aria-label={t("More")} aria-haspopup="menu" data-tip={t("More")} onClick={(e) => showMenuBelow(e.currentTarget, moreMenu())}>
            <Ellipsis size={16} />
          </button>
        </div>
      )}
      <div className="tool-group">
        <button
          className={`tool ${store.showTerminal ? "on" : ""}`}
          aria-pressed={store.showTerminal}
          aria-label={store.showTerminal ? t("Hide terminal") : t("Terminal")}
          onClick={() => store.toggleTerminal()}
          data-tip={tip(
            t("Terminal"),
            store.showTerminal ? t("Hides the terminal panel below. Shells keep running.") : t("Opens a terminal in this repository's folder below the graph. The graph updates as soon as you run git commands."),
            "Ctrl+`",
          )}
        >
          <SquareTerminal size={16} />
        </button>
        {set === "repository" && (
          <button
            className={`tool ${inspectorCollapsed ? "" : "on"}`}
            aria-label={inspectorTitle}
            aria-expanded={!inspectorCollapsed}
            onClick={() => settings.set("inspectorCollapsed", !inspectorCollapsed)}
            data-tip={tip(inspectorTitle, "", "Ctrl+Alt+B")}
          >
            {inspectorCollapsed ? <PanelRightOpen size={16} /> : <PanelRightClose size={16} />}
          </button>
        )}
      </div>
      <AccountQuickControls store={store} />
    </div>
  );
}
