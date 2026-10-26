import { makePlan, planProblem, rebaseItem, type RebaseItem, type RebasePlan, rebaseTodo, historyOperationInProgress, fullObjectID, repoStateTitle, shellQuote } from "@/entities/git";
import { ipc } from "@/shared/api";
import { joinPath, slash } from "@/shared/config";
import { t } from "@/shared/i18n";
import { describe, gitRaw } from "@/shared/platform";
import { RepoDrop } from "./drop";

/** 인터랙티브 리베이스(커밋 정리): 현재 브랜치의 커밋을 합치기·순서 바꾸기·메시지 고치기·빼기 (맥 버전 RepoStore+Rebase.swift) */
export abstract class RepoRebase extends RepoDrop {
  /** 이 커밋부터 HEAD 까지를 정리하는 창을 연다 */
  async startInteractiveRebase(sha: string, present = true) {
    const branch = this.headBranch;
    if (!this.path || !branch || !fullObjectID(sha)) return;
    const path = this.path, generation = this.pushReviewGeneration;
    const current = () => this.path === path && this.pushReviewGeneration === generation;
    const headResult = await gitRaw(["rev-parse", "--verify", "HEAD"], path);
    if (!current() || headResult.status !== 0) return;
    const head = headResult.stdout.trim();
    const fail = (m: string) => {
      if (!current()) return;
      this.errorMessage = m;
      this.emit();
    };
    if (this.repoState !== "clean") return fail(t("You can't clean up commits right now ({0}).", repoStateTitle[this.repoState]));
    if (!(await this.isAncestor(sha, head))) return fail(t("You can only clean up commits that are on the current branch '{0}'.", branch));
    if (!current()) return;
    const parent = await gitRaw(["rev-parse", "--verify", "-q", `${sha}^`], path);
    const base = parent.status === 0 ? parent.stdout.trim() : null;
    const r = await gitRaw(["log", "--format=%H%x1f%P%x1f%an%x1f%B%x1e", base ? `${base}..${head}` : head], path);
    if (r.status !== 0) return fail(t("Couldn't read the commit list."));
    if (!current()) return;
    const items: RebaseItem[] = [];
    for (const rec of r.stdout.split("\x1e")) {
      const f = rec.replace(/^[\r\n]+|[\r\n]+$/g, "").split("\x1f");
      if (f.length < 4) continue;
      if (f[1].split(" ").filter(Boolean).length > 1) return fail(t("There's a merge commit in the range. Pick a commit above the merge commit."));
      items.push(rebaseItem(f[0], f.slice(3).join("\x1f").replace(/\r\n/g, "\n").replace(/^\n+|\n+$/g, ""), f[2]));
    }
    if (!items.length) return;
    // 가장 오래된 커밋이 이미 올라간 브랜치에 있으면, 정리한 뒤 강제 푸시가 필요하다
    const up = this.status.upstream;
    const pushed = !!up && (await this.isAncestor(items[items.length - 1].sha, up));
    if (!current()) return;
    this.rebasePlan = makePlan(base, items, pushed);
    this.rebasePlan.expectedHead = head;
    if (present) this.sheet = { kind: "interactiveRebase" };
    this.emit();
    return this.rebasePlan;
  }

  /** 계획대로 git rebase -i 를 돌린다(할 일 목록은 미리 만들어 편집기 대신 복사해 넣는다) */
  async runInteractiveRebase(plan: RebasePlan) {
    if (!this.gitDir || !this.path || planProblem(plan) || this.busy) return;
    const path = this.path;
    const generation = this.pushReviewGeneration;
    try {
      const head = await this.g(["rev-parse", "--verify", "HEAD"]);
      const status = await this.g(["status", "--porcelain=v1", "--untracked-files=normal"]);
      if (this.path !== path || this.pushReviewGeneration !== generation || (plan.expectedHead && head.stdout.trim() !== plan.expectedHead)) throw new Error(t("The repository changed. Open this review again."));
      const pending = await historyOperationInProgress(this.gitDir);
      if (this.path !== path || this.pushReviewGeneration !== generation) return;
      if (status.stdout || pending || this.repoState !== "clean") throw new Error(t("Commit or stash changes and finish the current Git operation first."));
    } catch (e) { if (this.path === path && this.pushReviewGeneration === generation) this.fail(e); return; }
    const dir = joinPath(this.gitDir, "gitrochi-rebase");
    const file = (name: string) => slash(joinPath(dir, name));
    try {
      await ipc.remove(dir);
      for (const i of plan.items) if (i.action === "reword") await ipc.writeText(file(`msg-${i.sha}`), i.newMessage);
      await ipc.writeText(file("todo"), rebaseTodo(plan, (sha) => file(`msg-${sha}`)));
    } catch (e) {
      if (this.path !== path || this.pushReviewGeneration !== generation) return;
      this.errorMessage = t("Couldn't write the cleanup plan.\n\n") + describe(e);
      this.emit();
      return;
    }
    if (this.path !== path || this.pushReviewGeneration !== generation) return;
    const ok = await this.run(t("Cleaning up commits…"), ["-c", `sequence.editor=cp ${shellQuote(file("todo"))}`, "rebase", "-i", plan.base ?? "--root"], { env: { GIT_EDITOR: "true" } });
    if (this.path !== path || this.pushReviewGeneration !== generation) return;
    this.rebasePlan = null;
    // 충돌로 멈추면 남은 메시지 고치기에 파일이 필요하다
    if (ok && this.repoState === "clean") await ipc.remove(dir);
  }
}
