import { ChevronDown, ChevronRight, CircleCheck, Ellipsis, ExternalLink, RefreshCw, RotateCw } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { CIAPI, CIStatusIcon, isActiveCI, statusInfo, type CIJob, type CIPipeline, type CIRequestCheck } from "@/entities/ci";
import { accounts, hubError, workspaceJobLog } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, IconButton, showMenuBelow, Spinner } from "@/shared/ui";
import { useObserve } from "@/shared/lib";
import { checkGroups, checkJob, checksBadge, firstError, logLines, logWindow } from "../lib/pull-request-page";

type Badge = ReturnType<typeof checksBadge>;
interface Log { body: string; truncated: boolean }

/**
 * The selected request's checks: what failed, open with its log; what still runs; and what passed, folded into one
 * line. The workflow runs and their jobs follow. macOS: RequestChecksPanel.swift.
 */
export function RequestChecksPanel({ store, number, sha, url, draft = false, active = true, onBadge }: {
  store: RepoStore; number: number; sha: string | null; url: string;
  draft?: boolean;
  /** the Checks tab is showing: the first failed job's log is read only then */
  active?: boolean;
  /** what the Checks tab counts */
  onBadge?: (badge: Badge) => void;
}) {
  useObserve(accounts);
  const [refresh, setRefresh] = useState(0), [loading, setLoading] = useState(false), [error, setError] = useState("");
  const [checks, setChecks] = useState<CIRequestCheck[]>([]), [runs, setRuns] = useState<CIPipeline[]>([]), [truncated, setTruncated] = useState(false);
  const [jobs, setJobs] = useState(new Map<number, CIJob[]>()), [jobLoading, setJobLoading] = useState<number | null>(null);
  const [logs, setLogs] = useState(new Map<number, Log>()), [logLoading, setLogLoading] = useState<number | null>(null);
  const [passedOpen, setPassedOpen] = useState(false), [failedOpen, setFailedOpen] = useState(true);
  const generation = useRef(0), autoLoaded = useRef<number | null>(null);
  const target = store.target, account = store.hostingAccount;
  const key = `${store.path}:${target?.provider}:${target?.host}:${target?.path}:${account?.id}:${accounts.revision}:${number}:${sha}`;
  useEffect(() => {
    generation.current++; autoLoaded.current = null;
    setChecks([]); setRuns([]); setJobs(new Map()); setLogs(new Map()); setJobLoading(null); setLogLoading(null); setLoading(false); setError(""); setTruncated(false); setPassedOpen(false); setFailedOpen(true);
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
  const loadLog = async (job: number, projectID?: number) => {
    const id = generation.current;
    setLogLoading(job); setError("");
    let token: string | undefined;
    try {
      const access = await store.ci.access();
      if (!access || !account || generation.current !== id) return;
      token = access.token;
      const result = await workspaceJobLog({ ...access, target: projectID ? { ...access.target, path: String(projectID) } : access.target, me: account.username, stillCurrent: () => generation.current === id }, job);
      if (generation.current === id) setLogs(values => new Map(values).set(job, result));
    } catch (e) { if (generation.current === id) setError(hubError(e, token)); }
    finally { if (generation.current === id) setLogLoading(null); }
  };
  const closeLog = (job: number) => setLogs(values => { const next = new Map(values); next.delete(job); return next; });
  const open = (address: string) => {
    try { const value = new URL(address); if (["https:", "http:"].includes(value.protocol) && !value.username && !value.password) store.openUrl(value.href); } catch { /* No browser action for an absent result URL. */ }
  };
  const groups = useMemo(() => checkGroups(checks), [checks]);
  const badge = useMemo(() => checksBadge(checks), [checks]);
  useEffect(() => { onBadge?.(badge); }, [badge?.kind, badge?.count]);
  /** The run a check's job belongs to: named in a GitHub address, else the one whose loaded jobs hold it */
  const runOf = (job: { run: number | null; job: number }) => runs.find(run => run.id === job.run) ?? runs.find(run => jobs.get(run.id)?.some(item => item.id === job.job));
  // The failed check opens with its log; only the first one is read without being asked
  const firstFailedJob = groups.failed.map(check => checkJob(check.url)).find(job => job) ?? null;
  useEffect(() => {
    if (!active || !firstFailedJob || autoLoaded.current === firstFailedJob.job || logs.has(firstFailedJob.job)) return;
    autoLoaded.current = firstFailedJob.job;
    void loadLog(firstFailedJob.job, runOf(firstFailedJob)?.projectID);
  }, [active, firstFailedJob?.job]);
  const rerun = (check: CIRequestCheck, job: { run: number | null; job: number }, run: CIPipeline) => {
    void store.ci.retryJob({ id: job.job, name: check.name, stage: "", status: check.status, url: check.url, allowFailure: false, duration: null }, run).then(() => setRefresh(value => value + 1));
  };
  const checkRow = (check: CIRequestCheck) => {
    const job = checkJob(check.url), log = job ? logs.get(job.job) : undefined;
    return <div className="pr-check-item" key={check.id}>
      <div className="pr-check-row request-check-row">
        <CIStatusIcon status={check.status} size={14}/><span className="pr-check-name mono">{check.name}</span>
        <span className="pr-cap">{statusInfo[check.status].title}{check.summary ? ` · ${check.summary}` : ""}</span><span className="spacer"/>
        {job && !log && <button type="button" className="pr-text-button" disabled={logLoading !== null} onClick={() => void loadLog(job.job, runOf(job)?.projectID)}>{logLoading === job.job ? <Spinner size={11}/> : null}{t("Load log")}</button>}
        {check.url && <IconButton small icon={<ExternalLink size={13}/>} tip={t("Open result")} aria-label={t("Open result")} onClick={() => open(check.url)}/>}
      </div>
      {job && log && <JobLog name={check.name} log={log} onCopy={() => store.copy(log.body)} onClose={() => closeLog(job.job)}/>}
    </div>;
  };
  return <section className="request-checks pr-checks">
    <header className="pr-checks-head">
      <div className="pr-checks-title">
        <h3>{t("Checks")}</h3>
        <span className="pr-cap">{runs[0] && <button type="button" className="pr-link" onClick={() => open(runs[0].url)}>{t("Run #{0}", runs[0].number)}</button>}{runs[0] && sha ? " · " : ""}{sha && <code className="mono selectable request-check-sha">{sha.slice(0, 7)}</code>}</span>
        {loading && <Spinner size={12}/>}<span className="spacer"/>
        <IconButton small disabled={loading} icon={<RefreshCw size={13}/>} tip={t("Refresh checks")} aria-label={t("Refresh checks")} onClick={() => setRefresh(value => value + 1)}/>
        <Button onClick={() => open(`${url}${target?.provider === "github" ? "/checks" : "/pipelines"}`)}>{t("All results")}<ExternalLink size={13}/></Button>
      </div>
      {draft && <span className="pr-cap">{t("Draft requests cannot be merged.")}</span>}
    </header>
    {error && <p className="error-text selectable" role="alert">{error}</p>}
    {!sha && <p className="pr-cap">{t("Checks are unavailable until the request's commit is known.")}</p>}
    {!loading && sha && !checks.length && !runs.length && !error && <p className="pr-cap">{t("No checks reported")}</p>}
    {groups.failed.length > 0 && <section className="pr-check-group" aria-label={t("Failed")}>
      <button type="button" className="pr-group" aria-expanded={failedOpen} onClick={() => setFailedOpen(!failedOpen)}>{failedOpen ? <ChevronDown size={12}/> : <ChevronRight size={12}/>}{t("Failed")}</button>
      {failedOpen && groups.failed.map(check => {
        const job = checkJob(check.url), log = job ? logs.get(job.job) : undefined, run = job ? runOf(job) : undefined;
        return <FailedCheck key={check.id} check={check} log={log} loading={!!job && logLoading === job.job}
          onOpen={check.url ? () => open(check.url) : undefined}
          onLoad={job ? () => void loadLog(job.job, run?.projectID) : undefined}
          onRerun={job && run ? () => rerun(check, job, run) : undefined}
          onCopy={log ? () => store.copy(log.body) : undefined}/>;
      })}
    </section>}
    {groups.running.length > 0 && <section className="pr-check-group" aria-label={t("Running")}>
      <span className="pr-group">{t("Running")}</span>
      <div className="pr-check-list">{groups.running.map(checkRow)}</div>
    </section>}
    {groups.passed.length > 0 && <section className="pr-check-group" aria-label={t("Passed")}>
      <button type="button" className="pr-group" aria-expanded={passedOpen} onClick={() => setPassedOpen(!passedOpen)}>
        {passedOpen ? <ChevronDown size={12}/> : <ChevronRight size={12}/>}<span>{t("Passed")} {groups.passed.length}</span>
        {!passedOpen && <><CircleCheck size={12} className="pr-passed-icon" aria-hidden="true"/><span className="pr-group-names mono ellipsis">{groups.passed.map(check => check.name).join(" · ")}</span></>}
      </button>
      {passedOpen && <div className="pr-check-list">{groups.passed.map(checkRow)}</div>}
    </section>}
    {(truncated || runs.length === 30) && <p className="pr-cap">{t("More results are available in the browser.")}</p>}
    {runs.map(run => <details className="request-run pr-run" key={run.id} onToggle={event => { if (event.currentTarget.open && !jobs.has(run.id) && jobLoading === null) void loadJobs(run); }}>
      <summary><CIStatusIcon status={run.status} size={14}/><strong className="grow">{run.name || t("Pipeline")} · {t("Run #{0}", run.number)}</strong><span className="pr-cap">{statusInfo[run.status].title}</span></summary>
      <div className="request-run-jobs">
        <div className="row"><Button size="small" onClick={() => open(run.url)}>{t("Open run")}<ExternalLink size={12}/></Button>{jobLoading === run.id && <Spinner size={12}/>}<span className="spacer"/><Button size="small" disabled={jobLoading !== null} onClick={() => void loadJobs(run)}>{t("Refresh jobs")}</Button></div>
        {jobs.get(run.id)?.map(job => {
          const log = logs.get(job.id);
          return <div className="pr-check-item" key={job.id}>
            <div className="pr-check-row request-check-row">
              <CIStatusIcon status={job.status} size={13}/><span className="pr-check-name mono">{job.name}</span>
              <span className="pr-cap">{statusInfo[job.status].title}{job.stage ? ` · ${job.stage}` : ""}</span><span className="spacer"/>
              <button type="button" className="pr-text-button" disabled={logLoading !== null} onClick={() => void loadLog(job.id, run.projectID)}>{logLoading === job.id ? <Spinner size={11}/> : null}{t(log ? "Refresh log" : "Load log")}</button>
              {job.url && <IconButton small icon={<ExternalLink size={13}/>} tip={t("Open result")} aria-label={t("Open result")} onClick={() => open(job.url)}/>}
            </div>
            {log && <JobLog name={job.name} log={log} onCopy={() => store.copy(log.body)} onClose={() => closeLog(job.id)}/>}
          </div>;
        })}
        {jobs.has(run.id) && !jobs.get(run.id)?.length && <p className="pr-cap">{t("No jobs reported")}</p>}
      </div>
    </details>)}
  </section>;
}

/** A failed check: what failed and why, the ways to act on it, and its log right below */
function FailedCheck({ check, log, loading, onOpen, onLoad, onRerun, onCopy }: { check: CIRequestCheck; log?: Log; loading: boolean; onOpen?: () => void; onLoad?: () => void; onRerun?: () => void; onCopy?: () => void }) {
  const lines = useMemo(() => (log ? logLines(log.body) : []), [log]);
  const [jump, setJump] = useState(0);
  const error = firstError(lines);
  return <div className="pr-check-card">
    <div className="pr-check-top">
      <div className="pr-check-line">
        <CIStatusIcon status={check.status} size={14}/>
        <span className="pr-check-name mono">{check.name}</span>
        <span className="pr-check-status status-tone" data-tone="failed">{statusInfo[check.status].title}</span>
        <span className="spacer"/>
        <span className="pr-check-actions">
          {loading && <Spinner size={12}/>}
          {log && error != null && <Button onClick={() => setJump(value => value + 1)}>{t("Jump to first error")}</Button>}
          {!log && onLoad && <Button disabled={loading} onClick={onLoad}>{t("Load log")}</Button>}
          {onRerun && <Button onClick={onRerun}><RotateCw size={14}/>{t("Re-run job")}</Button>}
          {onOpen && <Button className="pr-button-icon" tip={t("Open result")} aria-label={t("Open result")} onClick={onOpen}><ExternalLink size={13}/></Button>}
          {onLoad && <Button className="pr-button-icon" tip={t("More job actions")} aria-label={t("More job actions")} aria-haspopup="menu" onClick={(event) => showMenuBelow(event.currentTarget, [
            { label: t("Copy log"), disabled: !onCopy, onClick: onCopy },
            { label: t("Refresh log"), disabled: loading, onClick: onLoad },
          ])}><Ellipsis size={14}/></Button>}
        </span>
      </div>
      {check.summary && <span className="pr-cap pr-check-summary">{check.summary}</span>}
    </div>
    {log && <LogRegion name={check.name} lines={lines} truncated={log.truncated} jump={jump} target={error}/>}
  </div>;
}

/** Any other job's log, with the two things to do with it */
function JobLog({ name, log, onCopy, onClose }: { name: string; log: Log; onCopy: () => void; onClose: () => void }) {
  const lines = useMemo(() => logLines(log.body), [log]);
  return <div className="pr-job-log">
    <div className="pr-text-actions"><button type="button" className="pr-text-button" onClick={onCopy}>{t("Copy log")}</button><button type="button" className="pr-text-button" onClick={onClose}>{t("Close")}</button></div>
    <LogRegion name={name} lines={lines} truncated={log.truncated}/>
  </div>;
}

/** Numbered log lines; the ones that report a failure wrap and stand out, and a long log starts at its tail */
function LogRegion({ name, lines, truncated, jump = 0, target = null }: { name: string; lines: ReturnType<typeof logLines>; truncated: boolean; jump?: number; target?: number | null }) {
  const [all, setAll] = useState(false);
  const region = useRef<HTMLDivElement>(null);
  const { shown, earlier } = logWindow(lines, all);
  useEffect(() => {
    if (!jump || target == null) return;
    // the first error may sit in the folded earlier lines
    if (!all && earlier > 0 && target <= earlier) { setAll(true); return; }
    region.current?.querySelector(`[data-line="${target}"]`)?.scrollIntoView({ block: "center" });
  }, [jump, all]);
  // a failed job's log opens on its first error; only the log scrolls, never the page around it
  useEffect(() => {
    const box = region.current, line = target == null ? null : box?.querySelector<HTMLElement>(`[data-line="${target}"]`);
    if (box && line) box.scrollTop = Math.max(0, line.offsetTop - box.offsetTop - box.clientHeight / 2);
  }, [lines]);
  return <div className="pr-log request-job-log selectable" role="region" aria-label={`${name} · ${t("Job log")}`} tabIndex={0} ref={region}>
    {truncated && <p className="pr-cap pr-log-note">{t("Log preview is limited to 2 MB. Open the browser for the complete log.")}</p>}
    {earlier > 0 && <button type="button" className="pr-text-button pr-log-earlier" onClick={() => setAll(true)}>{t("Show {0} earlier lines", earlier)}</button>}
    {lines.length === 1 && !lines[0].text ? <p className="pr-cap pr-log-note">{t("No content to show.")}</p>
      : shown.map(line => <div className={`pr-log-line mono ${line.isError ? "error status-tone" : ""}`} data-tone={line.isError ? "failed" : undefined} data-line={line.n} key={line.n}><span className="pr-log-n">{line.n}</span><span className="pr-log-text">{line.text}</span></div>)}
  </div>;
}
