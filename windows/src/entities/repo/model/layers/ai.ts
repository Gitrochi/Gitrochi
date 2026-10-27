import { ai, changeQuestionLimits, changeQuestionPrompt, changeQuestionSystem, createChangeQuestionSnapshot, type ChangeQuestionMessage, type ChangeQuestionSnapshot, type AIProviderId, clip, Prompts, providerById, splitMessage } from "@/entities/ai";
import { gitch, type GraphReview } from "@/entities/gitch";
import { type FileChange, parseSplitPlan, type SplitGroup } from "@/entities/git";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { describe, git } from "@/shared/platform";
import { RepoIssues } from "./issues";

export interface ChangeQuestionSession {
  readonly repository: string;
  readonly origin: string;
  readonly provider: AIProviderId;
  readonly providerTitle: string;
  readonly system: string;
  readonly configuration: string;
  snapshot: ChangeQuestionSnapshot | null;
  loading: boolean;
  question: string;
  messages: ChangeQuestionMessage[];
  error: string | null;
  working: boolean;
  active: boolean;
  generation: number;
}

const changeQuestionConfiguration = () => {
  const provider = ai.providerFor("explain");
  return JSON.stringify([provider, ai.model(provider), provider === "compatible" ? ai.baseURL : "", ai.instructions.global ?? "", ai.instructions.explain ?? ""]);
};

/** AI: 커밋 메시지·설명·PR 글, 나눠서 커밋 */
export abstract class RepoAI extends RepoIssues {
  changeQuestionSession: ChangeQuestionSession | null = null;

