import { ArrowDown, ArrowUp, ChevronDown, ChevronLeft, Ellipsis, GitBranch, PanelRightClose, PanelRightOpen, RefreshCcw, SquarePen, SquareTerminal } from "lucide-react";
import { structureGraphMenus } from "@/features/git-menus";
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

/** 툴바 버튼은 아이콘만. 무슨 버튼인지는 마우스를 올리면 설명 풍선으로 보여 준다. */
export function Toolbar({ store }: { store: RepoStore }) {
  useObserve(store);
  useObserve(settings);
  const inspectorCollapsed = settings.get("inspectorCollapsed", false);
  const inspectorTitle = inspectorCollapsed ? t("Show right panel") : t("Hide right panel");
  const st = store.status;
  const sheet = (s: RepoStore["sheet"]) => {
    store.sheet = s;
    store.changed();
  };
  const split = (main: React.ReactNode, mainTip: string, onMain: () => void, items: () => MenuItem[], disabled = false, prominent = false) => (
    <div className={`tool-group${prominent ? " prominent" : ""}`}>
      <button className="tool titled" data-tip={mainTip} disabled={disabled} onClick={onMain}>
        {main}
      </button>
      <button className="tool caret" disabled={disabled} onClick={(e) => showMenuBelow(e.currentTarget.parentElement!, items())} data-tip={t("More")}>
        <ChevronDown size={12} />
      </button>
    </div>
  );

  const set = toolbarSet(store.destination, !!store.path);
  // without a repository only the account control is useful; the Home page has the open and clone actions
  if (set === "noRepository")
    return (
      <div className="toolbar no-repository">
        <div className="title grow">
          <span className="name ellipsis">Gitrochi</span>
        </div>
        <AccountQuickControls store={store} />
      </div>
    );

  const recommended = recommendedSync(st.ahead, st.behind, !!st.upstream);
  const changesOn = store.destination === "repository" && store.selection?.kind === "wip";
  const lastUndo = store.undoStack[store.undoStack.length - 1];
  const repositoryMenu = (): MenuItem[] => [
    ...recents()
      .filter((p) => !samePath(p, store.path))
      .slice(0, 10)
      .map((p): MenuItem => ({ label: `${basename(p)}   —   ${displayPath(p)}`, onClick: () => void store.openOrReport(p) })),
    "divider",
    { label: t("Open repository…"), shortcut: "Ctrl+O", onClick: () => void store.pickAndOpen() },
    { label: t("Clone repository…"), shortcut: "Ctrl+Shift+O", onClick: () => sheet({ kind: "clone" }) },
    "divider",
    ...structureGraphMenus(store),
    { label: t("Repository tools…"), onClick: () => sheet({ kind: "localWorkflows" }) },
    { label: t("Work validation…"), onClick: () => sheet({ kind: "workValidation" }) },
    "divider",
    { label: t("Ask AI about changes…"), disabled: !!store.busy, onClick: () => void store.openChangeQuestion() },
    { label: t("Repository assistant…"), onClick: () => void store.openRepositoryAssistant() },
    { label: t("Connect external AI with MCP…"), onClick: () => sheet({ kind: "mcpConnection" }) },
    "divider",
    { label: t("Close tab"), shortcut: "Ctrl+W", onClick: () => workspace.closeTab(store.id) },
  ];
  // the same menu on every page: sync first, then Undo naming what it undoes, then the rest
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
    { label: t("Structure graph workspace"), disabled: !!store.busy || !!store.graphJob, onClick: () => void store.openStructureGraph("files") },
  ];
  const back = store.cameFromRepository && returnsToRepository.has(store.destination);

  return (
    <div className="toolbar">
      {back && (
        <button type="button" className="tool toolbar-back" aria-label={t("Back to the repository screen")} data-tip={keyLabel(t("Back to the repository screen (Ctrl+[)"))} onClick={() => store.returnToRepository()}>
          <ChevronLeft size={15} />
          {t("Repository")}
        </button>
      )}
      <button
        type="button"
        className="title title-menu"
        aria-haspopup="menu"
        data-tip={tip(t("Repository"), t("Open or clone another repository, recent repositories, structure graph, close tabs"))}
        onClick={(e) => showMenuBelow(e.currentTarget, repositoryMenu())}
      >
        <span className="name ellipsis">
          {store.name}
          <ChevronDown size={11} className="muted" />
        </span>
        <span className="sub ellipsis">{store.subtitle}</span>
      </button>

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
          <div className="tool-group">
            <button className="tool titled" disabled={store.busy != null} onClick={() => void store.fetch()} data-tip={tip("Fetch", t("Fetches new commits and branches from all remotes. Your branches aren't changed."), "Ctrl+Shift+F")}>
              <RefreshCcw size={16} />
              Fetch
            </button>
          </div>
          {split(
            <>
              <ArrowDown size={16} />
              Pull
            </>,
            tip(
              "Pull",
              (!st.upstream
                ? t("This branch has no remote tracking branch to pull from (push it first to create one).")
                : st.behind > 0
                  ? t("Brings {0} new commits from the remote into the current branch.", st.behind)
                  : t("Syncs the current branch with the remote (no commits to pull right now).")) + t(" Choose merge or rebase from ▾."),
              "Ctrl+Shift+L",
            ),
            () => void store.pull(),
            () => [
              { label: t("Pull (as configured in git)"), onClick: () => void store.pull("standard") },
              { label: t("Pull — fast-forward only"), onClick: () => void store.pull("fastForward") },
              { label: t("Pull — merge"), onClick: () => void store.pull("merge") },
              { label: t("Pull — rebase"), onClick: () => void store.pull("rebase") },
            ],
            !st.upstream,
            recommended === "pull",
          )}
          {split(
            <>
              <ArrowUp size={16} />
              Push
            </>,
            tip(
              "Push",
              (!st.upstream
                ? t("Pushes the current branch to the remote for the first time and sets up tracking.")
                : st.ahead > 0
                  ? t("Pushes {0} unpushed commits to the remote.", st.ahead)
                  : t("Pushes the current branch to the remote (no commits to push right now).")) + t(" Force push from ▾."),
              "Ctrl+Shift+P",
            ),
            () => void store.push(),
            () => [
              { label: t("Push"), onClick: () => void store.push() },
              { label: t("Force push (with lease)…"), onClick: () => void store.push(true) },
            ],
            false,
            recommended === "push",
          )}
          {split(
            <GitBranch size={16} />,
            tip(t("Branch"), t("Creates a new branch at the current position. From ▾: new worktree, compare revisions, run an agent (Claude Code, Codex, Gemini)."), "Ctrl+Shift+B"),
            () => store.requestNewBranch(),
            () => [
              { label: t("New branch…"), shortcut: "Ctrl+Shift+B", onClick: () => store.requestNewBranch() },
              { label: t("New worktree…"), shortcut: "Ctrl+Alt+W", onClick: () => sheet({ kind: "addWorktree", branch: null, start: null }) },
              { label: t("Compare revisions…"), shortcut: "Ctrl+3", onClick: () => store.navigate("compare") },
              "divider",
              { label: t("Stash… (save changes for later)"), shortcut: "Ctrl+Shift+S", disabled: statusIsEmpty(st), onClick: () => sheet({ kind: "stash" }) },
              { label: t("Pop (apply the latest stash)"), disabled: !store.stashes.length, onClick: () => void store.stashPop() },
              "divider",
              { label: t("Run {0} here", agentKind(agents.defaultKind).title), onClick: () => store.path && void store.startAgent(store.path) },
              { label: t("Start agent session…"), shortcut: "Ctrl+Alt+K", onClick: () => sheet({ kind: "startAgent", path: store.path }) },
            ],
          )}
        </>
      )}
      <div className="tool-group">
        <button className="tool" aria-label={t("More")} aria-haspopup="menu" data-tip={t("More")} onClick={(e) => showMenuBelow(e.currentTarget, moreMenu())}>
          <Ellipsis size={16} />
        </button>
      </div>
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
            aria-pressed={!inspectorCollapsed}
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
