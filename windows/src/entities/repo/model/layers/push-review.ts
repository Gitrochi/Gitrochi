import { accountHost, displayPushURL, parsePushConfig, pushConfigStamp, resolvePushDestination, reviewedPushArguments, type PushReviewPlan } from "@/entities/git";
import { gitch } from "@/entities/gitch";
import { accounts, findTarget } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { describe, git } from "@/shared/platform";
import { RepoFilters } from "./filters";

/** 확인 창이 열려 있는 동안 저장소·계정·목적지가 바뀌면 새 검토를 요구한다. */
export abstract class RepoPushReview extends RepoFilters {
  pushReview: PushReviewPlan | null = null;
  pushReviewLoading = false;
  pushReviewError: string | null = null;
  private pushReviewCompletion: ((success: boolean) => void) | null = null;
  protected pushReviewGeneration = 0;

  /** 사용자의 Push 검토 확인이 끝난 뒤에만 호출자를 이어 간다. */
  requestPushReview(branch: string, force = false, remoteOverride?: string): Promise<boolean> {
    if (!this.path || this.busy || this.pushReviewCompletion) return Promise.resolve(false);
    this.pushReview = null;
    this.pushReviewError = null;
    this.sheet = { kind: "pushReview", branch, force, remoteOverride };
    const result = new Promise<boolean>((resolve) => { this.pushReviewCompletion = resolve; });
    this.emit();
    return result;
  }

  cancelPushReview() {
    ++this.pushReviewGeneration;
    this.pushReviewLoading = false;
    const complete = this.pushReviewCompletion;
    this.pushReviewCompletion = null;
    this.pushReview = null;
    complete?.(false);
    this.emit();
  }

  async loadPushReview(branch: string, force = false, remoteOverride?: string) {
    const gen = ++this.pushReviewGeneration;
    this.pushReviewLoading = true;
    this.pushReview = null;
    this.pushReviewError = null;
    this.emit();
    try {
      const plan = await this.buildPushReview(branch, force, remoteOverride);
      if (gen === this.pushReviewGeneration) this.pushReview = plan;
    } catch (e) {
      if (gen === this.pushReviewGeneration) this.pushReviewError = displayPushURL(describe(e));
    } finally {
      if (gen === this.pushReviewGeneration) { this.pushReviewLoading = false; this.emit(); }
    }
  }

  private async buildPushReview(branch: string, force: boolean, remoteOverride?: string): Promise<PushReviewPlan> {
    const repo = this.path;
    if (!repo) throw new Error(t("The repository was closed. Open it and review the push again."));
    const g = async (args: string[]) => (await git(args, repo)).stdout;
    const [configOutput, remoteOutput, sourceOutput, currentOutput, status, preflight] = await Promise.all([
      g(["config", "--null", "--list"]), g(["remote"]), g(["rev-parse", "--verify", `refs/heads/${branch}^{commit}`]),
      git(["symbolic-ref", "--quiet", "--short", "HEAD"], repo, { ok: [0, 1] }).then((r) => r.stdout.trim()),
      gitch.status(repo), gitch.preflight(repo, false),
    ]);
    const config = parsePushConfig(configOutput);
    const sourceOID = sourceOutput.trim();
    const { remote, destination, setUpstream } = resolvePushDestination(config, remoteOutput.trim().split("\n").filter(Boolean), branch, currentOutput || null, remoteOverride);
    const urls = (await g(["remote", "get-url", "--push", "--all", remote])).trim().split("\n").filter(Boolean);
    if (urls.length !== 1) throw new Error(t("Multiple push URLs cannot be reviewed as a single destination. Configure one push URL."));
    const pushURL = urls[0];
    const target = findTarget([remote], { [remote]: pushURL }, accounts.accounts.map(accountHost), accounts.sshHostAliases);
    const env = await accounts.gitEnvironment(target, repo);
    const remoteRefs = await git(["ls-remote", "--refs", "--", pushURL, destination], repo, { env });
    const destinationOID = remoteRefs.stdout.trim().split(/\s+/)[0] || null;
    if (destinationOID && !/^[a-f0-9]{40,64}$/i.test(destinationOID)) throw new Error(t("The remote branch could not be read. Refresh and review the push again."));
    if (destinationOID) {
      const object = await git(["cat-file", "-e", `${destinationOID}^{commit}`], repo, { ok: [0, 1, 128] });
      if (object.status !== 0) throw new Error(t("Fetch this remote first so the outgoing commits and files can be reviewed accurately."));
    }
    let range = destinationOID ? [`${destinationOID}..${sourceOID}`] : [sourceOID];
    let comparisonBase = destinationOID;
    let observedHeads: string[] = [];
    if (!destinationOID) {
      const allRefs = await git(["ls-remote", "--symref", "--", pushURL, "HEAD", "refs/heads/*"], repo, { env });
      const rows = allRefs.stdout.trim().split("\n").map((line) => line.split(/\s+/));
      observedHeads = [...new Set(rows.filter(([oid, ref]) => /^[a-f0-9]{40,64}$/i.test(oid) && ref?.startsWith("refs/heads/")).map(([oid]) => oid))].sort();
      const defaultOID = rows.find(([oid, ref]) => /^[a-f0-9]{40,64}$/i.test(oid) && ref === "HEAD")?.[0];
      if (observedHeads.length) {
        const objects = await git(["cat-file", "--batch-check"], repo, { input: observedHeads.join("\n") + "\n" });
        const objectRows = objects.stdout.trim().split("\n");
        if (objectRows.length !== observedHeads.length || objectRows.some((line) => !/^[a-f0-9]{40,64} commit \d+$/i.test(line))) throw new Error(t("Fetch this remote first so the outgoing commits and files can be reviewed accurately."));
        range = [sourceOID, "--not", ...observedHeads];
        const base = await git(["merge-base", sourceOID, defaultOID && observedHeads.includes(defaultOID) ? defaultOID : observedHeads[0]], repo, { ok: [0, 1] });
        comparisonBase = base.stdout.trim() || null;
      }
    }
    const [log, count, names] = await Promise.all([
      g(["log", "-200", "--format=%H%x1f%an%x1f%ae%x1f%s", ...range, "--"]),
      g(["rev-list", "--count", ...range, "--"]),
      g(comparisonBase ? ["diff", "--name-only", "-z", comparisonBase, sourceOID, "--"] : ["ls-tree", "-r", "--name-only", "-z", sourceOID]),
    ]);
    const connected = target ? accounts.accountFor(target, repo) : null;
    const account = status?.lockedAccount || connected?.username || status?.pushAccount || status?.account || t("System Git credentials");
    const credentialAccount = connected?.username ?? t("System Git credentials");
    const author = [config["user.name"]?.at(-1), config["user.email"]?.at(-1) ? `<${config["user.email"].at(-1)}>` : null].filter(Boolean).join(" ");
    const files = names.split("\0").filter(Boolean);
    return {
      repo, branch, sourceOID, remote, destination, pushURL, displayURL: displayPushURL(pushURL), destinationOID, force, setUpstream,
      stamp: JSON.stringify([pushConfigStamp(config), sourceOID, remote, destination, pushURL, destinationOID, account, credentialAccount, author, accounts.revision, remoteOverride ?? null, observedHeads, comparisonBase]),
      author: author || t("Not configured"), account, credentialAccount,
      preflight: preflight ? { result: preflight.result, checks: preflight.checks.map((check) => ({ ...check, message: displayPushURL(check.message) })) } : { result: "STOP", checks: [{ level: "STOP", code: "unavailable", message: t("The gitch preflight check is unavailable. Open Settings → CLI and repair gitch before pushing.") }] },
      commits: log.trim().split("\n").filter(Boolean).map((line) => { const [sha, author, email, ...subject] = line.split("\x1f"); return { sha, author, email, subject: subject.join("\x1f") }; }),
      commitCount: Number(count.trim()) || 0, files: files.slice(0, 500), fileCount: files.length, fileScope: comparisonBase ? "changes" : "snapshot", comparisonBase,
    };
  }

