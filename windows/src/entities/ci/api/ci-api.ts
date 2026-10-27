import type { RepoTarget } from "@/entities/git";
import * as Hosting from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { dispatchInputs } from "../lib/yaml";
import { type CIDeployment, type CIJob, type CIPipeline, type CIRequestCheck, type CIWorkflow, githubStatus, gitlabStatus } from "../model/types";

interface GLPipeline { id: number; project_id?: number; iid?: number; sha: string; ref: string; status: string; source?: string; created_at?: string; web_url: string; name?: string | null; user?: { username: string } | null }
interface GLJob { id: number; name: string; stage: string; status: string; web_url: string; allow_failure?: boolean; duration?: number | null }
interface GHRun {
  id: number; name?: string | null; display_title?: string | null; run_number: number; head_branch?: string | null; head_sha: string;
  status?: string | null; conclusion?: string | null; html_url: string; created_at?: string; event: string; actor?: { login: string } | null;
}
interface GHJob { id: number; name: string; status?: string | null; conclusion?: string | null; html_url?: string | null; started_at?: string | null; completed_at?: string | null }
interface GHWorkflow { id: number; name: string; path: string; state: string }
interface GHPending { environment: { id: number; name?: string | null }; current_user_can_approve?: boolean }

export interface CIAccess {
  target: RepoTarget;
  token: string;
  apiBase: string;
}

const project = (c: CIAccess) => `${c.apiBase}/projects/${Hosting.projectID(c.target.path)}`;
const repoBase = (c: CIAccess) => `${c.apiBase}/repos/${c.target.path}`;
const q = encodeURIComponent;
const glPipeline = (p: GLPipeline): CIPipeline => ({ id: p.id, projectID: p.project_id, number: p.iid ?? p.id, name: p.name ?? "", title: "", ref: p.ref, sha: p.sha, status: gitlabStatus(p.status), url: p.web_url, created: Hosting.date(p.created_at), event: p.source ?? "", actor: p.user?.username ?? null });

/** base64(줄바꿈 포함) → UTF-8 글 */
function decodeBase64(b64: string): string {
  const bin = atob(b64.replace(/\s/g, ""));
  return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}

