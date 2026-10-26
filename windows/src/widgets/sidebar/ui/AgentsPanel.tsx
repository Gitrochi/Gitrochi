import { GitBranch, House, Pencil, Plus, ShieldOff, Sparkles, Zap } from "lucide-react";
import { useEffect } from "react";
import { agentKind, agents, type AgentSession, type AgentStatus, agentStatusTitle, skipsPermissions } from "@/entities/agent";
import { statsClean, type Worktree, type WorktreeStats } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { displayPath, samePath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import { Button, IconButton, showContextMenu } from "@/shared/ui";

/** 사이드바 '에이전트' 탭: 워크트리 카드 + 그 안에서 도는 Claude Code 세션 */
export function AgentsPanel({ store }: { store: RepoStore }) {
  useObserve(agents);
  const paths = store.worktrees.map((w) => w.path).join("|");
  useEffect(() => {
    // 다른 워크트리는 파일 감시 대상이 아니라 몇 초마다 다시 센다
    void store.refreshWorktreeStats();
    const secs = setInterval(() => void store.refreshWorktreeStats(), 5000);
    return () => clearInterval(secs);
  }, [store, paths]);

  const others = agents.sessions.filter((s) => !store.worktrees.some((w) => samePath(w.path, s.path)) && s.status !== "ended");
  const sheet = (s: RepoStore["sheet"]) => {
    store.sheet = s;
    store.changed();
  };
  return (
    <div className="side-scroll col" style={{ gap: 10, padding: 10 }}>
      <div className="row">
        <span style={{ fontWeight: 600 }}>{t("Worktrees")}</span>
        <span className="muted">{store.worktrees.length}</span>
        <span className="spacer" />
        {agents.sessions.some((s) => s.status === "ended") && (
          <button className="link" onClick={() => void agents.clearEnded()}>
            {t("Clear ended sessions")}</button>
        )}
        <IconButton small icon={<Plus size={13} />} tip={t("New worktree")} onClick={() => sheet({ kind: "addWorktree", branch: null, start: null })} />
      </div>
      <div className="row">
        <Button size="large" className="grow" onClick={() => sheet({ kind: "startAgent", path: null })} tip={t("Start agent session|Choose Claude Code, Codex or Gemini CLI, a worktree to work in, and a task")}>
          <Sparkles size={14} /> {" "}{t("Start session")}</Button>
        <Button size="large" onClick={() => store.path && void store.startAgent(store.path)} tip={t("Start {0} in this worktree now", agentKind(agents.defaultKind).title)}>
          <Zap size={14} />
        </Button>
      </div>
      {store.worktrees.map((w) => (
        <WorktreeCard key={w.path} store={store} worktree={w} stats={store.worktreeStats[w.path]} sessions={agents.sessionsIn(w.path)} isCurrent={samePath(w.path, store.path)} />
      ))}
      {others.length > 0 && (
        <>
          <span className="muted" style={{ fontWeight: 600, marginTop: 6 }}>
            {t("Sessions in other folders")}</span>
          {others.map((s) => (
            <SessionRow key={s.id} store={store} session={s} showPath />
          ))}
        </>
      )}
      <span className="faint" style={{ fontSize: 11.5 }}>
        {t("Sessions started here run in tabs of the terminal below, and their status is shown here. Click a session to go to its terminal.")}</span>
    </div>
  );
}

function WorktreeCard({ store, worktree: w, stats, sessions, isCurrent }: { store: RepoStore; worktree: Worktree; stats?: WorktreeStats; sessions: AgentSession[]; isCurrent: boolean }) {
  return (
    <div
      className={`wt-card ${isCurrent ? "current" : ""}`}
      onDoubleClick={() => !isCurrent && void store.openOrReport(w.path)}
      onContextMenu={(e) =>
        showContextMenu(e, [
          {
            label: t("Start agent session…"),
            onClick: () => {
              store.sheet = { kind: "startAgent", path: w.path };
              store.changed();
            },
          },
          { label: t("Open in Gitrochi"), disabled: isCurrent, onClick: () => void store.openOrReport(w.path) },
          { label: t("Show in Explorer"), onClick: () => void ipc.reveal(w.path) },
          { label: t("Open in the terminal below"), onClick: () => store.newTerminal(w.path) },
          { label: t("Open in external terminal"), onClick: () => void ipc.openTerminal(w.path) },
          "divider",
          { label: t("Remove worktree…"), danger: true, disabled: w.isMain || isCurrent, onClick: () => store.confirmRemove(w) },
        ])
      }
    >
      <div className="row">
        <span className="muted" style={{ display: "inline-flex" }}>
          {w.isMain ? <House size={14} /> : <GitBranch size={14} />}
        </span>
        <span className="grow" style={{ fontWeight: 600, wordBreak: "break-all" }} data-tip={displayPath(w.path)}>
          {w.branch ?? t("Detached HEAD")}
        </span>
        <IconButton
          small
          className="hover-only"
          icon={<Sparkles size={13} />}
          tip={t("Start an agent session in this worktree")}
          onClick={() => {
            store.sheet = { kind: "startAgent", path: w.path };
            store.changed();
          }}
        />
      </div>
      {stats && (
        <div className="row" style={{ gap: 8, fontWeight: 500, fontVariantNumeric: "tabular-nums" }}>
          {statsClean(stats) && !stats.ahead && !stats.behind && <span className="muted">{t("No changes")}</span>}
          {stats.added > 0 && (
            <span style={{ color: "var(--green)" }} data-tip={t("New file")}>
              +{stats.added}
            </span>
          )}
          {stats.modified > 0 && (
            <span className="row" style={{ color: "var(--orange)", gap: 2 }} data-tip={t("Modified files")}>
              <Pencil size={11} />
              {stats.modified}
            </span>
          )}
          {stats.deleted > 0 && (
            <span style={{ color: "var(--red)" }} data-tip={t("Deleted file")}>
              −{stats.deleted}
            </span>
          )}
          {stats.conflicted > 0 && (
            <span style={{ color: "var(--red)" }} data-tip={t("Conflict")}>
              !{stats.conflicted}
            </span>
          )}
          {stats.ahead > 0 && (
            <span style={{ color: "var(--accent)" }} data-tip={t("Commits not pushed to the remote")}>
              ↑{stats.ahead}
            </span>
          )}
          {stats.behind > 0 && (
            <span style={{ color: "var(--orange)" }} data-tip={t("Commits not pulled from the remote")}>
              ↓{stats.behind}
            </span>
          )}
        </div>
      )}
      {sessions.length > 0 && (
        <>
          <div style={{ height: 1, background: "var(--border)" }} />
          {sessions.map((s) => (
            <SessionRow key={s.id} store={store} session={s} showPath={false} />
          ))}
        </>
      )}
    </div>
  );
}

const dotColor: Record<AgentStatus, string> = {
  working: "var(--accent)",
  running: "var(--accent)",
  permission: "var(--red)",
  starting: "var(--orange)",
  waiting: "var(--orange)",
  ended: "var(--text-3)",
};

function SessionRow({ store, session: s, showPath }: { store: RepoStore; session: AgentSession; showPath: boolean }) {
  const can = agents.canFocus(s);
  return (
    <div
      className="session-row"
      onClick={() => can && agents.focus(s)}
      data-tip={s.status === "ended" ? t("Ended sessions") : t("Click to go to that terminal")}
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
    >
      <span className={`dot ${s.status === "working" || s.status === "running" ? "pulse" : ""}`} style={{ background: dotColor[s.status], marginTop: 5 }} />
      <span className="col grow">
        <span className="row">
          <span style={{ fontWeight: 500 }}>{agentStatusTitle[s.status]}</span>
          <span className="faint" style={{ fontSize: 11 }}>
            {agentKind(s.kind).title.split(" (")[0]}
          </span>
          {skipsPermissions(s.kind, s.mode) && (
            <span className="row" style={{ color: "var(--red)", fontSize: 11, gap: 2, flex: "none" }} data-tip={t("Started with all permission checks skipped")}>
              <ShieldOff size={11} />
              {t("Skips permissions")}
            </span>
          )}
          {s.detail && s.status !== "ended" && <span className="muted ellipsis">· {s.detail}</span>}
        </span>
        {s.task && (
          <span className="muted" style={{ fontSize: 11.5, display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" }}>
            {s.task}
          </span>
        )}
        <span className="faint ellipsis" style={{ fontSize: 11 }}>
          {(showPath ? displayPath(s.path) + " · " : "") + shortDate(s.updated)}
        </span>
      </span>
    </div>
  );
}
