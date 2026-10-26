import { type DropChoice, type DropRequest, type GraphEntry, isPending, type RefLabel, short } from "@/entities/git";
import { t } from "@/shared/i18n";
import { gitRaw } from "@/shared/platform";
import { RepoUndo } from "./undo";

export const branchPayload = "gitrochi-branch:";
export const commitPayload = "gitrochi-commit:";

/** 그래프 끌어다 놓기: 머지·리베이스·빨리 감기·cherry-pick */
export abstract class RepoDrop extends RepoUndo {
  branchNamed(name: string) {
    return this.localBranches.find((b) => b.name === name) ?? this.remoteBranches.find((b) => b.name === name) ?? null;
  }

  protected fullRef(name: string) {
    const b = this.branchNamed(name);
    if (b) return b.isRemote ? `refs/remotes/${b.name}` : `refs/heads/${b.name}`;
    return name;
  }

  async isAncestor(a: string, b: string) {
    if (!this.path) return false;
    try {
      return (await gitRaw(["merge-base", "--is-ancestor", a, b], this.path)).status === 0;
    } catch {
      return false;
    }
  }

  /**
   * 커밋 줄에 무언가를 놓았을 때. 그 줄의 브랜치(현재 브랜치 우선, 없으면 로컬, 원격 순)를 대상으로 삼는다.
   * 끌고 온 브랜치 자신(과 그 원격 추적 브랜치)은 대상에서 뺀다 — 같은 커밋에 main 과 feature 가 함께 있을 때
   * feature 를 그 줄에 놓으면 main 이 대상이 되게.
   */
  handleDrop(payload: string, entry: GraphEntry) {
    if (isPending(entry.commit) || this.busy != null) return;
    const refs = this.refsByCommit.get(entry.commit.id) ?? [];
    const pick = (list: RefLabel[]) =>
      list.find((r) => r.kind === "local" && r.isCurrent)?.name ?? list.find((r) => r.kind === "local")?.name ?? list.find((r) => r.kind === "remote")?.name ?? null;
    if (payload.startsWith(branchPayload)) {
      const source = payload.slice(branchPayload.length);
      const sourceBranch = this.branchNamed(source);
      const short = source.includes("/") && sourceBranch?.isRemote ? source.slice(source.indexOf("/") + 1) : source;
      const others = refs.filter((r) => r.name !== source && !(r.kind === "remote" && !sourceBranch?.isRemote && r.name.endsWith("/" + short)));
      const target = pick(others);
      if (target) void this.offerBranchDrop(source, target);
      else if (sourceBranch?.target !== entry.commit.id) this.offerBranchOnCommit(source, entry.commit.id);
    } else if (payload.startsWith(commitPayload)) {
      const sha = payload.slice(commitPayload.length);
      if (sha !== entry.commit.id) this.offerCommitDrop(sha, pick(refs));
    }
  }

  /** source 를 target 브랜치에 머지. target 이 현재 브랜치가 아니면 먼저 체크아웃한다(머지는 체크아웃한 브랜치에만 할 수 있다). */
  async mergeBranch(source: string, target: string) {
    if (target !== this.headBranch && !(await this.run(t("Checking out '{0}'…", target), ["switch", target]))) return;
    await this.merge(source);
  }

  /** 머지할 대상으로 고를 만한 로컬 브랜치(main·master·develop 먼저) */
  mergeTargets(exclude: string) {
    const preferred = ["main", "master", "develop", "dev"];
    const rank = (n: string) => (preferred.includes(n) ? preferred.indexOf(n) : preferred.length);
    return this.localBranches
      .filter((b) => b.name !== exclude)
      .sort((a, b) => rank(a.name) - rank(b.name) || a.name.localeCompare(b.name, undefined, { numeric: true }));
  }

  protected setDrop(r: DropRequest) {
    this.dropRequest = r;
    this.emit();
  }

