import { CirclePause, ShieldAlert, TriangleAlert, Zap } from "lucide-react";
import { CircleAlert, CircleX, Ellipsis, GitBranch, Pencil, Plus, Sparkles, SquareArrowOutUpRight } from "@/shared/icons";
import { type MouseEvent, type ReactNode, useEffect } from "react";
import { agentKind, agents, type AgentSession, appDisplayName, containingRoot, type ExternalAgent, relativeFolder, skipsPermissions, type TerminalAgent } from "@/entities/agent";
import { statsClean, type Worktree, type WorktreeStats } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { sessionMark, sessionsNeedingUser, sessionWord, type TabMark, TabMarkSlot } from "@/entities/terminal";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { basename, displayPath, samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import { Button, IconButton, type MenuItem, NoticeBlock, showContextMenu, showMenuBelow } from "@/shared/ui";
import { needCaption, worktreePlace } from "../lib/agents-panel";
import { Section } from "./Section";
import "./agents-panel.css";

const kindTitle = (kind: AgentSession["kind"]) => agentKind(kind).title.split(" (")[0];

/**
 * The sidebar's Agents tab: what waits for the user first, then each worktree with the sessions in it, then agents
 * running elsewhere. Every session is drawn by one row, with the terminal tab's marks and words. (macOS: AgentsPanel)
 */
export function AgentsPanel({ store }: { store: RepoStore }) {
  useObserve(agents);
  useObserve(settings);
  const paths = store.worktrees.map((w) => w.path).join("|");
  useEffect(() => {
    // the store polls other worktrees while this tab is in front; count once right away
    void store.refreshWorktreeStats();
  }, [store, paths]);

  useEffect(() => {
    // agents in other apps are looked up only while this panel shows in the front tab (at most every 5 s)
    const tick = () => { if (store.isActive && document.visibilityState === "visible") void agents.refreshExternal(); };
    tick();
    const timer = setInterval(tick, 5000);
    return () => clearInterval(timer);
  }, [store]);
  const roots = [...store.worktrees.map((w) => w.path), ...(store.path ? [store.path] : [])];
  const elsewhere = agents.externalIn(roots);
  // typed into a terminal tab of this window tab or another one; each shows under the worktree it works in
  const worktreePaths = store.worktrees.map((w) => w.path);
  const typed = agents.terminalAgentsIn(worktreePaths, [store, ...workspace.tabs.filter((tab) => tab !== store)]);
  const inWorktree = (s: AgentSession) => store.worktrees.some((w) => samePath(w.path, s.path));
  const needs = sessionsNeedingUser(agents.sessions);
  const ended = agents.sessions.filter((s) => s.status === "ended" && inWorktree(s));
  const others = agents.sessions.filter((s) => !inWorktree(s) && s.status !== "ended");
  const mainPath = store.worktrees.find((w) => w.isMain)?.path ?? null;
  const endedOpen = settings.get("agentsEndedOpen", false);
  const sheet = (s: RepoStore["sheet"]) => {
    store.sheet = s;
    store.changed();
  };
  const hasEnded = agents.sessions.some((s) => s.status === "ended");
  const prunable = store.worktrees.some((w) => w.prunable);
  const more = (): MenuItem[] => [
    ...(prunable ? [{ label: t("Clean up"), onClick: () => void store.pruneWorktrees() }] : []),
    ...(hasEnded ? [{ label: t("Clear ended sessions"), onClick: () => void agents.clearEnded() }] : []),
  ];
  return (
    <div className="side-scroll agents-panel">
      <div className="agents-start">
        <Button className="grow" onClick={() => sheet({ kind: "startAgent", path: null })}>
          <Sparkles size={13} />
          <span className="ellipsis">{t("Start agent session…")}</span>
        </Button>
        <Button className="agents-start-now" aria-label={t("Start {0} in this worktree now", kindTitle(agents.defaultKind))} tip={t("Start {0} in this worktree now", kindTitle(agents.defaultKind))}
          onClick={() => store.path && void store.startAgent(store.path)}>
          <Zap size={13} />
        </Button>
      </div>

      {needs.length > 0 && (
        <Section id="agent-needs" title={t("Needs you")} count={needs.length}>
          <div className="agents-list">
            {needs.map((s) => <NeedCard key={s.id} session={s} />)}
          </div>
        </Section>
      )}

      <Section
        id="agent-worktrees"
        title={t("Worktrees")}
        count={store.worktrees.length}
        actions={
          <>
            <IconButton small icon={<Plus size={13} />} aria-label={t("New worktree…")} tip={t("New worktree…")} onClick={() => sheet({ kind: "addWorktree", branch: null, start: null })} />
            {(hasEnded || prunable) && (
              <IconButton small className="agents-more" icon={<Ellipsis size={14} />} aria-haspopup="menu" aria-label={t("More agent actions")} tip={t("More agent actions")} onClick={(e) => showMenuBelow(e.currentTarget, more())} />
            )}
          </>
        }
      >
        <div className="agents-list">
          {store.worktrees.map((w) => (
            <WorktreeGroup key={w.path} store={store} worktree={w} stats={store.worktreeStats[w.path]} mainPath={mainPath}
              sessions={agents.sessionsIn(w.path).filter((s) => s.status !== "ended")}
              typed={typed.filter((x) => samePath(containingRoot(x.agent.cwd, worktreePaths) ?? "", w.path))} isCurrent={samePath(w.path, store.path)} />
          ))}
        </div>
        {ended.length > 0 && (
          <Section id="agent-ended" title={t("Ended")} count={ended.length} open={endedOpen} onToggle={() => settings.set("agentsEndedOpen", !endedOpen)}>
            <div className="agents-list">
              {ended.map((s) => <SessionRow key={s.id} store={store} session={s} place={store.worktrees.find((w) => samePath(w.path, s.path))?.branch ?? basename(s.path)} />)}
            </div>
          </Section>
        )}
      </Section>

      {(elsewhere.length > 0 || others.length > 0) && (
        <Section id="agent-elsewhere" title={t("Elsewhere")}>
          <div className="agents-list">
            {elsewhere.map((a) => <ExternalAgentRow key={a.pid} store={store} agent={a} roots={roots} />)}
            {others.map((s) => <SessionRow key={s.id} store={store} session={s} place={displayPath(s.path)} flat />)}
          </div>
        </Section>
      )}

      <span className="agents-note">{t("Sessions started here run in the terminal tabs below; click one to go to its terminal.")}</span>
    </div>
  );
}

/** A session that waits for the user: what it waits for, which session, and the way to its terminal */
function NeedCard({ session: s }: { session: AgentSession }) {
  const can = agents.canFocus(s);
  return (
    <NoticeBlock
      className="agent-need"
      icon={s.status === "permission" ? <CircleAlert size={14} /> : <CirclePause size={14} />}
      tone="waiting"
      title={t(sessionWord(s.status))}
      caption={needCaption({ task: s.task, folder: basename(s.path), kind: kindTitle(s.kind), detail: s.status === "permission" ? s.detail : null, ago: shortDate(s.updated) })}
      actions={can ? [{ label: t("Respond"), onClick: () => agents.focus(s) }] : []}
    />
  );
}

/** A worktree and, indented under it, the sessions working in it */
function WorktreeGroup({ store, worktree: w, stats, sessions, typed, isCurrent, mainPath }: { store: RepoStore; worktree: Worktree; stats?: WorktreeStats; sessions: AgentSession[]; typed: TerminalAgent[]; isCurrent: boolean; mainPath: string | null }) {
  const startHere = () => {
    store.sheet = { kind: "startAgent", path: w.path };
    store.changed();
  };
  const changed = stats ? stats.added + stats.modified + stats.deleted : 0;
  return (
    <>
      <div
        className="agent-worktree"
        data-path={w.path}
        aria-current={isCurrent ? "true" : undefined}
        onDoubleClick={() => !isCurrent && void store.switchWorktree(w.path)}
        onContextMenu={(e) =>
          showContextMenu(e, [
            { label: t("Start agent session…"), onClick: startHere },
            { label: t("Open worktree"), disabled: isCurrent, onClick: () => void store.switchWorktree(w.path) },
            { label: t("Open in new tab"), disabled: isCurrent, onClick: () => void store.openOrReport(w.path) },
            { label: t("Show in Explorer"), onClick: () => void ipc.reveal(w.path) },
            { label: t("Open in the terminal below"), onClick: () => store.newTerminal(w.path) },
            { label: t("Open in external terminal"), onClick: () => void ipc.openTerminal(w.path) },
            { label: t("Copy path"), onClick: () => store.copy(displayPath(w.path)) },
            "divider",
            { label: t("Remove worktree…"), danger: true, disabled: w.isMain || isCurrent, onClick: () => store.confirmRemove(w) },
            { label: t("Force remove…"), danger: true, disabled: w.isMain || isCurrent, onClick: () => store.confirmRemove(w, true) },
          ])
        }
      >
        <span className="agent-worktree-line">
          {isCurrent ? (
            <span className="side-current" role="img" aria-label={t("Current")}><span /></span>
          ) : (
            <span className="agent-worktree-icon" aria-hidden="true"><GitBranch size={13} /></span>
          )}
          <span className="ellipsis agent-worktree-name">{w.branch ?? t("Detached HEAD")}</span>
          {/* one state icon: a folder that is gone outranks a conflict, which outranks plain uncommitted files */}
          {w.prunable ? (
            <span className="agent-state status-tone" data-tone="waiting" data-state="prunable" role="img" aria-label={t("Worktree whose folder is gone — remove it with 'Clean up'")} data-tip={t("Worktree whose folder is gone — remove it with 'Clean up'")}><TriangleAlert size={12} /></span>
          ) : stats && stats.conflicted > 0 ? (
            <span className="agent-state status-tone" data-tone="failed" data-state="conflict" role="img" aria-label={`${t("Conflict")} ${stats.conflicted}`} data-tip={`${t("Conflict")} ${stats.conflicted}`}><CircleX size={12} /></span>
          ) : stats && !statsClean(stats) && changed > 0 ? (
            <span className="agent-state" data-state="changed" role="img" aria-label={`${t("Uncommitted changes")} ${changed}`} data-tip={`${t("Uncommitted changes")} ${changed}`}><Pencil size={12} /></span>
          ) : null}
        </span>
        <span className="agent-worktree-line2">
          <span className="ellipsis mono agent-worktree-path" data-tip={displayPath(w.path)}>{worktreePlace(displayPath(w.path), w.path === mainPath)}</span>
          {stats && stats.ahead > 0 && <span className="agent-ab" data-tip={t("Commits not pushed to the remote")}>↑{stats.ahead}</span>}
          {stats && stats.behind > 0 && <span className="agent-ab" data-tip={t("Commits not pulled from the remote")}>↓{stats.behind}</span>}
        </span>
      </div>
      {sessions.map((s) => <SessionRow key={s.id} store={store} session={s} />)}
      {typed.map((x) => <TerminalAgentRow key={x.agent.pid} store={store} typed={x} root={w.path} />)}
    </>
  );
}

/**
 * The one row every session is drawn by: the terminal tab's mark in its 12px slot, "Agent · what it does" on up to
 * two lines, then what only some rows have (the skipped permission checks, where it runs).
 */
function AgentRow({ mark, word, kind, text, tone, skips, place, flat, className = "", trailing, onClick, onContextMenu, ...data }: {
  mark: TabMark;
  /** The state in words, for the tooltip and assistive technology (the mark alone shows it) */
  word: string;
  kind: string;
  text?: string | null;
  /** Draws the text as a state word in its tone (an agent in another app has no task to show) */
  tone?: "waiting";
  skips?: boolean;
  place?: string | null;
  /** Not indented under a worktree */
  flat?: boolean;
  className?: string;
  trailing?: ReactNode;
  onClick?: () => void;
  onContextMenu?: (e: MouseEvent) => void;
  "data-pid"?: number;
  "data-status"?: string;
}) {
  return (
    <div className={`agent-session ${flat ? "flat" : ""} ${onClick ? "clickable" : ""} ${className}`} role="group" aria-label={[kind, word, text].filter(Boolean).join(", ")} data-tip={word} onClick={onClick} onContextMenu={onContextMenu} {...data}>
      <span className="agent-session-main">
        <span className="agent-session-line">
          <TabMarkSlot mark={mark} />
          <span className="agent-session-text">
            <span className="agent-session-kind">{kind}</span>
            {text && <> · {tone ? <span className="agent-session-word status-tone" data-tone={tone}>{text}</span> : text}</>}
          </span>
        </span>
        {skips && (
          <span className="agent-session-skips status-tone" data-tone="waiting" data-tip={t("Started with all permission checks skipped")}>
            <ShieldAlert size={12} />
            {t("Skips permissions")}
          </span>
        )}
        {place && <span className="agent-session-place ellipsis">{place}</span>}
      </span>
      {trailing}
    </div>
  );
}

function SessionRow({ store, session: s, place, flat }: { store: RepoStore; session: AgentSession; place?: string; flat?: boolean }) {
  const can = agents.canFocus(s);
  return (
    <AgentRow
      mark={sessionMark(s.status)}
      word={t(sessionWord(s.status))}
      kind={kindTitle(s.kind)}
      text={s.task}
      skips={skipsPermissions(s.kind, s.mode)}
      place={place}
      flat={flat}
      data-status={s.status}
      onClick={can ? () => agents.focus(s) : undefined}
      onContextMenu={(e) =>
        showContextMenu(e, [
          { label: t("Go to terminal"), disabled: !can, onClick: () => agents.focus(s) },
          { label: t("New session in the same place"), onClick: () => void store.startAgent(s.path, "", null, s.kind) },
          "divider",
          s.status === "ended"
            ? { label: t("Remove from list"), onClick: () => void agents.remove(s.id) }
            : {
                label: t("End session…"),
                danger: true,
                onClick: () =>
                  store.ask({ title: t("End the {0} session?", agentKind(s.kind).title), message: s.task || s.path, actionTitle: t("End"), action: () => agents.stop(s) }),
              },
        ])
      }
    />
  );
}

/** An agent typed into a tab of the terminal below (not started from here); clicking goes to that tab (macOS: TerminalAgentRow) */
function TerminalAgentRow({ store, typed: { agent, term, host }, root }: { store: RepoStore; typed: TerminalAgent; root: string }) {
  const go = () => host.focusTerminal(term);
  return (
    <AgentRow
      className="terminal-agent"
      mark="ring"
      word={t("Running")}
      kind={kindTitle(agent.kind)}
      place={relativeFolder(agent.cwd, root) || null}
      data-pid={agent.pid}
      onClick={go}
      onContextMenu={(e) =>
        showContextMenu(e, [
          { label: t("Go to terminal"), onClick: go },
          { label: t("Copy folder path"), onClick: () => store.copy(agent.cwd) },
        ])
      }
    />
  );
}

/** An agent running in another app; the button brings that app to the front (macOS: ExternalAgentRow) */
function ExternalAgentRow({ store, agent, roots }: { store: RepoStore; agent: ExternalAgent; roots: string[] }) {
  const host = agent.hostExe ? appDisplayName(agent.hostExe) : t("Unknown app");
  const root = containingRoot(agent.cwd, roots);
  const worktree = root ? store.worktrees.find((w) => samePath(w.path, root)) : undefined;
  // "branch · sub/folder"
  const place = [root ? worktree?.branch ?? basename(root) : displayPath(agent.cwd), root ? relativeFolder(agent.cwd, root) : ""].filter(Boolean).join(" · ");
  const forward = () => void agents.bringForward(agent).catch((e: unknown) => store.fail(e));
  return (
    <AgentRow
      className="external-agent"
      flat
      mark="ring"
      word={t("Running")}
      kind={kindTitle(agent.kind)}
      text={t("Running")}
      tone="waiting"
      place={place}
      data-pid={agent.pid}
      onClick={forward}
      trailing={
        <IconButton small className="agent-forward" icon={<SquareArrowOutUpRight size={13} />} aria-label={t("Bring {0} to the front", host)} tip={t("Bring {0} to the front", host)} disabled={agent.hostPid === null}
          onClick={(e) => { e.stopPropagation(); forward(); }} />
      }
      onContextMenu={(e) =>
        showContextMenu(e, [
          { label: t("Bring {0} to the front", host), disabled: agent.hostPid === null, onClick: forward },
          { label: t("Copy folder path"), onClick: () => store.copy(agent.cwd) },
        ])
      }
    />
  );
}
