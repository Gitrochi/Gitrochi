import { ArrowDown, ArrowUp, ChevronDown, FolderOpen, GitBranch, GitPullRequestArrow, PackageOpen, PanelRightClose, PanelRightOpen, RefreshCcw, SquarePen, SquareTerminal, Undo2 } from "lucide-react";
import { structureGraphMenus } from "@/features/git-menus";
import { agentKind, agents } from "@/entities/agent";
import { providerInfo, statusIsEmpty } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { basename, displayPath, recents, samePath, settings } from "@/shared/config";
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
  const split = (main: React.ReactNode, mainTip: string, onMain: () => void, items: () => MenuItem[], disabled = false) => (
    <div className="tool-group">
      <button className="tool" data-tip={mainTip} disabled={disabled} onClick={onMain}>
        {main}
      </button>
      <button className="tool caret" disabled={disabled} onClick={(e) => showMenuBelow(e.currentTarget.parentElement!, items())} data-tip={t("More")}>
        <ChevronDown size={12} />
      </button>
    </div>
  );

  // without a repository only the account control is useful; the Home page has the open and clone actions
  if (!store.path)
    return (
      <div className="toolbar no-repository">
        <div className="title grow">
          <span className="name ellipsis">Gitrochi</span>
        </div>
        <AccountQuickControls store={store} />
      </div>
    );

  return (
    <div className="toolbar">
      <div className="tool-group">
        <button
          className="tool"
          data-tip={tip(t("Repository"), t("Open or clone another repository, recent repositories, structure graph, close tabs"))}
          onClick={(e) =>
            showMenuBelow(e.currentTarget, [
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
              "divider",
              { label: t("Ask AI about changes…"), disabled: !!store.busy, onClick: () => void store.openChangeQuestion() },
              { label: t("Repository assistant…"), onClick: () => void store.openRepositoryAssistant() },
              { label: t("Connect external AI with MCP…"), onClick: () => sheet({ kind: "mcpConnection" }) },
              "divider",
              { label: t("Close tab"), shortcut: "Ctrl+W", onClick: () => workspace.closeTab(store.id) },
            ])
          }
        >
          <FolderOpen size={16} />
          <ChevronDown size={11} />
        </button>
      </div>
      <div className="title grow">
        <span className="name ellipsis">{store.name}</span>
        <span className="sub ellipsis">{store.subtitle}</span>
      </div>

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

      <div className="tool-group">
        <button
          className="tool"
          disabled={!store.undoStack.length || store.busy != null}
          onClick={() => store.confirmUndo()}
          data-tip={tip(
            t("Undo"),
            store.undoStack.length
              ? t("Undoes the last operation, “{0}”. Undoing a commit keeps its changes.", store.undoStack[store.undoStack.length - 1].title)
              : t("Nothing to undo. Operations like commit, merge, rebase, checkout and branch deletion can be undone here."),
            "Ctrl+Z",
          )}
        >
          <Undo2 size={16} />
        </button>
        <button
          className="tool"
          onClick={() => { store.navigate("repository"); store.select({ kind: "wip" }); }}
          data-tip={tip(
            t("Uncommitted changes"),
            statusIsEmpty(st) ? t("No modified files. When you edit files, you can stage and commit them here.") : t("{0} modified files — stage and commit them.", store.wipCount),
            "Ctrl+1",
          )}
        >
          <SquarePen size={16} />
          {!statusIsEmpty(st) && <span className="badge-num">{store.wipCount}</span>}
        </button>
        <button className="tool" onClick={() => void store.fetch()} data-tip={tip("Fetch", t("Fetches new commits and branches from all remotes. Your branches aren't changed."), "Ctrl+Shift+F")}>
          <RefreshCcw size={16} />
        </button>
      </div>

      {split(
        <>
          <ArrowDown size={16} />
          {st.behind > 0 && <span className="badge-num">{st.behind}</span>}
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
      )}

      {split(
        <>
          <ArrowUp size={16} />
          {st.ahead > 0 && <span className="badge-num">{st.ahead}</span>}
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
          {
            label: t("Force push (with lease)…"),
            onClick: () => void store.push(true),
          },
        ],
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
          { label: t("Run {0} here", agentKind(agents.defaultKind).title), onClick: () => store.path && void store.startAgent(store.path) },
          { label: t("Start agent session…"), shortcut: "Ctrl+Alt+K", onClick: () => sheet({ kind: "startAgent", path: store.path }) },
        ],
      )}

      {store.target && (
        <div className="tool-group">
          <button
            className="tool"
            disabled={!store.headBranch}
            onClick={() => sheet({ kind: "createPullRequest" })}
            data-tip={tip(
              t("New {0}", providerInfo[store.target.provider].requestShort),
              t("Creates a {1} from the current branch ({0}). Pushes first if needed.", store.headBranch ?? "-", providerInfo[store.target.provider].requestName),
            )}
          >
            <GitPullRequestArrow size={16} />
          </button>
        </div>
      )}

      {split(
        <>
          <PackageOpen size={16} />
          {store.stashes.length > 0 && <span className="badge-num">{store.stashes.length}</span>}
        </>,
        tip(
          "Stash",
          (statusIsEmpty(st) ? t("Applies the most recently stashed changes (Pop).") : t("Saves uncommitted changes for later.")) +
            (store.stashes.length ? t(" {0} stashes saved.", store.stashes.length) : "") +
            t(" Choose Stash or Pop from ▾."),
          "Ctrl+Shift+S",
        ),
        () => (!statusIsEmpty(st) ? sheet({ kind: "stash" }) : void store.stashPop()),
        () => [
          { label: t("Stash… (save changes for later)"), disabled: statusIsEmpty(st), onClick: () => sheet({ kind: "stash" }) },
          { label: t("Pop (apply the latest stash)"), disabled: !store.stashes.length, onClick: () => void store.stashPop() },
        ],
        statusIsEmpty(st) && !store.stashes.length,
      )}

      <div className="tool-group">
        <button
          className={`tool ${store.showTerminal ? "on" : ""}`}
          onClick={() => store.toggleTerminal()}
          data-tip={tip(
            t("Terminal"),
            store.showTerminal ? t("Hides the terminal panel below. Shells keep running.") : t("Opens a terminal in this repository's folder below the graph. The graph updates as soon as you run git commands."),
            "Ctrl+`",
          )}
        >
          <SquareTerminal size={16} />
        </button>
      </div>
      {store.destination === "repository" && (
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
      <AccountQuickControls store={store} />
    </div>
  );
}
