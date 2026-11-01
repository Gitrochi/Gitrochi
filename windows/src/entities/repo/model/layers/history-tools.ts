import { batchArguments, historyOperationInProgress, changePaths, fullObjectID, lineHistoryRange, makePlan, parseLineHistory, parseNameStatus, parseNumstat, isPending, toggleGraphSelection, validRevisionInput, type BatchCommitAction, type BatchCommitItem, type FileChange, type LineHistoryEntry, type LineStat } from "@/entities/git";
import { t } from "@/shared/i18n";
import { describe, git } from "@/shared/platform";
import { RepoGitch } from "./gitch";

interface RevisionComparison { left: string; right: string; base: string; mergeBase: boolean; files: FileChange[]; stats: Record<string, LineStat> }
const newState = () => ({
  selected: [] as string[], anchor: null as string | null,
  left: "HEAD~1", right: "HEAD", useMergeBase: false, comparison: null as RevisionComparison | null,
  comparisonPath: null as string | null, comparisonPatch: "", comparisonLoading: false, comparisonError: null as string | null,
  batch: [] as BatchCommitItem[], batchHead: "", batchBranch: "", batchAction: "cherry-pick" as BatchCommitAction, batchLoading: false, batchError: null as string | null,
  linePath: "", lineRevision: "HEAD", lineStart: 1, lineEnd: 1, functionName: "", lineEntries: [] as LineHistoryEntry[], lineSelected: null as string | null, lineLoading: false, lineError: null as string | null, lineTruncated: false,
});
/** 그래프 선택, 고정 객체 사이 비교, Git의 줄/함수 추적을 제공한다. */
export abstract class RepoHistoryTools extends RepoGitch {
  historyTools = newState();
  private historyToolsGeneration = 0;
  private comparisonFileGeneration = 0;
  protected resetState() {
    super.resetState();
    this.historyToolsGeneration++;
    this.comparisonFileGeneration++;
    this.historyTools = newState();
  }
  cancelHistoryTools() {
    this.historyToolsGeneration++;
    this.comparisonFileGeneration++;
    this.historyTools.comparisonLoading = false;
    this.historyTools.batchLoading = false;
    this.historyTools.lineLoading = false;
    this.emit();
  }
  selectGraphCommit(sha: string, extend = false, toggle = false) {
    const s = this.historyTools;
    const oldAnchor = s.anchor;
    const ids = this.entries.filter((e) => !isPending(e.commit)).map((e) => e.commit.id);
    const selected = toggleGraphSelection(ids, s.selected, s.anchor, sha, extend, toggle);
    this.select({ kind: "commit", sha });
    s.selected = selected;
    s.anchor = extend ? oldAnchor : sha;
    this.emit();
  }
  clearHistorySelection() { this.historyTools.selected = []; this.historyTools.anchor = null; }
  openRevisionComparison(left?: string, right?: string) {
    this.cancelHistoryTools();
    const s = this.historyTools;
    const selected = s.selected;
    s.left = left ?? (selected.length === 2 ? selected[1] : this.status.upstream ?? "HEAD~1");
    s.right = right ?? (selected.length === 2 ? selected[0] : "HEAD");
    s.comparison = null; s.comparisonPatch = ""; s.comparisonError = null;
    this.sheet = { kind: "compareRevisions" }; this.emit();
  }
  /** Opens the Compare page on two revisions, e.g. a release tag and the checkout (macOS: showRevisionComparison). */
  showRevisionComparison(left: string, right: string) {
    if (!this.navigate("compare")) return;
    const s = this.historyTools;
    s.left = left; s.right = right; s.useMergeBase = false;
    void this.loadRevisionComparison();
  }
  private async resolveHistoryRevision(value: string, path: string): Promise<string> {
    if (!validRevisionInput(value)) throw new Error(t("Enter a branch, tag or commit without spaces or leading dashes."));
    const r = await git(["rev-parse", "--verify", "--end-of-options", `${value}^{commit}`], path);
    const sha = r.stdout.trim();
    if (!fullObjectID(sha)) throw new Error(t("Couldn't resolve this commit."));
    return sha;
  }
  async loadRevisionComparison() {
    const path = this.path; if (!path) return;
    const request = ++this.historyToolsGeneration, s = this.historyTools;
    const current = () => request === this.historyToolsGeneration && this.path === path && this.historyTools === s;
    const { left: leftInput, right: rightInput, useMergeBase } = s;
    s.comparisonLoading = true; s.comparisonError = null; s.comparison = null; s.comparisonPatch = ""; this.emit();
    try {
      const [left, right] = await Promise.all([this.resolveHistoryRevision(leftInput, path), this.resolveHistoryRevision(rightInput, path)]);
      const base = useMergeBase ? (await git(["merge-base", left, right], path)).stdout.trim() : left;
      if (!fullObjectID(base)) throw new Error(t("These revisions have no common ancestor. Use direct comparison."));
      const [files, stats] = await Promise.all([git(["diff", "--no-ext-diff", "-M", "--name-status", "-z", base, right, "--"], path), git(["diff", "--no-ext-diff", "-M", "--numstat", "-z", base, right, "--"], path)]);
      if (!current()) return;
      s.comparison = { left, right, base, mergeBase: useMergeBase, files: parseNameStatus(files.stdout), stats: parseNumstat(stats.stdout) };
      if (s.comparison.files[0]) await this.selectComparisonFile(s.comparison.files[0]);
    } catch (e) { if (current()) s.comparisonError = describe(e); }
    finally { if (current()) { s.comparisonLoading = false; this.emit(); } }
  }
  async selectComparisonFile(file: FileChange) {
    const s = this.historyTools, comparison = s.comparison, path = this.path;
    if (!comparison || !path) return;
    const request = ++this.comparisonFileGeneration;
    s.comparisonPath = file.path; s.comparisonPatch = ""; this.emit();
    try {
      const r = await git(["diff", "--no-ext-diff", "--no-textconv", "-M", comparison.base, comparison.right, "--", ...changePaths(file)], path);
      if (this.path !== path || this.historyTools !== s || s.comparison !== comparison || request !== this.comparisonFileGeneration) return;
      s.comparisonPatch = r.stdout.length > 2_000_000 ? r.stdout.slice(0, 2_000_000) + "\n" + t("Output truncated. Narrow the selection.") : r.stdout;
    } catch (e) { if (this.path === path && this.historyTools === s && request === this.comparisonFileGeneration) s.comparisonPatch = describe(e); }
    this.emit();
  }
  async openBatchCommits(action: BatchCommitAction = "cherry-pick") {
    const path = this.path; if (!path || !this.historyTools.selected.length) return;
    this.cancelHistoryTools();
    const request = this.historyToolsGeneration, s = this.historyTools;
    const current = () => request === this.historyToolsGeneration && this.path === path && this.historyTools === s;
    const chosen = new Set(s.selected);
    s.batchAction = action; s.batch = []; s.batchError = null; s.batchLoading = true;
    this.sheet = { kind: "batchCommits" }; this.emit();
    try {
      s.batchHead = await this.resolveHistoryRevision("HEAD", path);
      s.batchBranch = (await git(["symbolic-ref", "--quiet", "HEAD"], path)).stdout.trim();
      const ordered = this.entries.filter((e) => chosen.has(e.commit.id)).map((e) => e.commit.id).reverse();
      if (ordered.length !== chosen.size) throw new Error(t("Some selected commits are outside the graph. Select them again."));
      const records = await Promise.all(ordered.map(async (sha): Promise<BatchCommitItem> => {
        const r = await git(["show", "--no-patch", "--format=%H%x1f%P%x1f%an%x1f%B", sha], path);
        const [id, parents, author, ...message] = r.stdout.trimEnd().split("\x1f");
        return { sha: id, parents: parents.split(" ").filter(Boolean), author, message: message.join("\x1f"), subject: message.join("\x1f").split("\n")[0] };
      }));
      if (!current()) return;
      s.batch = action === "revert" ? records.reverse() : records;
      if (records.some((item) => item.parents.length > 1)) s.batchError = t("Merge commits need a mainline choice. Select non-merge commits.");
    } catch (e) { if (current()) s.batchError = describe(e); }
    finally { if (current()) { s.batchLoading = false; this.emit(); } }
  }
  async executeBatchCommits() {
    const path = this.path, s = this.historyTools, request = this.historyToolsGeneration;
    if (!path || this.busy || s.batchLoading || s.batchError || !s.batch.length) return;
    const current = () => request === this.historyToolsGeneration && this.path === path && this.historyTools === s;
    s.batchLoading = true; this.emit();
    try {
      const [head, branch, status] = await Promise.all([this.resolveHistoryRevision("HEAD", path), git(["symbolic-ref", "--quiet", "HEAD"], path), git(["status", "--porcelain=v1", "--untracked-files=normal"], path)]);
      if (!current()) return;
      if (head !== s.batchHead || branch.stdout.trim() !== s.batchBranch) throw new Error(t("The repository changed. Open this review again."));
      const pending = this.gitDir ? await historyOperationInProgress(this.gitDir) : true;
      if (!current()) return;
      if (status.stdout || pending || this.repoState !== "clean") throw new Error(t("Commit or stash changes and finish the current Git operation first."));
      if (s.batch.some((item) => item.parents.length > 1)) throw new Error(t("Merge commits need a mainline choice. Select non-merge commits."));
      if (s.batchAction === "squash" || s.batchAction === "drop") {
        const selected = new Set(s.batch.map((item) => item.sha));
        const first = s.batch.find((item) => !item.parents.some((parent) => selected.has(parent)));
        if (!first || !fullObjectID(first.sha)) throw new Error(t("Select at least one commit."));
        // 선택하지 않은 커밋은 그대로 두며 범위 안의 머지는 기존 제약으로 막는다.
        this.rebasePlan = null;
        const plan = await this.startInteractiveRebase(first.sha, false);
        if (!current()) return;
        if (!plan) throw new Error(t("The repository changed. Open this review again."));
        if (s.batchAction === "squash") {
          const indexes = plan.items.map((item, i) => selected.has(item.sha) ? i : -1).filter((i) => i >= 0);
          if (indexes.length !== selected.size || Math.max(...indexes) - Math.min(...indexes) + 1 !== selected.size || selected.size < 2) throw new Error(t("Squash requires adjacent commits on the current branch."));
          const oldest = Math.max(...indexes);
          plan.items = plan.items.map((item, i) => ({ ...item, action: selected.has(item.sha) && i !== oldest ? "squash" : "pick" }));
        } else {
          if (![...selected].every((sha) => plan.items.some((item) => item.sha === sha))) throw new Error(t("Select commits on the current branch."));
          plan.items = plan.items.map((item) => ({ ...item, action: selected.has(item.sha) ? "drop" : "pick" }));
        }
        this.rebasePlan = makePlan(plan.base, plan.items, plan.pushed);
        this.rebasePlan.expectedHead = head;
        this.sheet = { kind: "interactiveRebase" };
      } else {
        const args = batchArguments(s.batchAction, s.batch);
        const backup = `refs/gitrochi/batch/${crypto.randomUUID()}`;
        await git(["update-ref", "--create-reflog", backup, head, ""], path);
        if (!current()) return;
        this.sheet = null;
        await this.run(t("Applying selected commits…"), args);
      }
    } catch (e) { if (current()) { s.batchError = describe(e); this.sheet = { kind: "batchCommits" }; } }
    finally { if (current()) { s.batchLoading = false; this.emit(); } }
  }
  openLineHistory(path?: string, revision?: string, start = 1, end = start) {
    this.cancelHistoryTools(); const s = this.historyTools;
    s.linePath = path ?? this.fileInspect?.path ?? this.diffSource?.change.path ?? "";
    s.lineRevision = revision ?? this.fileInspect?.rev ?? (this.diffSource?.kind === "commit" ? this.diffSource.sha : "HEAD");
    s.lineStart = start; s.lineEnd = end; s.functionName = ""; s.lineEntries = []; s.lineError = null; s.lineTruncated = false;
    this.sheet = { kind: "lineHistory" }; this.emit();
  }
  openSelectedLineHistory() {
    const source = this.diffSource; if (!source) return;
    const lines = this.diff?.lines.filter((_line, index) => this.diffSelection.has(index)) ?? [];
    let path = source.change.path;
    let revision: string | undefined;
    let numbers = lines.flatMap((line) => line.newNo == null ? [] : [line.newNo]);
    if (!numbers.length) numbers = lines.flatMap((line) => line.oldNo == null ? [] : [line.oldNo]);
    if (source.kind === "commit") {
      revision = source.sha;
      if (lines.length && !lines.some((line) => line.newNo != null)) {
        path = source.change.oldPath ?? path; revision = source.parent ?? undefined;
        numbers = lines.flatMap((line) => line.oldNo == null ? [] : [line.oldNo]);
      }
    }
    this.openLineHistory(path, revision, numbers.length ? Math.min(...numbers) : 1, numbers.length ? Math.max(...numbers) : 1);
  }
  async loadLineHistory() {
    const path = this.path; if (!path) return;
    const request = ++this.historyToolsGeneration, s = this.historyTools;
    const current = () => this.path === path && this.historyTools === s && request === this.historyToolsGeneration;
    s.lineLoading = true; s.lineError = null; s.lineEntries = []; this.emit();
    try {
      const range = lineHistoryRange(s.linePath, s.lineStart, s.lineEnd, s.functionName);
      const sha = await this.resolveHistoryRevision(s.lineRevision, path);
      const r = await git(["log", "--no-ext-diff", "--no-textconv", "--max-count=200", "--date=short", "--format=%x1e%H%x1f%an%x1f%ad%x1f%s", "-L", range, sha, "--"], path, { timeoutMs: 120_000 });
      if (!current()) return;
      s.lineTruncated = r.stdout.length > 2_000_000;
      s.lineEntries = parseLineHistory(r.stdout.slice(0, 2_000_000));
      s.lineSelected = s.lineEntries[0]?.sha ?? null;
    } catch (e) { if (current()) s.lineError = describe(e); }
    finally { if (current()) { s.lineLoading = false; this.emit(); } }
  }
}