  /** 보내기 전에는 AI를 호출하지 않고, 사용자가 확인할 로컬 스냅샷만 준비한다. */
  async openChangeQuestion(refresh = false) {
    const repository = this.path;
    if (!repository) return;
    const origin = JSON.stringify([this.diffSource, this.selection, this.headHash]);
    const existing = this.changeQuestionSession;
    if (!refresh && existing?.repository === repository && existing.origin === origin && existing.snapshot) {
      existing.active = true;
      this.openSheet({ kind: "askChanges" });
      return;
    }
    this.cancelChangeQuestion();
    const provider = ai.providerFor("explain");
    const model = ai.model(provider);
    const session: ChangeQuestionSession = { repository, origin, provider, providerTitle: providerById(provider).title + (model ? ` · ${model}` : ""),
      system: ai.systemFor("explain", changeQuestionSystem), configuration: changeQuestionConfiguration(), snapshot: null, loading: true, question: "", messages: [], error: null, working: false, active: true, generation: 0 };
    this.changeQuestionSession = session;
    this.openSheet({ kind: "askChanges" });
    // 기다리는 사이 선택이 바뀌어도 같은 표시 내용을 참조한다.
    const source = this.diffSource;
    const selection = this.selection;
    const doc = this.diff;
    const picked = new Set(this.diffSelection);
    const loading = this.diffLoading;
    const ignoreWhitespace = this.diffIgnoreWhitespace;
    const current = () => this.path === repository && this.changeQuestionSession === session && session.active;
    try {
      const head = (await git(["rev-parse", "--verify", "HEAD"], repository).catch(() => null))?.stdout.trim() || "(unborn HEAD)";
      let scope: string, path: string | null = null, text: string;
      const limitations: string[] = [];
      let impact: string | null = null;
      if (source) {
        path = source.change.path;
        scope = source.kind === "review" ? `PR/MR #${source.number}` : source.kind === "commit" ? `${t("Commit")} ${source.sha}`
          : source.change.kind === "untracked" ? t("Untracked file") : source.change.staged ? t("Staged file") : t("Unstaged file");
        // 새 파일도 이미 읽은 표시 내용을 재사용해 경로를 다시 읽거나 심볼릭 링크를 따라가지 않는다.
        if (!doc || loading) throw new Error(t("Wait for the selected diff to finish loading."));
        if (doc.error) throw new Error(doc.error);
        if (doc.isBinary) throw new Error(t("This is a binary file. Select a text diff to ask AI."));
        if (doc.truncated) limitations.push(t("The displayed diff was truncated."));
        if (ignoreWhitespace) limitations.push(t("Whitespace-only changes are hidden in this snapshot."));
        if (picked.size) {
          text = doc.lines.filter((_, i) => picked.has(i)).map((l) => `old:${l.oldNo ?? "-"} new:${l.newNo ?? "-"} ${l.kind === "added" ? "+" : l.kind === "removed" ? "-" : " "}${l.raw ?? l.text}`).join("\n");
          scope += ` · ${t("Selected lines")}`;
          limitations.push(t("Only selected lines are included; surrounding code may be missing."));
        } else {
          text = [...doc.header, ...doc.lines.map((l) => l.kind === "added" ? "+" + (l.raw ?? l.text) : l.kind === "removed" ? "-" + (l.raw ?? l.text) : l.kind === "context" ? " " + (l.raw ?? l.text) : l.raw || l.text)].join("\n");
        }
      } else if (selection?.kind === "commit") {
        scope = `${t("Commit")} ${selection.sha}`;
        text = (await git(["show", "--stat", "--patch", "--diff-merges=first-parent", "--no-ext-diff", "--no-textconv", "--format=commit %H%n%B", selection.sha], repository)).stdout;
      } else if (selection?.kind === "pullRequest") {
        throw new Error(t("Select a PR/MR file to ask AI about its changes."));
      } else {
        scope = t("Staged changes");
        const before = await gitch.commitReviewStamp(repository).catch(() => null);
        text = (await git(["diff", "--cached", "--no-ext-diff", "--no-textconv", "-M", "--stat", "--patch"], repository)).stdout;
        // 뒤 단계 gitch 분석 결과는 스테이지를 읽기 전후의 식별값이 같을 때만 첨부한다.
        const state = (this as unknown as { commitImpact?: { kind: string; result?: GraphReview }; commitImpactStale?: boolean }).commitImpact;
        const report = state?.kind === "done" ? state.result : null;
        if (before && report && !report.stale && report.stamp === before && report.headSha === (head === "(unborn HEAD)" ? "" : head)
          && await gitch.commitReviewStamp(repository).catch(() => null) === before) {
          impact = JSON.stringify({ changed: report.changed, direct: report.direct, indirect: report.indirect, testCandidatesNotRun: report.tests, limitations: report.limitations }, null, 2);
        }
        if (!text.trim()) throw new Error(t("No staged changes. Stage files first."));
      }
      if (!text.trim()) throw new Error(t("No text changes are available for this selection."));
      if (!current()) return;
      session.snapshot = createChangeQuestionSnapshot({ repository, head, scope, path, diff: text, limitations, impact });
    } catch (error) {
      if (!current()) return;
      session.error = describe(error);
    } finally {
      if (current()) { session.loading = false; this.emit(); }
    }
  }

  setChangeQuestion(question: string) {
    if (!this.changeQuestionSession) return;
    this.changeQuestionSession.question = question;
    this.emit();
  }

  async sendChangeQuestion() {
    const session = this.changeQuestionSession;
    if (!session?.snapshot || !session.active || session.working || this.path !== session.repository) return;
    const question = session.question.trim();
    if (!question || question.length > changeQuestionLimits.question) return;
    if (session.configuration !== changeQuestionConfiguration()) {
      session.error = t("AI settings changed. Choose New snapshot before sending.");
      this.emit();
      return;
    }
    const problem = ai.problem(session.provider);
    if (problem) { session.error = problem; this.emit(); return; }
    const request = ++session.generation;
    session.working = true;
    session.error = null;
    this.emit();
    const current = () => this.path === session.repository && this.changeQuestionSession === session && session.active && session.generation === request;
    try {
      const answer = await ai.complete(session.system, changeQuestionPrompt(session.snapshot, question, session.messages), "medium", session.provider);
      if (!current()) return;
      session.messages = [...session.messages, { role: "user", text: question }, { role: "assistant", text: answer.slice(0, changeQuestionLimits.answer) }];
      if (session.question.trim() === question) session.question = "";
    } catch (error) {
      if (!current()) return;
      session.error = describe(error);
    } finally {
      if (current()) { session.working = false; this.emit(); }
    }
  }