  protected async offerBranchDrop(source: string, target: string) {
    const current = this.headBranch;
    const sourceRef = this.fullRef(source),
      targetRef = this.fullRef(target);
    const targetIsLocal = this.localBranches.some((b) => b.name === target);
    const sourceIsLocal = this.localBranches.some((b) => b.name === source);
    if (await this.isAncestor(sourceRef, targetRef)) {
      this.setDrop({ title: t("'{0}' is already in '{1}'", source, target), message: t("No new commits to merge."), choices: [] });
      return;
    }
    const choices: DropChoice[] = [];
    // 대상이 원본의 조상이면 머지 커밋 없이 앞으로 옮기기만 하면 된다
    if (targetIsLocal && (await this.isAncestor(targetRef, sourceRef))) {
      if (target === current) {
        choices.push({ title: t("Fast-forward '{0}' (current) to '{1}'", target, source), action: () => this.run(t("Fast-forwarding…"), ["merge", "--ff-only", source]) });
      } else {
        choices.push({
          title: t("Fast-forward '{0}' to '{1}'", target, source),
          action: () => this.run(t("Fast-forwarding…"), ["fetch", ".", `${sourceRef}:refs/heads/${target}`]),
        });
      }
    }
    if (target === current) {
      choices.push({ title: t("Merge '{0}' into '{1}' (current)", source, target), action: () => this.merge(source) });
      choices.push({ title: t("Rebase '{0}' (current) onto '{1}'", target, source), action: () => this.rebase(source) });
    } else if (source === current) {
      // 가장 흔한 경우: 작업한 브랜치(현재)를 main 같은 브랜치에 합치기
      if (targetIsLocal) choices.push({ title: t("Merge '{0}' (current) into '{1}' — checks out '{2}'", source, target, target), action: () => this.mergeBranch(source, target) });
      choices.push({ title: t("Rebase '{0}' (current) onto '{1}'", source, target), action: () => this.rebase(target) });
      choices.push({ title: t("Merge '{0}' into '{1}' (current)", target, source), action: () => this.merge(target) });
    } else {
      if (targetIsLocal)
        choices.push({
          title: t("Check out '{0}', then merge '{1}'", target, source),
          action: async () => {
            if (await this.run(t("Checking out…"), ["switch", target])) await this.merge(source);
          },
        });
      if (sourceIsLocal)
        choices.push({
          title: t("Check out '{0}', then rebase onto '{1}'", source, target),
          action: async () => {
            if (await this.run(t("Checking out…"), ["switch", source])) await this.rebase(target);
          },
        });
    }
    this.setDrop({
      title: `'${source}'  →  '${target}'`,
      message: choices.length ? t("What would you like to do? If there are conflicts, you can resolve them on the right.") : t("There's nothing you can do here."),
      choices,
    });
  }

  protected offerBranchOnCommit(source: string, sha: string) {
    const s = short(sha);
    const choices: DropChoice[] = [];
    if (source === this.headBranch) {
      choices.push({ title: t("Merge this commit ({0}) into '{1}' (current)", s, source), action: () => this.merge(sha) });
      choices.push({ title: t("Rebase '{0}' (current) onto this commit ({1})", source, s), action: () => this.rebase(sha) });
    } else if (this.localBranches.some((b) => b.name === source)) {
      choices.push({
        title: t("Check out '{0}', then rebase onto this commit ({1})", source, s),
        action: async () => {
          if (await this.run(t("Checking out…"), ["switch", source])) await this.rebase(sha);
        },
      });
    }
    this.setDrop({ title: t("'{0}'  →  commit {1}", source, s), message: choices.length ? t("What would you like to do?") : t("There's nothing you can do here."), choices });
  }

  protected offerCommitDrop(sha: string, target: string | null) {
    if (!target) return;
    const s = short(sha);
    const choices: DropChoice[] = [];
    if (target === this.headBranch) {
      choices.push({ title: t("Cherry-pick commit {0} onto '{1}' (current)", s, target), action: () => this.cherryPick(sha) });
    } else if (this.localBranches.some((b) => b.name === target)) {
      choices.push({
        title: t("Check out '{0}', then cherry-pick commit {1}", target, s),
        action: async () => {
          if (await this.run(t("Checking out…"), ["switch", target])) await this.cherryPick(sha);
        },
      });
    }
    this.setDrop({
      title: t("Commit {0}  →  '{1}'", s, target),
      message: choices.length ? t("What would you like to do?") : t("You can't cherry-pick onto a remote branch directly."),
      choices,
    });
  }
}