  /** 다시 읽은 계획이 같고 사전 점검이 통과할 때만 고정 refspec 을 실행한다. */
  async confirmPushReview(): Promise<boolean> {
    const plan = this.pushReview;
    const sheet = this.sheet;
    if (!plan || this.pushReviewLoading || this.busy || sheet?.kind !== "pushReview" || plan.preflight.result === "STOP") return false;
    const gen = this.pushReviewGeneration;
    this.pushReviewLoading = true;
    this.pushReviewError = null;
    this.emit();
    try {
      const active = () => gen === this.pushReviewGeneration && this.path === plan.repo && this.sheet === sheet;
      const fresh = await this.buildPushReview(plan.branch, plan.force, sheet.remoteOverride);
      if (!active()) return false;
      this.pushReview = fresh;
      if (fresh.stamp !== plan.stamp) {
        this.pushReviewError = t("The branch, account or push destination changed. Review the updated details and confirm again.");
        return false;
      }
      if (fresh.preflight.result === "STOP") return false;
      const target = findTarget([plan.remote], { [plan.remote]: plan.pushURL }, accounts.accounts.map(accountHost), accounts.sshHostAliases);
      const env = await accounts.gitEnvironment(target, plan.repo);
      if (!active()) return false;
      const success = await this.run(t("Pushing…"), reviewedPushArguments(fresh), { network: true, env });
      if (!active()) return false;
      if (!success) {
        this.pushReviewError = this.pushReviewError ?? (this.errorMessage ? displayPushURL(this.errorMessage) : null);
        this.errorMessage = null;
        return false;
      }
      if (fresh.setUpstream && this.path === fresh.repo) {
        // SHA 로 push 했으므로 Git 이 자동으로 만들지 않는 추적 설정만 성공 뒤 저장한다.
        await git(["config", `branch.${fresh.branch}.remote`, fresh.remote], fresh.repo);
        if (!active()) return false;
        await git(["config", `branch.${fresh.branch}.merge`, fresh.destination], fresh.repo);
        if (!active()) return false;
        await this.reload(true);
        if (!active()) return false;
      }
      await this.loadPullRequests();
      if (!active()) return false;
      await this.ci.refreshBadges();
      if (!active()) return false;
      const complete = this.pushReviewCompletion;
      this.pushReviewCompletion = null;
      this.sheet = null;
      this.pushReview = null;
      complete?.(true);
      return true;
    } catch (e) {
      if (gen === this.pushReviewGeneration && this.path === plan.repo && this.sheet === sheet) this.pushReviewError = displayPushURL(describe(e));
      return false;
    } finally {
      if (gen === this.pushReviewGeneration) this.pushReviewLoading = false;
      this.emit();
    }
  }
}