  stopChangeQuestion() {
    const session = this.changeQuestionSession;
    if (!session) return;
    session.generation++;
    session.working = false;
    this.emit();
  }

  cancelChangeQuestion() {
    if (this.changeQuestionSession) this.changeQuestionSession.active = false;
    this.stopChangeQuestion();
  }

  // MARK: 나눠서 커밋 — AI 가 변경 파일을 주요 내용별로 묶고, 확인한 뒤 차례로 커밋한다

  /** 나눌 수 있는 변경(충돌 파일 제외, 스테이지 여부 상관없이) */
  get splittableChanges(): FileChange[] {
    const seen = new Set<string>();
    const out: FileChange[] = [];
    for (const c of [...this.status.staged, ...this.status.unstaged]) {
      if (seen.has(c.path)) continue;
      seen.add(c.path);
      out.push(c);
    }
    return out;
  }

  async planSplit() {
    if (!this.path || this.aiWorking) return;
    const changes = this.splittableChanges;
    if (changes.length < 2) {
      this.errorMessage = t("Splitting needs changes in at least two files.");
      this.emit();
      return;
    }
    if (this.status.conflicted.length) {
      this.errorMessage = t("Resolve the conflicts first.");
      this.emit();
      return;
    }
    this.aiWorking = t("{0} is splitting the changes by topic…", ai.shortFor("commit"));
    this.aiNotice = null;
    this.emit();
    try {
      // 스테이지 여부와 상관없이 HEAD 와 비교한 변경 + 새 파일 내용
      const tracked = this.headHash
        ? (await this.g(["diff", "HEAD", "--no-ext-diff", "-M", "--stat", "--patch"])).stdout
        : (await this.g(["diff", "--cached", "--no-ext-diff", "--stat", "--patch"])).stdout;
      const untracked = changes.filter((c) => c.kind === "untracked").slice(0, 40);
      let newFiles = "";
      for (const c of untracked) {
        const head = await ipc.readHead(joinPath(this.path, c.path), 6000).catch(() => null);
        newFiles += `\n=== ${c.path} (new file) ===\n${head ? (head.binary ? "(binary)" : head.text) : "(unreadable)"}\n`;
      }
      let recent = "";
      try {
        recent = (await this.g(["log", "-15", "--format=%s"])).stdout.trim();
      } catch {
        /* 첫 커밋 */
      }
      const list = changes.map((c) => `- ${c.path}${c.oldPath ? ` (renamed from ${c.oldPath})` : ""} [${c.kind}]`).join("\n");
      const clipped = clip(tracked + newFiles, 300_000);
      const prompt = `Branch: ${this.headBranch ?? "(detached HEAD)"}\n\nRecent commit messages (style reference):\n${recent || "(none)"}\n\nChanged files (use these exact paths):\n${list}\n\nChanges:\n${clipped.text}`;
      const text = await ai.write("commit", Prompts.split, prompt, "medium");
      this.splitPlan = parseSplitPlan(text, changes);
      if (clipped.omitted > 0) this.aiNotice = t("The diff was long, so only the beginning was used for splitting ({0}K characters omitted).", Math.floor(clipped.omitted / 1000));
      this.sheet = { kind: "splitCommits" };
    } catch (e) {
      this.errorMessage = describe(e);
    } finally {
      this.aiWorking = null;
      this.emit();
    }
  }