export const CIAPI = {
  /** 최근 파이프라인·실행(ref 가 있으면 그 브랜치만) */
  async pipelines(c: CIAccess, ref: string | null, sha?: string): Promise<CIPipeline[]> {
    if (c.target.provider === "gitlab") {
      const list = await Hosting.send<GLPipeline[]>("gitlab", `${project(c)}/pipelines?per_page=30${ref ? `&ref=${q(ref)}` : ""}${sha ? `&sha=${q(sha)}` : ""}`, c.token);
      return list.map(glPipeline);
    }
    const r = await Hosting.send<{ workflow_runs: GHRun[] }>("github", `${repoBase(c)}/actions/runs?per_page=30${ref ? `&branch=${q(ref)}` : ""}${sha ? `&head_sha=${q(sha)}` : ""}`, c.token);
    return r.workflow_runs.map((p) => ({
      id: p.id,
      number: p.run_number,
      name: p.name ?? "",
      title: p.display_title ?? "",
      ref: p.head_branch ?? "",
      sha: p.head_sha,
      status: githubStatus(p.status, p.conclusion),
      url: p.html_url,
      created: Hosting.date(p.created_at),
      event: p.event,
      actor: p.actor?.login ?? null,
    }));
  },

  /** Merged-result pipelines can have a different SHA from the request's source commit. */
  async requestPipelines(c: CIAccess, number: number, sha: string): Promise<CIPipeline[]> {
    if (c.target.provider === "github") return CIAPI.pipelines(c, null, sha);
    const [list, request] = await Promise.all([
      CIAPI.pipelines(c, null, sha),
      Hosting.send<{ head_pipeline?: GLPipeline | null }>("gitlab", `${project(c)}/merge_requests/${number}`, c.token),
    ]);
    const head = request.head_pipeline ? glPipeline(request.head_pipeline) : null;
    return head ? [head, ...list.filter(run => run.id !== head.id)] : list;
  },

  /** Include third-party checks and commit statuses, independently of Actions runs. */
  async requestChecks(c: CIAccess, sha: string): Promise<{ checks: CIRequestCheck[]; truncated: boolean }> {
    if (c.target.provider === "gitlab") {
      const statuses = await Hosting.send<{ id: number; name: string; status: string; target_url?: string; description?: string }[]>("gitlab", `${project(c)}/repository/commits/${q(sha)}/statuses?per_page=100`, c.token);
      return { checks: statuses.map(s => ({ id: `status:${s.id}`, name: s.name, status: gitlabStatus(s.status), url: s.target_url ?? "", summary: s.description ?? "" })), truncated: statuses.length === 100 };
    }
    const [runs, statuses] = await Promise.all([
      Hosting.send<{ total_count: number; check_runs: { id: number; name: string; status: string; conclusion?: string | null; html_url?: string; details_url?: string; output?: { title?: string; summary?: string } }[] }>("github", `${repoBase(c)}/commits/${q(sha)}/check-runs?filter=latest&per_page=100`, c.token),
      Hosting.send<{ total_count: number; statuses: { id: number; context: string; state: string; target_url?: string; description?: string }[] }>("github", `${repoBase(c)}/commits/${q(sha)}/status?per_page=100`, c.token),
    ]);
    const checks: CIRequestCheck[] = runs.check_runs.map(r => ({ id: `check:${r.id}`, name: r.name, status: githubStatus(r.status, r.conclusion), url: r.details_url || r.html_url || "", summary: r.output?.title ?? "" }));
    checks.push(...statuses.statuses.map(s => ({ id: `status:${s.id}`, name: s.context, status: s.state === "success" ? "success" as const : s.state === "pending" ? "pending" as const : s.state === "failure" || s.state === "error" ? "failed" as const : "unknown" as const, url: s.target_url ?? "", summary: s.description ?? "" })));
    return { checks, truncated: runs.total_count > runs.check_runs.length || statuses.total_count > statuses.statuses.length };
  },

  async jobs(c: CIAccess, pipeline: number, projectID?: number): Promise<CIJob[]> {
    if (c.target.provider === "gitlab") {
      const base = projectID ? `${c.apiBase}/projects/${projectID}` : project(c);
      const list = await Hosting.send<GLJob[]>("gitlab", `${base}/pipelines/${pipeline}/jobs?per_page=100`, c.token);
      // 단계 순서 = 먼저 만들어진 작업 순서
      return list
        .sort((a, b) => a.id - b.id)
        .map((j) => ({ id: j.id, name: j.name, stage: j.stage, status: gitlabStatus(j.status), url: j.web_url, allowFailure: !!j.allow_failure, duration: j.duration ?? null }));
    }
    const r = await Hosting.send<{ jobs: GHJob[] }>("github", `${repoBase(c)}/actions/runs/${pipeline}/jobs?per_page=100&filter=latest`, c.token);
    return r.jobs.map((j) => {
      const s = Hosting.date(j.started_at);
      const e = Hosting.date(j.completed_at);
      return { id: j.id, name: j.name, stage: "", status: githubStatus(j.status, j.conclusion), url: j.html_url ?? "", allowFailure: false, duration: s != null && e != null ? e - s : null };
    });
  },

  play: (c: CIAccess, job: number) => Hosting.sendRaw("gitlab", `${project(c)}/jobs/${job}/play`, c.token, "POST"),

  retryJob: (c: CIAccess, job: number) =>
    c.target.provider === "gitlab"
      ? Hosting.sendRaw("gitlab", `${project(c)}/jobs/${job}/retry`, c.token, "POST")
      : Hosting.sendRaw("github", `${repoBase(c)}/actions/jobs/${job}/rerun`, c.token, "POST"),

  cancelJob: (c: CIAccess, job: number) => Hosting.sendRaw("gitlab", `${project(c)}/jobs/${job}/cancel`, c.token, "POST"),

  /** GitLab 은 실패·취소된 작업만 다시 실행한다 */
  retryPipeline: (c: CIAccess, id: number, failedOnly: boolean) =>
    c.target.provider === "gitlab"
      ? Hosting.sendRaw("gitlab", `${project(c)}/pipelines/${id}/retry`, c.token, "POST")
      : Hosting.sendRaw("github", `${repoBase(c)}/actions/runs/${id}/${failedOnly ? "rerun-failed-jobs" : "rerun"}`, c.token, "POST"),

  cancelPipeline: (c: CIAccess, id: number) =>
    c.target.provider === "gitlab"
      ? Hosting.sendRaw("gitlab", `${project(c)}/pipelines/${id}/cancel`, c.token, "POST")
      : Hosting.sendRaw("github", `${repoBase(c)}/actions/runs/${id}/cancel`, c.token, "POST"),

  /** GitLab: 브랜치·변수로 새 파이프라인 */
  runPipeline: (c: CIAccess, ref: string, variables: [string, string][]) =>
    Hosting.sendRaw("gitlab", `${project(c)}/pipeline`, c.token, "POST", {
      ref,
      variables: variables.map(([key, value]) => ({ key, value, variable_type: "env_var" })),
    }),

  /** GitHub: workflow_dispatch 가 있는 워크플로(입력값 포함). 파일은 ref 의 것을 읽는다. */
  async workflows(c: CIAccess, ref: string): Promise<CIWorkflow[]> {
    const r = await Hosting.send<{ workflows: GHWorkflow[] }>("github", `${repoBase(c)}/actions/workflows?per_page=100`, c.token);
    const list = r.workflows.filter((w) => w.state === "active" && w.path.startsWith(".github/workflows/"));
    const out = await Promise.all(
      list.map(async (w): Promise<CIWorkflow | null> => {
        try {
          const file = await Hosting.send<{ content?: string }>("github", `${repoBase(c)}/contents/${w.path}?ref=${q(ref)}`, c.token);
          const inputs = file.content ? dispatchInputs(decodeBase64(file.content)) : null;
          return inputs ? { id: w.id, name: w.name, path: w.path, inputs } : null;
        } catch {
          return null;
        }
      }),
    );
    return out.filter((w): w is CIWorkflow => !!w);
  },

  dispatch: (c: CIAccess, workflow: number, ref: string, inputs: Record<string, string>) =>
    Hosting.sendRaw("github", `${repoBase(c)}/actions/workflows/${workflow}/dispatches`, c.token, "POST", { ref, inputs }),

  async pendingDeployments(c: CIAccess, run: number): Promise<CIDeployment[]> {
    const list = await Hosting.send<GHPending[]>("github", `${repoBase(c)}/actions/runs/${run}/pending_deployments`, c.token);
    return list.map((p) => ({ environmentID: p.environment.id, environment: p.environment.name ?? t("Environment {0}", p.environment.id), canApprove: !!p.current_user_can_approve }));
  },

  review: (c: CIAccess, run: number, environments: number[], approve: boolean) =>
    Hosting.sendRaw("github", `${repoBase(c)}/actions/runs/${run}/pending_deployments`, c.token, "POST", {
      environment_ids: environments,
      state: approve ? "approved" : "rejected",
      comment: "Gitrochi",
    }),
};

// MARK: - 상태
