import { CommitSearchQuery, isPending, type SearchScope } from "@/entities/git";
import { git } from "@/shared/platform";
import { RepoSelection } from "./selection";

/** 커밋·파일·코드 검색 */
export abstract class RepoSearch extends RepoSelection {
  get isSearching() {
    return !!this.searchText.trim();
  }

  get searchPosition(): number | null {
    const id = this.selectedID;
    const i = id ? this.searchMatches.indexOf(id) : -1;
    return i < 0 ? null : i + 1;
  }

  requestSearchFocus() {
    this.navigate("repository");
    this.closeFileInspect();
    this.closeDiff();
    this.showSearchBar = true;
    this.searchFocusRequest++;
    this.emit();
  }

  /** Esc or the bar's close button: the search ends and the bar goes away */
  closeSearchBar() {
    this.showSearchBar = false;
    this.clearSearch();
  }

  setSearch(text: string, scope?: SearchScope) {
    this.searchText = text;
    if (scope) this.searchScope = scope;
    this.updateSearch();
  }

  updateSearch() {
    if (this.searchTimer) clearTimeout(this.searchTimer);
    const gen = ++this.searchGen;
    const q = this.searchText.trim();
    const path = this.path;
    if (!q || !path) {
      this.clearSearchResults();
      return;
    }
    const scope = this.searchScope;
    const query = new CommitSearchQuery(q);
    if (scope === "commits") {
      // 1) 불러온 커밋에서 즉시: 제목·작성자·이메일·SHA·브랜치/태그 이름
      const found = new Set<string>();
      for (const e of this.entries) {
        const c = e.commit;
        if (isPending(c)) continue;
        if (
          query.matches(c.subject) ||
          query.matches(c.author) ||
          query.matches(c.email) ||
          c.id.startsWith(query.key) ||
          (this.refsByCommit.get(c.id) ?? []).some((r) => query.matches(r.name))
        )
          found.add(c.id);
      }
      this.applySearch(found, true);
    } else {
      this.searchMatches = [];
      this.searchMatchSet = new Set();
    }
    // 2) git 으로 더 깊게(메시지 본문, 파일 경로, 코드 변경) — 입력이 멈추면 실행
    this.searching = true;
    this.emit();
    this.searchTimer = setTimeout(async () => {
      const args = ["log", "--exclude=refs/stash", "--all", "--format=%H"];
      if (scope === "commits") args.push("-n", "20000", "-i", "-E", "--grep=" + query.gitPattern);
      else if (scope === "files") args.push("-n", "20000", "--", `:(glob,icase)**/*${q}*`);
      else args.push("-n", "1000", "-G", q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
      let out = "";
      try {
        out = (await git(args, path, { timeoutMs: 180_000, env: { GIT_LITERAL_PATHSPECS: "0" } })).stdout;
      } catch {
        out = "";
      }
      if (gen !== this.searchGen) return;
      this.searching = false;
      const found = new Set(out.split(/\r?\n/).filter(Boolean));
      if (scope === "commits") for (const id of this.searchMatchSet) found.add(id);
      this.applySearch(found, scope !== "commits" || !this.searchMatches.length);
      this.emit();
    }, scope === "commits" ? 350 : 500);
  }

  protected applySearch(found: Set<string>, jump: boolean) {
    const ordered = this.entries.filter((e) => found.has(e.commit.id)).map((e) => e.commit.id);
    this.searchMatches = ordered;
    this.searchMatchSet = new Set(ordered);
    let unloaded = 0;
    for (const id of found) if (!this.searchMatchSet.has(id)) unloaded++;
    this.searchUnloaded = unloaded;
    // 지금 고른 커밋이 결과가 아니면 첫 결과로 이동
    if (jump && this.destination === "repository" && ordered.length && !this.searchMatchSet.has(this.selectedID ?? "")) {
      this.select({ kind: "commit", sha: ordered[0] });
      this.scrollTarget = ordered[0];
    }
    this.emit();
  }

  clearSearchResults() {
    this.searchMatches = [];
    this.searchMatchSet = new Set();
    this.searchUnloaded = 0;
    this.searching = false;
    this.emit();
  }

  clearSearch() {
    this.searchGen++;
    if (this.searchTimer) clearTimeout(this.searchTimer);
    this.searchText = "";
    this.clearSearchResults();
  }

  nextMatch() {
    this.stepMatch(1);
  }
  previousMatch() {
    this.stepMatch(-1);
  }

  protected stepMatch(d: number) {
    const m = this.searchMatches;
    if (!m.length) return;
    let cur = m.indexOf(this.selectedID ?? "");
    if (cur < 0) cur = d > 0 ? -1 : 0;
    const sha = m[(cur + d + m.length) % m.length];
    this.select({ kind: "commit", sha });
    this.scrollTarget = sha;
    this.emit();
  }

  /** 아직 그래프에 없는 결과가 있으면 기록을 더 불러와 다시 찾는다 */
  async loadMoreForSearch() {
    await this.loadMore();
    this.updateSearch();
  }
}
