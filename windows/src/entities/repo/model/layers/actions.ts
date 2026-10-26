import { displayPushURL, type Branch, branchRemote, branchShort, changePaths, type ConfirmRequest, type FileChange, fileName, type PullMode, type RepoState, type ResetMode, short, type Stash, type Tag } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import { samePath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { describe, git } from "@/shared/platform";
import type { RefSnapshot } from "../../lib/undo-model";
import { RepoPushReview } from "./push-review";

/** git 작업: 실행·Fetch·Pull·Push·브랜치·태그·스태시·스테이지·커밋·진행 중인 머지/리베이스 */
export abstract class RepoActions extends RepoPushReview {
  // 되돌리기(repo/undo.ts)
  protected abstract refSnapshot(): Promise<RefSnapshot | null>;
  protected abstract recordUndo(args: string[], input: string | undefined, before: RefSnapshot, after: RefSnapshot): void;

  /**
   * git 명령 하나를 실행하고 저장소를 다시 읽는다. 실패하면 git 의 메시지를 그대로 보여 준다.
   * 전후로 브랜치·태그·HEAD 를 기록해 두어 '되돌리기'로 되돌릴 수 있게 한다(머지·리베이스가 진행 중일 때는 빼고).
   */
  async run(label: string, args: string[], o: { network?: boolean; input?: string; env?: Record<string, string> } = {}): Promise<boolean> {
    const repo = this.path;
    if (!repo || this.busy != null) return false;
    const generation = this.pushReviewGeneration;
    const target = this.target;
    const active = () => this.path === repo && this.pushReviewGeneration === generation;
    this.busy = label;
    this.emit();
    try {
      const before = this.repoState === "clean" ? await this.refSnapshot() : null;
      if (!active()) return false;
      const env = o.env ?? (o.network ? await accounts.gitEnvironment(target, repo) : {});
      if (!active()) return false;
      await git(args, repo, { input: o.input, timeoutMs: o.network ? 900_000 : 300_000, env });
      if (!active()) return false;
      const after = before ? await this.refSnapshot() : null;
      if (!active()) return false;
      if (before && after) this.recordUndo(args, o.input, before, after);
      await this.reload();
      return active();
    } catch (e) {
      if (!active()) return false;
      if (this.sheet?.kind === "pushReview") this.pushReviewError = displayPushURL(describe(e));
      else this.fail(e);
      await this.reload(true);
      return false;
    } finally {
      if (active()) { this.busy = null; this.emit(); }
    }
  }

  protected get defaultRemote() {
    return this.remotes.includes("origin") ? "origin" : this.remotes[0] ?? null;
  }

  async fetch() {
    if (await this.run(t("Fetching…"), ["fetch", "--all", "--prune"], { network: true })) {
      await this.loadPullRequests();
      await this.ci.refreshBadges();
    }
  }

  async pull(mode: PullMode = "standard") {
    const args = ["pull"];
    if (mode === "fastForward") args.push("--ff-only");
    if (mode === "merge") args.push("--no-rebase");
    if (mode === "rebase") args.push("--rebase");
    await this.run(t("Pulling…"), args, { network: true });
  }

  async push(force = false): Promise<boolean> {
    const branch = this.headBranch;
    if (!branch || !this.headHash) {
      this.errorMessage = t("There's no branch to push. HEAD is detached or there are no commits yet.");
      this.emit();
      return false;
    }
    return this.requestPushReview(branch, force);
  }

  async pushBranch(b: Branch): Promise<boolean> {
    if (b.isRemote) return false;
    return this.requestPushReview(b.name);
  }

  /** 지금 열린 곳이 아닌 다른 워크트리가 이 브랜치를 쓰고 있으면 그 워크트리 */
  worktreeUsing(branch: string) {
    return this.worktrees.find((w) => w.branch === branch && !samePath(w.path, this.path)) ?? null;
  }

  async checkout(b: Branch) {
    if (!b.isRemote) {
      const w = this.worktreeUsing(b.name);
      if (w) {
        this.ask({
          title: t("'{0}' is in use by another worktree", b.name),
          message: t("{0}\nA branch can be checked out in only one worktree. Open that worktree?", w.path),
          actionTitle: t("Open worktree"),
          destructive: false,
          action: () => this.switchWorktree(w.path),
        });
        return;
      }
    }
    if (b.isRemote) {
      const s = branchShort(b);
      if (this.localBranches.some((x) => x.name === s)) await this.run(t("Checking out…"), ["switch", s]);
      else await this.run(t("Checking out…"), ["switch", "-c", s, "--track", b.name]);
    } else if (!b.isCurrent) {
      await this.run(t("Checking out…"), ["switch", b.name]);
    }
  }

  checkoutDetached(sha: string) {
    return this.run(t("Checking out…"), ["switch", "--detach", sha]);
  }

  requestNewBranch(start?: string, label?: string) {
    const s = start ?? this.headHash ?? "HEAD";
    this.sheet = { kind: "newBranch", start: s, label: label ?? this.headBranch ?? short(s) };
    this.emit();
  }

  createBranch(name: string, start: string, checkout: boolean) {
    return this.run(t("Creating branch…"), checkout ? ["switch", "-c", name, start] : ["branch", name, start]);
  }

  ask(c: ConfirmRequest) {
    this.confirm = { destructive: true, ...c };
    this.emit();
  }

  confirmDelete(b: Branch) {
    if (b.isRemote) {
      const remote = branchRemote(b);
      if (!remote) return;
      this.ask({
        title: t("Delete remote branch '{0}'?", b.name),
        message: t("The branch will be deleted on the {0} server. Be careful if others use it too.", remote),
        actionTitle: t("Delete from remote"),
        action: () => this.run(t("Deleting remote branch…"), ["push", remote, "--delete", branchShort(b)], { network: true }),
      });
    } else {
      this.ask({
        title: t("Delete branch '{0}'?", b.name),
        message: t("git refuses to delete a branch with unmerged commits. Use 'Force delete' in that case."),
        actionTitle: t("Delete"),
        action: () => this.run(t("Deleting branch…"), ["branch", "-d", b.name]),
      });
    }
  }

  confirmForceDelete(b: Branch) {
    this.ask({
      title: t("Force delete branch '{0}'?", b.name),
      message: t("Unmerged commits are discarded too."),
      actionTitle: t("Force delete"),
      action: () => this.run(t("Deleting branch…"), ["branch", "-D", b.name]),
    });
  }

  merge(name: string) {
    return this.run(t("Merging…"), ["merge", name]);
  }
  rebase(onto: string) {
    return this.run(t("Rebasing…"), ["rebase", onto]);
  }
  cherryPick(sha: string) {
    return this.run(t("Cherry-picking…"), ["cherry-pick", sha]);
  }
  revert(sha: string) {
    return this.run(t("Reverting…"), ["revert", "--no-edit", sha]);
  }

  reset(sha: string, mode: ResetMode) {
    const action = () => this.run(t("Resetting…"), ["reset", `--${mode}`, sha]);
    if (mode === "hard") {
      this.ask({
        title: t("Hard reset to {0}?", short(sha)),
        message: t("Uncommitted changes and later commits are removed from the current branch."),
        actionTitle: t("Hard reset"),
        action,
      });
    } else void action();
  }

  createTag(name: string, message: string, sha: string) {
    return this.run(t("Creating tag…"), message.trim() ? ["tag", "-a", name, "-m", message, sha] : ["tag", name, sha]);
  }

  deleteTag(tag: Tag) {
    this.ask({
      title: t("Delete tag '{0}'?", tag.name),
      message: t("Only the local tag is deleted."),
      actionTitle: t("Delete"),
      action: () => this.run(t("Deleting tag…"), ["tag", "-d", tag.name]),
    });
  }

  async pushTag(tag: Tag) {
    const remote = this.defaultRemote;
    if (!remote) {
      this.errorMessage = t("No remote repository.");
      this.emit();
      return;
    }
    await this.run(t("Pushing tag…"), ["push", remote, "refs/tags/" + tag.name], { network: true });
  }

  // 스태시

  stash(message: string, includeUntracked: boolean) {
    const args = ["stash", "push"];
    if (includeUntracked) args.push("--include-untracked");
    if (message.trim()) args.push("-m", message.trim());
    return this.run(t("Stashing…"), args);
  }
  stashApply(s: Stash) {
    return this.run(t("Applying stash…"), ["stash", "apply", s.ref]);
  }
  stashPop(s?: Stash) {
    return this.run(t("Popping stash…"), ["stash", "pop", ...(s ? [s.ref] : [])]);
  }
  stashDrop(s: Stash) {
    this.ask({
      title: t("Discard {0}?", s.ref),
      message: s.message,
      actionTitle: t("Discard"),
      action: () => this.run(t("Dropping stash…"), ["stash", "drop", s.ref]),
    });
  }

  // 스테이지·커밋

  stage(changes: FileChange[]) {
    if (!changes.length) return Promise.resolve(false);
    return this.run(t("Staging…"), ["add", "-A", "--", ...changes.flatMap(changePaths)]);
  }

  unstage(changes: FileChange[]) {
    if (!changes.length) return Promise.resolve(false);
    const paths = changes.flatMap(changePaths);
    return this.headHash
      ? this.run(t("Unstaging…"), ["restore", "--staged", "--", ...paths])
      : this.run(t("Unstaging…"), ["rm", "--cached", "-r", "-q", "--", ...paths]);
  }

  stageAll() {
    return this.run(t("Staging…"), ["add", "-A"]);
  }

  unstageAll() {
    return this.headHash ? this.run(t("Unstaging…"), ["reset", "-q"]) : this.run(t("Unstaging…"), ["rm", "--cached", "-r", "-q", "."]);
  }

  confirmDiscard(c: FileChange) {
    this.ask({
      title: t("Discard changes to '{0}'?", fileName(c.path)),
      message: c.kind === "untracked" ? t("Untracked new files will be deleted.") : t("Your edits in the working tree will be lost."),
      actionTitle: t("Discard changes"),
      action: async () => {
        const repository = this.path;
        if (!repository || !await this.preserveDiscardedChanges(changePaths(c)) || this.path !== repository) return;
        return c.kind === "untracked"
          ? this.run(t("Discarding changes…"), ["clean", "-f", "-q", "--", c.path])
          : this.run(t("Discarding changes…"), ["restore", "--worktree", "--", ...changePaths(c)]);
      },
    });
  }

  confirmDiscardAll() {
    this.ask({
      title: t("Discard all changes?"),
      message: t("A local recovery copy is saved before discarding staged, unstaged and untracked changes."),
      actionTitle: t("Discard all"),
      action: async () => {
        const repository = this.path;
        if (!repository || !await this.preserveDiscardedChanges() || this.path !== repository) return;
        if (this.headHash && !(await this.run(t("Undoing…"), ["reset", "--hard", "-q"]))) return;
        if (!this.headHash && !(await this.run(t("Undoing…"), ["read-tree", "--empty"]))) return;
        await this.run(t("Cleaning up…"), ["clean", "-fd", "-q"]);
      },
    });
  }

  get canCommit() {
    return (
      this.busy == null &&
      !!this.summary.trim() &&
      (this.status.staged.length > 0 || this.amend || this.repoState === "merging") &&
      this.status.conflicted.length === 0
    );
  }

  setSummary(v: string) {
    this.summary = v;
    this.emit();
  }
  setMessage(v: string) {
    this.message = v;
    this.emit();
  }

  async setAmend(on: boolean) {
    this.amend = on;
    this.emit();
    if (!on || this.summary || this.message || !this.path || !this.headHash) return;
    try {
      const text = (await this.g(["log", "-1", "--format=%B"])).stdout.trim();
      const nl = text.indexOf("\n");
      this.summary = nl < 0 ? text : text.slice(0, nl);
      this.message = nl < 0 ? "" : text.slice(nl + 1).trim();
      this.emit();
    } catch {
      /* 무시 */
    }
  }

  async commit() {
    if (!this.canCommit) return;
    const text = [this.summary.trim(), this.message.trim()].filter(Boolean).join("\n\n");
    const args = ["commit", "-F", "-"];
    if (this.amend) args.push("--amend");
    if (await this.run(t("Committing…"), args, { input: text + "\n" })) {
      this.summary = "";
      this.message = "";
      this.amend = false;
      this.mergeMessageFilled = false;
      this.emit();
    }
  }

  abortOperation() {
    const args: Record<RepoState, string[] | null> = {
      merging: ["merge", "--abort"],
      rebasing: ["rebase", "--abort"],
      cherryPicking: ["cherry-pick", "--abort"],
      reverting: ["revert", "--abort"],
      clean: null,
    };
    const a = args[this.repoState];
    if (!a) return;
    this.ask({
      title: t("Abort the current operation ({0})?", this.repoStateTitle),
      message: t("Returns to the state before the operation started."),
      actionTitle: t("Abort"),
      action: async () => {
        await this.run(t("Aborting…"), a);
        this.summary = "";
        this.message = "";
        this.emit();
      },
    });
  }

  get repoStateTitle() {
    return { clean: "", merging: t("Merge in progress"), rebasing: t("Rebase in progress"), cherryPicking: t("Cherry-pick in progress"), reverting: t("Revert in progress") }[this.repoState];
  }

  async continueOperation() {
    switch (this.repoState) {
      case "rebasing":
        await this.run(t("Continuing rebase…"), ["rebase", "--continue"]);
        break;
      case "cherryPicking":
        await this.run(t("Continuing cherry-pick…"), ["cherry-pick", "--continue"]);
        break;
      case "reverting":
        await this.run(t("Continuing revert…"), ["revert", "--continue"]);
        break;
      case "merging":
        await this.commit();
        break;
    }
  }
}
