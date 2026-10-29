import { ExternalLink, FileText, RefreshCw } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { CIAPI, CIStatusIcon, isActiveCI, statusInfo, type CIJob, type CIPipeline, type CIRequestCheck } from "@/entities/ci";
import { accounts, hubError, workspaceJobLog } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, IconButton, Spinner } from "@/shared/ui";
import { useObserve } from "@/shared/lib";

/** The selected request's commit checks, workflow jobs and redacted logs. */
export function RequestChecksPanel({ store, number, sha, url }: { store: RepoStore; number: number; sha: string | null; url: string }) {
  useObserve(accounts);
  const [refresh, setRefresh] = useState(0), [loading, setLoading] = useState(false), [error, setError] = useState("");
  const [checks, setChecks] = useState<CIRequestCheck[]>([]), [runs, setRuns] = useState<CIPipeline[]>([]), [truncated, setTruncated] = useState(false);
  const [jobs, setJobs] = useState(new Map<number, CIJob[]>()), [jobLoading, setJobLoading] = useState<number | null>(null);
  const [log, setLog] = useState<{ job: CIJob; body: string; truncated: boolean } | null>(null), [logLoading, setLogLoading] = useState<number | null>(null);
  const generation = useRef(0);
  const target = store.target, account = store.hostingAccount;
  const key = `${store.path}:${target?.provider}:${target?.host}:${target?.path}:${account?.id}:${accounts.revision}:${number}:${sha}`;
  useEffect(() => {
    generation.current++;
    setChecks([]); setRuns([]); setJobs(new Map()); setLog(null); setJobLoading(null); setLogLoading(null); setLoading(false); setError(""); setTruncated(false);
    return () => { generation.current++; };
  }, [key]);
  useEffect(() => {
    let stopped = false, timer: ReturnType<typeof setTimeout> | undefined;
    if (!sha) return;
    const load = async () => {
      setLoading(true); setError("");
      let token: string | undefined;
      try {
        const access = await store.ci.access();
        if (!access) throw new Error(t("Connect an account to see the conversation and approvals."));
        token = access.token;
        const [checkResult, runResult] = await Promise.allSettled([CIAPI.requestChecks(access, sha), CIAPI.requestPipelines(access, number, sha)]);
        if (stopped) return;
        const errors: string[] = [];
        if (checkResult.status === "fulfilled") { setChecks(checkResult.value.checks); setTruncated(checkResult.value.truncated); } else errors.push(hubError(checkResult.reason, token));
        if (runResult.status === "fulfilled") setRuns(runResult.value); else errors.push(hubError(runResult.reason, token));
        if (runResult.status === "fulfilled") {
          const expanded = await Promise.allSettled(runResult.value.filter(run => jobs.has(run.id)).map(async run => ({ id: run.id, jobs: await CIAPI.jobs(access, run.id, run.projectID) })));
          if (stopped) return;
          setJobs(values => {
            const next = new Map(values);
            for (const result of expanded) if (result.status === "fulfilled") next.set(result.value.id, result.value.jobs);
            return next;
          });
          for (const result of expanded) if (result.status === "rejected") errors.push(hubError(result.reason, token));
        }
        setError(errors.join("\n"));
        const active = checkResult.status === "fulfilled" && checkResult.value.checks.some(c => isActiveCI(c.status)) || runResult.status === "fulfilled" && runResult.value.some(r => isActiveCI(r.status));
        if (active) timer = setTimeout(() => setRefresh(value => value + 1), 20_000);
      } catch (e) { if (!stopped) setError(hubError(e, token)); }
      finally { if (!stopped) setLoading(false); }
    };
    void load();
    return () => { stopped = true; if (timer) clearTimeout(timer); };
  }, [store, key, sha, refresh]);
  const loadJobs = async (run: CIPipeline) => {
    const id = generation.current;
    setJobLoading(run.id); setError("");
    let token: string | undefined;
    try {
      const access = await store.ci.access();
      if (!access || generation.current !== id) return;
      token = access.token;
      const result = await CIAPI.jobs(access, run.id, run.projectID);
      if (generation.current === id) setJobs(values => new Map(values).set(run.id, result));
    } catch (e) { if (generation.current === id) setError(hubError(e, token)); }
    finally { if (generation.current === id) setJobLoading(null); }
  };
  const loadLog = async (job: CIJob, run: CIPipeline) => {
    const id = generation.current;
    setLogLoading(job.id); setLog(null); setError("");
    let token: string | undefined;
    try {
      const access = await store.ci.access();
      if (!access || !account || generation.current !== id) return;
      token = access.token;
      const result = await workspaceJobLog({ ...access, target: run.projectID ? { ...access.target, path: String(run.projectID) } : access.target, me: account.username, stillCurrent: () => generation.current === id }, job.id);
      if (generation.current === id) setLog({ job, ...result });
    } catch (e) { if (generation.current === id) setError(hubError(e, token)); }
    finally { if (generation.current === id) setLogLoading(null); }
  };
  const open = (address: string) => {
    try { const value = new URL(address); if (["https:", "http:"].includes(value.protocol) && !value.username && !value.password) store.openUrl(value.href); } catch { /* No browser action for an absent result URL. */ }
  };
  return <section className="request-checks">
    <header className="request-section-head"><strong>{t("Checks and CI")}</strong>{loading && <Spinner size={12}/>}<span className="spacer"/><IconButton small disabled={loading} icon={<RefreshCw size={12}/>} tip={t("Refresh checks")} onClick={() => setRefresh(value => value + 1)}/><Button size="small" onClick={() => open(`${url}${target?.provider === "github" ? "/checks" : "/pipelines"}`)}>{t("All results")}<ExternalLink size={12}/></Button></header>
    {sha && <code className="request-check-sha">{sha.slice(0, 12)}</code>}
    {error && <p className="error-text" role="alert">{error}</p>}
    {!sha && <p className="muted">{t("Checks are unavailable until the request's commit is known.")}</p>}
    {!loading && sha && !checks.length && !runs.length && !error && <p className="muted">{t("No checks reported")}</p>}
    {checks.map(check => <div className="request-check-row" key={check.id}><CIStatusIcon status={check.status} size={15}/><div className="grow"><strong>{check.name}</strong>{check.summary && <span>{check.summary}</span>}</div><span className="request-check-status" style={{ color: statusInfo[check.status].color }}>{statusInfo[check.status].title}</span>{check.url && <IconButton small icon={<ExternalLink size={13}/>} tip={t("Open result")} onClick={() => open(check.url)}/>}</div>)}
    {(truncated || runs.length === 30) && <p className="muted">{t("More results are available in the browser.")}</p>}
    {runs.map(run => <details className="request-run" key={run.id} onToggle={event => { if (event.currentTarget.open && !jobs.has(run.id) && jobLoading === null) void loadJobs(run); }}><summary><CIStatusIcon status={run.status} size={14}/><strong className="grow">{run.name || t("Pipeline")} #{run.number}</strong><span className="request-check-status">{statusInfo[run.status].title}</span></summary><div className="request-run-jobs"><div className="row"><Button size="small" onClick={() => open(run.url)}>{t("Open run")}<ExternalLink size={12}/></Button>{jobLoading === run.id && <Spinner size={12}/>}<span className="spacer"/><Button size="small" disabled={jobLoading !== null} onClick={() => void loadJobs(run)}>{t("Refresh jobs")}</Button></div>{jobs.get(run.id)?.map(job => <div className="request-check-row" key={job.id}><CIStatusIcon status={job.status} size={13}/><div className="grow"><strong>{job.name}</strong>{job.stage && <span>{job.stage}</span>}</div><span className="request-check-status" style={{ color: statusInfo[job.status].color }}>{statusInfo[job.status].title}</span><IconButton small disabled={logLoading !== null} icon={logLoading === job.id ? <Spinner size={12}/> : <FileText size={13}/>} tip={t("Load log")} onClick={() => void loadLog(job, run)}/>{job.url && <IconButton small icon={<ExternalLink size={13}/>} tip={t("Open result")} onClick={() => open(job.url)}/>}</div>)}{jobs.has(run.id) && !jobs.get(run.id)?.length && <p className="muted">{t("No jobs reported")}</p>}</div></details>)}
    {log && <div className="request-job-log"><div className="row"><strong className="grow">{log.job.name} · {t("Job log")}</strong><Button size="small" onClick={() => store.copy(log.body)}>{t("Copy redacted log")}</Button><Button size="small" onClick={() => setLog(null)}>{t("Close")}</Button></div>{log.truncated && <p className="muted">{t("Log preview is limited to 2 MB. Open the browser for the complete log.")}</p>}<pre className="selectable mono">{log.body || t("No content to show.")}</pre></div>}
  </section>;
}
