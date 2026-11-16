import type { Branch } from "@/entities/git";
import { settings } from "@/shared/config";
import { RepoSearch } from "./search";

/** 그래프 거르기: 브랜치 숨기기·고정, 현재 브랜치만 보기(저장소마다 기억) — 맥 버전 RepoStore+Filters */
export abstract class RepoFilters extends RepoSearch {
  static ref(b: Branch) {
    return b.isRemote ? `refs/remotes/${b.name}` : `refs/heads/${b.name}`;
  }

  isHidden(b: Branch) {
    return this.hiddenRefs.has(RepoFilters.ref(b));
  }

  isPinned(b: Branch) {
    return !b.isRemote && this.pinnedBranches.has(b.name);
  }

  private saveFilter(key: string, value: unknown) {
    if (!this.path) return;
    const all = { ...settings.get<Record<string, unknown>>(key, {}) };
    if (value === undefined) delete all[this.path];
    else all[this.path] = value;
    settings.set(key, all);
  }

  /** 브랜치를 그래프에서 숨기거나 다시 보인다. 로컬 브랜치면 같은 이름의 원격 브랜치도 함께. */
  async setHidden(b: Branch, hidden: boolean) {
    const refs = [RepoFilters.ref(b), ...(b.isRemote ? [] : this.remoteBranches.filter((r) => r.name.slice(r.name.indexOf("/") + 1) === b.name).map(RepoFilters.ref))];
    const next = new Set(this.hiddenRefs);
    for (const r of refs) hidden ? next.add(r) : next.delete(r);
    this.hiddenRefs = next;
    this.saveFilter("graphHiddenRefs", next.size ? [...next].sort() : undefined);
    await this.reload();
  }

  async showAllBranches() {
    this.hiddenRefs = new Set();
    this.saveFilter("graphHiddenRefs", undefined);
    await this.reload();
  }

  setPinned(b: Branch, pinned: boolean) {
    const next = new Set(this.pinnedBranches);
    pinned ? next.add(b.name) : next.delete(b.name);
    this.pinnedBranches = next;
    this.saveFilter("pinnedBranches", next.size ? [...next].sort() : undefined);
    this.emit();
  }

  /** Narrows the sidebar's branches and tags to the names that contain the text; "" lists everything again */
  setBranchFilter(text: string) {
    if (text === this.branchFilter) return;
    this.branchFilter = text;
    this.emit();
  }

  async setCurrentOnly(on: boolean) {
    this.graphCurrentOnly = on;
    this.saveFilter("graphCurrentOnly", on ? true : undefined);
    await this.reload();
    if (on && this.headHash) {
      this.scrollTarget = this.headHash;
      this.emit();
    }
  }
}
