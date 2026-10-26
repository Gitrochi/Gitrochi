import { ipc } from "@/shared/api";
import { accounts } from "@/entities/hosting";
import { dirname, joinPath, samePath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { describe, git, gitRaw } from "@/shared/platform";
import { emptyLocalWorkflows, parseRecoveryRefs, parseReflog, safeRepoPath, safeSubmoduleURL, type RecoveryEntry, type SubmoduleEntry } from "../../lib/local-workflows";
import { RepoHistoryTools } from "./history-tools";

/** 별도 인덱스로 보관하므로 안전 사본을 만들 때 사용자의 작업 파일·스테이지는 건드리지 않는다. */
export abstract class RepoLocalWorkflows extends RepoHistoryTools {
  localWorkflows = emptyLocalWorkflows();
  private localEpoch = 0;
  protected resetState() { this.localEpoch++; this.localWorkflows = emptyLocalWorkflows(); super.resetState(); }

  async loadLocalWorkflows() {
    const repo = this.path, epoch = ++this.localEpoch;
    if (!repo) return;
    this.localWorkflows.loading = true; this.localWorkflows.error = null; this.emit();
    try {
      const safetyPrefix = await this.safetyPrefix(repo);
      const [refs, reflog, lfs, files, patterns, modules, config, bisect, head, indexEntries] = await Promise.all([
        gitRaw(["for-each-ref", "--format=%(refname) %(objectname)", safetyPrefix], repo),
        gitRaw(["reflog", "show", "--all", "-n", "300", "--format=%H%x1f%gd%x1f%gs%x1f%aI"], repo),
        gitRaw(["lfs", "version"], repo), gitRaw(["lfs", "ls-files"], repo), gitRaw(["lfs", "track"], repo),
        gitRaw(["submodule", "status"], repo), gitRaw(["config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.(path|url)$"], repo),
        gitRaw(["bisect", "log"], repo), gitRaw(["log", "-1", "--format=%h %s"], repo),
        gitRaw(["ls-files", "--stage", "-z"], repo),
      ]);
      if (this.path !== repo || epoch !== this.localEpoch) return;
      const urls = new Map<string, { path?: string; url?: string }>();
      for (const line of config.stdout.split("\n")) { const match = /^submodule\.(.+)\.(path|url) (.*)$/.exec(line); if (!match) continue; const entry = urls.get(match[1]) ?? {}; entry[match[2] as "path" | "url"] = match[3]; urls.set(match[1], entry); }
      const recorded = new Map(indexEntries.stdout.split("\0").flatMap((line) => { const m = /^160000 ([a-f0-9]{40,64}) 0\t(.+)$/.exec(line); return m ? [[m[2], m[1]]] : []; }));
      const entries: SubmoduleEntry[] = modules.stdout.split("\n").flatMap((line) => { const m = /^([-+ U])([a-f0-9]{40,64}) (.+?)(?: \(.*\))?$/.exec(line); if (!m) return []; const config = [...urls.entries()].find(([, u]) => u.path === m[3]); return [{ status: m[1], sha: recorded.get(m[3]) ?? m[2], path: m[3], url: config?.[1].url ?? "", configName: config?.[0] ?? "" }]; });
      this.localWorkflows = { ...this.localWorkflows, recovery: parseRecoveryRefs(refs.stdout), reflog: parseReflog(reflog.stdout), lfsAvailable: lfs.status === 0, lfsFiles: files.status === 0 ? files.stdout : "", lfsPatterns: patterns.status === 0 ? patterns.stdout : "", submodules: entries, bisectActive: bisect.status === 0, bisectLog: bisect.status === 0 ? bisect.stdout : "", bisectCurrent: head.stdout.trim(), bisectResult: [...bisect.stdout.matchAll(/^# first '?bad'? commit: \[([a-f0-9]+)\] (.*)$/gm)].at(-1)?.slice(1).join(" ") ?? "" };
    } catch (e) { if (this.path === repo && epoch === this.localEpoch) this.localWorkflows.error = describe(e); }
    finally { if (this.path === repo && epoch === this.localEpoch) { this.localWorkflows.loading = false; this.emit(); } }
  }

  async preserveDiscardedChanges(paths?: string[]): Promise<boolean> {
    const repo = this.path, epoch = this.localEpoch;
    if (!repo || this.busy || this.status.conflicted.length || (paths && !paths.every(safeRepoPath))) return false;
    const directory = this.gitDir ?? (await git(["rev-parse", "--absolute-git-dir"], repo)).stdout.trim();
    const indexFile = joinPath(directory, `gitrochi-safety-index-${crypto.randomUUID()}`);
    const temp = { env: { GIT_INDEX_FILE: indexFile } };
    try {
      const headResult = await gitRaw(["rev-parse", "--verify", "HEAD"], repo);
      const head = headResult.status === 0 ? headResult.stdout.trim() : (await git(["hash-object", "-w", "-t", "tree", "--stdin"], repo, { input: "" })).stdout.trim();
      const index = (await git(["write-tree"], repo)).stdout.trim();
      const names = (await git(["ls-files", "-co", "--exclude-standard", "-z"], repo)).stdout.split("\0").filter(Boolean);
      if (names.length > 20_000 || !names.every(safeRepoPath)) throw new Error(t("The safety copy exceeds the supported file count or contains an unsafe path."));
      let size = 0;
      for (const name of new Set(names)) { const info = await ipc.readHead(joinPath(repo, name), 1).catch(() => null); size += info?.size ?? 0; if (size > 200_000_000) throw new Error(t("The safety copy exceeds 200 MB. Preserve these changes manually before discarding.")); }
      await git(["read-tree", head], repo, temp);
      await git(["add", "-A", "--", "."], repo, temp);
      const worktree = (await git(["write-tree"], repo, temp)).stdout.trim();
      // 상태 문자열이 같아도 파일 내용은 바뀔 수 있어 실제 트리를 다시 대조한다.
      await git(["add", "-A", "--", "."], repo, temp);
      const verify = (await git(["write-tree"], repo, temp)).stdout.trim();
      const currentIndex = (await git(["write-tree"], repo)).stdout.trim();
      const current = await gitRaw(["rev-parse", "--verify", "HEAD"], repo);
      const currentHead = current.status === 0 ? current.stdout.trim() : head;
      if (this.path !== repo || epoch !== this.localEpoch || worktree !== verify || index !== currentIndex || head !== currentHead) throw new Error(t("The repository changed while making the safety copy. Try again."));
      const id = `${Date.now()}-${crypto.randomUUID()}`;
      const prefix = `${await this.safetyPrefix(repo)}/${id}`;
      await git(["update-ref", "--stdin"], repo, { input: `start\ncreate ${prefix}/worktree ${worktree}\ncreate ${prefix}/index ${index}\ncreate ${prefix}/head ${head}\nprepare\ncommit\n` });
      if (this.path !== repo || epoch !== this.localEpoch) return false;
      await git(["add", "-A", "--", "."], repo, temp);
      const [finalTree, finalIndex, finalHead] = await Promise.all([git(["write-tree"], repo, temp), git(["write-tree"], repo), gitRaw(["rev-parse", "--verify", "HEAD"], repo)]);
      if (this.path !== repo || epoch !== this.localEpoch || finalTree.stdout.trim() !== worktree || finalIndex.stdout.trim() !== index || (finalHead.status === 0 ? finalHead.stdout.trim() !== head : headResult.status === 0)) throw new Error(t("The repository changed while making the safety copy. Try again."));
      this.localWorkflows.notice = t("A local safety copy was saved in Repository tools → Recovery.");
      return true;
    } catch (e) { if (this.path === repo && epoch === this.localEpoch) this.showError(t("Changes were not discarded because a safety copy could not be saved.\n\n") + describe(e)); return false; }
    finally { await ipc.remove(indexFile).catch(() => {}); }
  }

  async previewRecovery(entry: RecoveryEntry) {
    const repo = this.path, epoch = this.localEpoch;
    if (!repo) return;
    try {
      const [worktree, index] = await Promise.all([git(["diff", "--no-ext-diff", "--no-textconv", "--stat", "--patch", entry.head, entry.worktree, "--"], repo), git(["diff", "--no-ext-diff", "--no-textconv", "--stat", "--patch", entry.head, entry.index, "--"], repo)]);
      if (this.path === repo && epoch === this.localEpoch) { const preview = `${t("Saved index")}\n${index.stdout}\n${t("Saved working tree")}\n${worktree.stdout}`; this.localWorkflows.preview = preview.slice(0, 200_000) + (preview.length > 200_000 ? `\n${t("Preview truncated. The complete safety copy is retained.")}` : ""); this.emit(); }
    } catch (e) { if (this.path === repo && epoch === this.localEpoch) this.fail(e); }
  }

  async restoreSafetyCopy(entry: RecoveryEntry) {
    const repo = this.path, epoch = this.localEpoch;
    if (!repo || this.busy) return;
    this.ask({ title: t("Restore the saved working tree and index?"), message: t("Restoring requires a clean working tree at the original commit. The saved staged and unstaged changes, including new files, will return."), actionTitle: t("Restore safety copy"), destructive: false, action: async () => {
      if (this.path !== repo || epoch !== this.localEpoch) return;
      const [status, head] = await Promise.all([git(["status", "--porcelain=v2", "--untracked-files=all"], repo), gitRaw(["rev-parse", "--verify", "HEAD"], repo)]);
      const headOID = head.status === 0 ? head.stdout.trim() : (await git(["hash-object", "-w", "-t", "tree", "--stdin"], repo, { input: "" })).stdout.trim();
      if (status.stdout.trim() || headOID !== entry.head || this.repoState !== "clean") { this.showError(t("Return to the original commit with a clean working tree before restoring. The safety copy is kept.")); return; }
      const available = parseRecoveryRefs((await git(["for-each-ref", "--format=%(refname) %(objectname)", `${await this.safetyPrefix(repo)}/${entry.id}`], repo)).stdout).find((p) => p.id === entry.id);
      if (!available || JSON.stringify(available) !== JSON.stringify(entry) || this.path !== repo || epoch !== this.localEpoch) return;
      if (await this.run(t("Restoring safety copy…"), ["restore", `--source=${entry.worktree}`, "--worktree", "--", "."])) await this.run(t("Restoring index…"), ["restore", `--source=${entry.index}`, "--staged", "--", "."]);
      await this.loadLocalWorkflows();
    } });
  }

  async recoverCommit(sha: string, branch: string) {
    const repo = this.path, epoch = this.localEpoch;
    if (!/^[a-f0-9]{40,64}$/.test(sha) || !branch.trim() || branch.startsWith("-")) return;
    if (!(await this.g(["check-ref-format", "--branch", branch], { ok: [0, 1, 128] })).status && this.path === repo && epoch === this.localEpoch) await this.run(t("Creating recovery branch…"), ["branch", branch, sha]);
  }

  async lfsTrack(pattern: string, remove = false) {
    if (!pattern.trim() || pattern.startsWith("-") || /[\r\n\0]/.test(pattern) || !this.localWorkflows.lfsAvailable) return;
    await this.run(t("Updating LFS patterns…"), ["lfs", remove ? "untrack" : "track", "--", pattern.trim()]); await this.loadLocalWorkflows();
  }
  async checkLfs() { await this.toolCommand(["lfs", "fsck"], false); }
  async loadLfsLocks() {
    const repo = this.path, epoch = this.localEpoch; if (!repo) return;
    try { const env = await accounts.gitEnvironment(this.target, repo); if (this.path !== repo || epoch !== this.localEpoch) return; const r = await git(["lfs", "locks", "--json"], repo, { env }); const data: unknown = JSON.parse(r.stdout); if (!data || typeof data !== "object") return; const locks = (data as { locks?: { id: string; path: string; owner?: { name?: string } }[] }).locks ?? []; if (this.path === repo && epoch === this.localEpoch) { this.localWorkflows.lfsLocks = locks.map((l) => ({ id: l.id, path: l.path, owner: l.owner?.name ?? "" })); this.emit(); } } catch (e) { if (this.path === repo && epoch === this.localEpoch) this.fail(e); }
  }
  async lfsLock(path: string) { if (safeRepoPath(path)) await this.toolCommand(["lfs", "lock", path], true); }
  async lfsUnlock(id: string) { const repo = this.path, epoch = this.localEpoch; if (!/^[a-zA-Z0-9_-]+$/.test(id)) return; this.ask({ title: t("Unlock this LFS file?"), message: t("The server lock will be removed. No force unlock is used."), actionTitle: t("Unlock"), destructive: true, action: async () => { if (this.path === repo && epoch === this.localEpoch) await this.toolCommand(["lfs", "unlock", `--id=${id}`], true); } }); }

  async updateSubmodule(entry: SubmoduleEntry) {
    const repo = this.path, epoch = this.localEpoch;
    if (!repo || !safeRepoPath(entry.path) || !safeSubmoduleURL(entry.url) || !entry.configName || /[\r\n=\0]/.test(entry.configName)) { this.showError(t("Only validated HTTPS or SSH submodule URLs are allowed. Review .gitmodules first.")); return; }
    this.ask({ title: t("Initialize or update this submodule?"), message: `${entry.path}\n${entry.url}\n${t("Check out the exact commit recorded by the parent repository. Local submodule changes block the update.")}`, actionTitle: t("Update submodule"), destructive: false, action: async () => {
      if (this.path !== repo || epoch !== this.localEpoch) return;
      if (!(await this.submodulePathSafe(repo, entry.path, entry.status !== "-"))) { this.showError(t("The submodule path resolves outside this repository. Review its folder first.")); return; }
      const config = (await git(["config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.(path|url)$"], repo)).stdout;
      if (!config.split("\n").includes(`submodule.${entry.configName}.url ${entry.url}`) || !config.split("\n").includes(`submodule.${entry.configName}.path ${entry.path}`)) { this.showError(t("Submodule configuration changed. Refresh before updating.")); return; }
      const recorded = (await git(["ls-files", "--stage", "-z", "--", entry.path], repo)).stdout;
      if (!recorded.startsWith(`160000 ${entry.sha} 0\t`)) { this.showError(t("Submodule configuration changed. Refresh before updating.")); return; }
      const local = await gitRaw(["-C", entry.path, "status", "--porcelain=v2", "--untracked-files=all"], repo);
      if (entry.status !== "-" && (local.status !== 0 || local.stdout.trim())) { this.showError(t("Commit or stash changes inside the submodule first.")); return; }
      if (entry.status !== "-") { const remote = await gitRaw(["-C", entry.path, "remote", "get-url", "origin"], repo); if (remote.status !== 0 || remote.stdout.trim() !== entry.url) { this.showError(t("The submodule remote differs from the reviewed URL. Review its origin configuration first.")); return; } }
      if (this.path !== repo || epoch !== this.localEpoch) return;
      await this.toolCommand(["-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never", "-c", `submodule.${entry.configName}.url=${entry.url}`, "submodule", "update", "--init", "--checkout", "--", entry.path], false);
    } });
  }
  openSubmodule(path: string) { if (safeRepoPath(path) && this.path) this.openRepo?.(joinPath(this.path, path)); }
  submoduleURLDisplay(url: string) { return safeSubmoduleURL(url) ? url : t("Unvalidated URL hidden"); }

  async startBisect(good: string, bad: string) {
    const repo = this.path;
    if (!repo || !good.trim() || !bad.trim() || good.startsWith("-") || bad.startsWith("-") || this.busy) return;
    const [status, a, b] = await Promise.all([this.g(["status", "--porcelain=v2", "--untracked-files=all"]), this.g(["rev-parse", "--verify", `${good}^{commit}`]), this.g(["rev-parse", "--verify", `${bad}^{commit}`])]);
    if (this.path !== repo) return;
    if (status.stdout.trim() || this.repoState !== "clean" || this.localWorkflows.bisectActive) { this.showError(t("Start bisect with a clean working tree and no operation in progress.")); return; }
    const ancestor = await this.g(["merge-base", "--is-ancestor", a.stdout.trim(), b.stdout.trim()], { ok: [0, 1] });
    if (ancestor.status !== 0) { this.showError(t("The good commit must be an ancestor of the bad commit.")); return; }
    const originalHead = (await this.g(["rev-parse", "HEAD"])).stdout.trim(), epoch = this.localEpoch;
    this.ask({ title: t("Start finding the first bad commit?"), message: t("Git will temporarily check out commits for you to test. Mark each commit good, bad, or skip. Reset bisect returns to the original branch."), actionTitle: t("Start bisect"), destructive: false, action: async () => {
      const [head, clean, active] = await Promise.all([git(["rev-parse", "HEAD"], repo), git(["status", "--porcelain=v2", "--untracked-files=all"], repo), gitRaw(["bisect", "log"], repo)]);
      if (this.path !== repo || epoch !== this.localEpoch) return;
      if (head.stdout.trim() !== originalHead || clean.stdout.trim() || active.status === 0 || this.repoState !== "clean") { this.showError(t("The repository changed. Refresh before starting bisect.")); return; }
      await this.toolCommand(["bisect", "start", b.stdout.trim(), a.stdout.trim()], false);
    } });
  }
  async markBisect(mark: "good" | "bad" | "skip") {
    const repo = this.path, epoch = this.localEpoch, current = this.localWorkflows.bisectCurrent;
    if (!repo || !this.localWorkflows.bisectActive || this.localWorkflows.bisectResult) return;
    const [status, head, active] = await Promise.all([git(["status", "--porcelain=v2", "--untracked-files=all"], repo), git(["log", "-1", "--format=%h %s"], repo), gitRaw(["bisect", "log"], repo)]);
    if (this.path !== repo || epoch !== this.localEpoch) return;
    if (status.stdout.trim() || head.stdout.trim() !== current || active.status !== 0) { this.showError(t("Keep the working tree clean and refresh the current test commit before marking it.")); return; }
    await this.toolCommand(["bisect", mark], false);
  }
  async resetBisect() { if (this.localWorkflows.bisectActive) await this.toolCommand(["bisect", "reset"], false); }
  private async toolCommand(args: string[], network: boolean) { const repo = this.path; await this.run(t("Running repository tool…"), args, { network }); if (this.path === repo) await this.loadLocalWorkflows(); }
  private async safetyPrefix(repo: string) { const directory = (await git(["rev-parse", "--absolute-git-dir"], repo)).stdout.trim(); const scope = (await git(["hash-object", "--stdin"], repo, { input: directory })).stdout.trim(); return `refs/gitrochi/safety/${scope}`; }
  private async submodulePathSafe(repo: string, path: string, initialized: boolean) {
    const requested = joinPath(repo, path);
    let existing = requested;
    while (!(await ipc.exists(existing))) { const parent = dirname(existing); if (parent === existing || !parent) return false; existing = parent; }
    const top = await gitRaw(["rev-parse", "--show-toplevel"], existing);
    if (top.status !== 0) return false;
    const canonicalRepo = (await git(["rev-parse", "--show-toplevel"], repo)).stdout.trim();
    return samePath(top.stdout.trim(), initialized ? joinPath(canonicalRepo, path) : canonicalRepo);
  }
}
