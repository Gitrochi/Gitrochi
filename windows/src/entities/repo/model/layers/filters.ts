import type { Branch, Tag } from "@/entities/git";
import { settings } from "@/shared/config";
import { PinnedRefs } from "../../lib/pinned-refs";
import { RepoSearch } from "./search";

/** 그래프 거르기: 브랜치 숨기기·고정, 현재 브랜치만 보기(저장소마다 기억) — 맥 버전 RepoStore+Filters */
export abstract class RepoFilters extends RepoSearch {
  static ref(b: Branch) {
    return b.isRemote ? `refs/remotes/${b.name}` : `refs/heads/${b.name}`;
  }

  static tagRef(t: Tag) {
    return `refs/tags/${t.name}`;
  }

  isHidden(b: Branch) {
    return this.hiddenRefs.has(RepoFilters.ref(b));
  }

  isPinned(b: Branch) {
    return this.pinnedRefs.has(RepoFilters.ref(b));
  }

  isTagHidden(t: Tag) {
    return this.hiddenRefs.has(RepoFilters.tagRef(t));
  }

  isTagPinned(t: Tag) {
    return this.pinnedRefs.has(RepoFilters.tagRef(t));
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
    await this.setRefsHidden(refs, hidden);
  }

  /** Hides a tag from the graph, or shows it again: its chip goes, and so do the commits only it reaches */
  async setTagHidden(t: Tag, hidden: boolean) {
    await this.setRefsHidden([RepoFilters.tagRef(t)], hidden);
  }

  private async setRefsHidden(refs: string[], hidden: boolean) {
    const next = new Set(this.hiddenRefs);
    for (const r of refs) hidden ? next.add(r) : next.delete(r);
    await this.applyHidden(next);
  }

  /** Shows every hidden branch and tag again */
  async showAllBranches() {
    await this.applyHidden(new Set());
  }

  private async applyHidden(next: Set<string>) {
    this.hiddenRefs = next;
    this.saveFilter("graphHiddenRefs", next.size ? [...next].sort() : undefined);
    // the chips now: a reload keeps the ref map while neither the walk nor the refs change, as with a hidden tag
    // whose commits other refs reach
    this.refsByCommit = this.buildRefMap(this.headHash);
    this.emit();
    await this.reload();
  }

  setPinned(b: Branch, pinned: boolean) {
    this.setRefPinned(RepoFilters.ref(b), pinned);
  }

  setTagPinned(t: Tag, pinned: boolean) {
    this.setRefPinned(RepoFilters.tagRef(t), pinned);
  }

  private setRefPinned(ref: string, pinned: boolean) {
    const next = new Set(this.pinnedRefs);
    pinned ? next.add(ref) : next.delete(ref);
    this.pinnedRefs = next;
    const stored = PinnedRefs.split(next);
    this.saveFilter("pinnedBranches", stored.branches.length ? stored.branches : undefined);
    this.saveFilter("pinnedRefs", stored.refs.length ? stored.refs : undefined);
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