  /** 확인한 계획대로: 인덱스를 비우고 묶음마다 스테이지 → 커밋 */
  async applySplit(groups: SplitGroup[]) {
    const plan = groups.filter((g) => g.files.length && g.message.trim());
    if (!this.path || !plan.length || this.busy != null) return false;
    const byPath = new Map(this.splittableChanges.map((c) => [c.path, c]));
    this.busy = t("Splitting commits…");
    this.emit();
    let done = 0;
    try {
      if (this.headHash) await this.g(["reset", "-q"]);
      else await this.g(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "."]);
      for (const g of plan) {
        this.busy = t("Creating commit {0}/{1}…", done + 1, plan.length);
        this.emit();
        const paths = g.files.flatMap((p) => {
          const c = byPath.get(p);
          return c?.oldPath ? [c.oldPath, p] : [p];
        });
        await this.g(["add", "-A", "--", ...paths], { env: { GIT_LITERAL_PATHSPECS: "1" } });
        await this.g(["commit", "-F", "-"], { input: g.message.trim() + "\n", timeoutMs: 300_000 });
        done++;
      }
      this.summary = "";
      this.message = "";
      this.splitPlan = null;
      return true;
    } catch (e) {
      this.errorMessage = t("Committed {1} of {0} and stopped.\n\n{2}", plan.length, done, describe(e));
      return false;
    } finally {
      this.busy = null;
      await this.reload(true);
      this.emit();
    }
  }

  // 진행 중인 머지·리베이스

  // MARK: - 글 작성(커밋 메시지·설명·PR)

  async generateCommitMessage() {
    if (!this.path || this.aiWorking) return;
    this.aiWorking = t("{0} is writing the commit message…", ai.shortFor("commit"));
    this.aiNotice = null;
    this.emit();
    try {
      const diff = (await this.g(["diff", "--cached", "--no-ext-diff", "-M", "--stat", "--patch"])).stdout;
      if (!diff.trim()) {
        this.errorMessage = t("No staged changes. Stage files first.");
        return;
      }
      let recent = "";
      try {
        recent = (await this.g(["log", "-15", "--format=%s"])).stdout.trim();
      } catch {
        /* 첫 커밋 */
      }
      const clipped = clip(diff);
      const prompt = `Branch: ${this.headBranch ?? "(detached HEAD)"}\n\nRecent commit messages (style reference):\n${recent || "(none)"}\n\nStaged changes:\n${clipped.text}`;
      const text = await ai.write("commit", Prompts.commit, prompt, "low");
      const [s, b] = splitMessage(text);
      this.summary = s;
      this.message = b;
      if (clipped.omitted > 0) this.aiNotice = t("The diff was long, so only the beginning was sent to {0} ({1}K characters omitted).", ai.shortFor("commit"), Math.floor(clipped.omitted / 1000));
    } catch (e) {
      this.errorMessage = describe(e);
    } finally {
      this.aiWorking = null;
      this.emit();
    }
  }

  async explainCommit(sha: string) {
    if (!this.path || this.explaining.has(sha)) return;
    this.explaining.add(sha);
    this.emit();
    try {
      const show = (
        await this.g(["show", "--stat", "--patch", "--diff-merges=first-parent", "--no-ext-diff", "--format=commit %H%nAuthor: %an%nDate: %ad%n%n%B", sha])
      ).stdout;
      const clipped = clip(show);
      let text = await ai.write("explain", Prompts.explain, clipped.text, "medium");
      if (clipped.omitted > 0) text += t("\n\n(The diff was long, so only the beginning was explained.)");
      this.explanations = { ...this.explanations, [sha]: text };
    } catch (e) {
      this.errorMessage = describe(e);
    } finally {
      this.explaining.delete(sha);
      this.emit();
    }
  }

  /** PR 제목·본문 초안: base 이후 커밋들과 diff 로 작성 */
  async draftPullRequest(base: string): Promise<[string, string] | null> {
    const target = this.target;
    if (!this.path || !target) return null;
    const baseRef = this.remoteBranches.some((b) => b.name === `${target.remote}/${base}`) ? `${target.remote}/${base}` : base;
    try {
      const log = (await this.g(["log", "--format=- %s%n%b", `${baseRef}..HEAD`])).stdout;
      const diff = (await this.g(["diff", "--no-ext-diff", "--stat", "--patch", `${baseRef}...HEAD`])).stdout;
      if (!log.trim() && !diff.trim()) {
        this.errorMessage = t("No new commits compared with '{0}'.", base);
        this.emit();
        return null;
      }
      const clipped = clip(diff);
      const prompt = `Branch ${this.headBranch ?? ""} into ${base}.\n\nCommits:\n${log.trim()}\n\nDiff:\n${clipped.text}`;
      return splitMessage(await ai.write("pullRequest", Prompts.pullRequest, prompt, "low"));
    } catch (e) {
      this.fail(e);
      return null;
    }
  }
}
