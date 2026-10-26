import { type AgentKind, agents } from "@/entities/agent";
import * as P from "@/entities/git";
import { type WorkingStatus, type Worktree, worktreeStats, type WorktreeStats } from "@/entities/git";
import { basename, dirname, joinPath, samePath, samePathKey } from "@/shared/config";
import { t } from "@/shared/i18n";
import { git } from "@/shared/platform";
import { pendingRowsKey } from "./core";
import { RepoRebase } from "./rebase";

/** 워크트리·에이전트 세션 */
export abstract class RepoWorktrees extends RepoRebase {
  /** 기본 위치: <저장소 상위>/<저장소 이름>-worktrees/<브랜치> */
  defaultWorktreePath(branch: string) {
    if (!this.path) return "";
    return joinPath(dirname(this.path), `${basename(this.path)}-worktrees`, branch.replace(/\//g, "-"));
  }

  async addWorktree(path: string, branch: string, createNew: boolean, start: string | null, launchClaude: boolean, task: string) {
    const args = ["worktree", "add"];
    if (createNew) args.push("-b", branch, path, ...(start ? [start] : []));
    else args.push(path, branch);
    if (!(await this.run(t("Creating worktree…"), args))) return false;
    if (launchClaude) await this.startAgent(path, task);
    return true;
  }

  /**
   * Shows another worktree of this repository in this tab, like GitKraken (a tab already showing it comes forward instead).
   * Terminals stay; the newest one opened in that worktree is selected.
   */
  async switchWorktree(path: string) {
    if (samePath(path, this.path) || this.showTab?.(path)) return;
    await this.openInPlace(path, true);
    // a worktree may sit inside another one, so the longest matching path owns the terminal
    const owner = (dir: string) =>
      this.worktrees
        .filter((w) => samePath(w.path, dir) || samePathKey(dir).startsWith(samePathKey(w.path) + "/"))
        .sort((a, b) => b.path.length - a.path.length)[0]?.path;
    const s = [...this.terminals].reverse().find((t) => samePath(owner(t.directory) ?? "", path));
    if (s) {
      this.activeTerminalID = s.id;
      s.unseenOutput = false;
      this.emit();
    }
  }

  confirmRemove(w: Worktree, force = false) {
    this.ask({
      title: t("Remove worktree '{0}'?", basename(w.path)),
      message: force
        ? t("{0}\nUncommitted changes are deleted too.", w.path)
        : t("{0}\nThe folder is deleted; the branch and commits stay. git refuses if there are uncommitted changes.", w.path),
      actionTitle: force ? t("Force remove") : t("Remove"),
      action: () => this.run(t("Removing worktree…"), ["worktree", "remove", ...(force ? ["--force"] : []), w.path]),
    });
  }

  pruneWorktrees() {
    return this.run(t("Pruning worktrees…"), ["worktree", "prune"]);
  }

  /** 코딩 에이전트(Claude Code·Codex·Gemini CLI)를 아래 터미널 탭에서 시작 */
  async startAgent(path: string, task = "", mode: string | null = null, kind: AgentKind = agents.defaultKind) {
    try {
      await agents.start(this, kind, path, task, mode);
    } catch (e) {
      this.fail(e);
    }
  }

  /** 워크트리마다 변경 파일 수와 원격 대비 ↑↓ (에이전트 패널 카드), and other worktrees' changes for their graph rows */
  async refreshWorktreeStats() {
    const list = this.worktrees.filter((w) => !w.prunable);
    const path = this.path;
    const stats: Record<string, WorktreeStats> = {};
    const status: Record<string, WorkingStatus> = {};
    await Promise.all(
      list.map(async (w) => {
        if (samePath(w.path, path)) {
          stats[w.path] = worktreeStats(this.status);
          return;
        }
        try {
          const r = await git(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"], w.path);
          status[w.path] = P.parseStatus(r.stdout);
          stats[w.path] = worktreeStats(status[w.path]);
        } catch {
          /* 폴더가 사라짐 */
        }
      }),
    );
    if (this.path !== path) return;
    let changed = false;
    if (JSON.stringify(stats) !== JSON.stringify(this.worktreeStats)) {
      this.worktreeStats = stats;
      changed = true;
    }
    if (JSON.stringify(status) !== JSON.stringify(this.worktreeStatus)) {
      this.worktreeStatus = status;
      changed = true;
      // a worktree gained or lost its changes (or moved its HEAD): redraw the graph with its row
      if (this.lastLog && this.lastLog.pending !== pendingRowsKey(this.pendingWorktrees(this.worktrees))) void this.reload(true);
    }
    if (changed) this.emit();
  }
}
