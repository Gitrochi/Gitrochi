import { useEffect, useState } from "react";
import {
  canSchedule, type CIInput, type CIJob, CIStatusIcon, type CIStatus, type CIWorkflow, type CommitRun, commitWorkflowRuns, dateTimeInputValue, defaultCommitJob,
  filterRunCommits, nextFullHour, parseDateTimeInput, type RunCommit, scheduledRuns, statusInfo,
} from "@/entities/ci";
import type { Provider } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { listWhen } from "@/shared/lib";
import { describe } from "@/shared/platform";
import { ArrowUp, Search } from "@/shared/icons";
import { Checkbox, IconButton, Segmented, SharedSheet } from "@/shared/ui";
import "./run-pipeline.css";

interface Variable {
  id: number;
  key: string;
  value: string;
  description: string;
  options: string[];
  /** .gitlab-ci.yml 에서 온 변수(이름 고정) */
  fixed: boolean;
}

let nextVarID = 1;

/**
 * GitLab: 브랜치·변수로 새 파이프라인 / GitHub: workflow_dispatch 워크플로를 브랜치·입력값으로 실행.
 * With a commit of the branch chosen, that commit's own run starts again: a GitLab job is pressed, a GitHub run re-run.
 */
export function RunPipelineSheet({ store, close }: { store: RepoStore; close: () => void }) {
  const ci = store.ci;
  const provider: Provider = store.target?.provider ?? "gitlab";
  const branches = ci.branches;
  const [ref, setRef] = useState(() => branches[0] ?? ci.currentRef ?? "");
  // the branch's commits with runs on it; null runs on the branch's tip as it is when the run starts
  const [commits, setCommits] = useState<RunCommit[]>([]);
  const [sha, setSha] = useState<string | null>(null);
  // narrows the commits by message or SHA
  const [query, setQuery] = useState("");
  // GitLab: the chosen commit's pipeline jobs, manual ones first, and the one to press
  const [jobs, setJobs] = useState<CIJob[]>([]);
  const [jobName, setJobName] = useState<string | null>(null);
  // GitHub: the chosen commit's workflow run to re-run
  const [runID, setRunID] = useState<number | null>(null);
  const commit = sha ? (commits.find((c) => c.sha === sha) ?? null) : null;
  const [variables, setVariables] = useState<Variable[]>([]);
  const [workflows, setWorkflows] = useState<CIWorkflow[]>([]);
  const [workflowID, setWorkflowID] = useState<number | null>(null);
  const [values, setValues] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  // Run later: the app keeps the run and starts it itself at this local date and time
  const [later, setLater] = useState(false);
  const [runAt, setRunAt] = useState(() => dateTimeInputValue(nextFullHour(scheduledRuns.now())));
  // the time is checked again when the primary is pressed: it may have passed while the sheet was open
  const [checkedAt, setCheckedAt] = useState(() => scheduledRuns.now());
  const workflow = workflows.find((w) => w.id === workflowID) ?? null;
  const timeOK = canSchedule(parseDateTimeInput(runAt), Math.max(checkedAt, scheduledRuns.now()));

  useEffect(() => {
    if (provider !== "gitlab") return;
    void ci.gitlabVariables().then((list) =>
      setVariables(list.map((v) => ({ id: nextVarID++, key: v.name, value: v.defaultValue, description: v.description, options: v.options, fixed: true }))),
    );
  }, [ci, provider]);

  const pick = (list: CIWorkflow[], id: number | null, prev: Record<string, string>) => {
    setWorkflowID(id);
    const v: Record<string, string> = {};
    for (const i of list.find((w) => w.id === id)?.inputs ?? []) {
      v[i.name] = prev[i.name] ?? (!i.defaultValue && i.type === "choice" ? (i.options[0] ?? "") : i.defaultValue);
      if (i.type === "boolean" && v[i.name] !== "true") v[i.name] = "false";
    }
    setValues(v);
  };

  useEffect(() => {
    if (provider !== "github" || !ref) return;
    let cancelled = false;
    setLoading(true);
    ci.workflows(ref)
      .then((list) => {
        if (cancelled) return;
        setLoadError(null);
        setWorkflows(list);
        pick(list, list.find((w) => w.id === workflowID)?.id ?? list[0]?.id ?? null, values);
      })
      .catch((e) => {
        if (cancelled) return;
        setLoadError(describe(e));
        setWorkflows([]);
      })
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
    // 브랜치가 바뀔 때만 다시 읽는다
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ci, provider, ref]);

  useEffect(() => {
    let cancelled = false;
    setSha(null);
    setCommits([]);
    void ci.commits(ref.trim()).then((list) => { if (!cancelled) setCommits(list); }, () => {});
    return () => {
      cancelled = true;
    };
  }, [ci, ref]);

  // a chosen commit starts on its first manual job (GitLab) or its newest workflow run (GitHub)
  useEffect(() => {
    setJobs([]);
    setJobName(null);
    setRunID(null);
    if (!commit) return;
    if (provider === "github") {
      setRunID(commitWorkflowRuns(commit)[0]?.id ?? null);
      return;
    }
    const pipeline = commit.runs[0]?.id;
    if (pipeline === undefined) return;
    let cancelled = false;
    setLoading(true);
    ci.commitJobs(pipeline)
      .then((list) => {
        if (cancelled) return;
        setJobs(list);
        setJobName(defaultCommitJob(list)?.name ?? null);
      }, () => {})
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ci, provider, commit?.sha]);

  // what starts again for the chosen commit
  const commitRun: CommitRun | null = (() => {
    if (!commit) return null;
    if (provider === "github") return runID === null ? null : { runID, jobName: null };
    const pipeline = commit.runs[0]?.id;
    return pipeline !== undefined && jobName && jobs.some((j) => j.name === jobName) ? { runID: pipeline, jobName } : null;
  })();
  const chosenJob = jobs.find((j) => j.name === jobName) ?? null;

  const canRun = (() => {
    if (!ref.trim()) return false;
    if (commit) return !!commitRun;
    if (provider === "gitlab") return true;
    if (!workflow) return false;
    return workflow.inputs.every((i) => !i.required || i.type === "boolean" || !!(values[i.name] ?? "").trim());
  })();

  const run = () => {
    if (!canRun) return;
    if (commit && commitRun) {
      if (later) return schedule([], {}, commit, commitRun);
      close();
      void ci.runOnCommit(commitRun);
      return;
    }
    const vars = variables.map((v): [string, string] => [v.key.trim(), v.value]).filter(([k]) => !!k);
    const inputs = workflow ? Object.fromEntries(Object.entries(values).filter(([k, v]) => !!v && workflow.inputs.some((i) => i.name === k))) : {};
    if (later) return schedule(vars, inputs);
    close();
    if (provider === "gitlab") {
      void ci.runPipeline(ref.trim(), vars);
    } else if (workflow) {
      void ci.runWorkflow(workflow, ref.trim(), inputs);
    }
  };

  /** Keeps the run with this repository and its account (never the token) for the app to start at the chosen time */
  const schedule = (vars: [string, string][], inputs: Record<string, string>, onCommit: RunCommit | null = null, target: CommitRun | null = null) => {
    const now = scheduledRuns.now(), at = parseDateTimeInput(runAt);
    setCheckedAt(now);
    const repo = store.target, account = store.hostingAccount, path = store.path;
    if (!canSchedule(at, now) || !repo || !account || !path || (provider === "github" && !workflow && !target)) return;
    const rerun = provider === "github" && target ? (onCommit?.runs.find((r) => r.id === target.runID) ?? null) : null;
    scheduledRuns.add({
      id: crypto.randomUUID(), repoPath: path, provider, host: repo.host, remote: repo.remote, path: repo.path, accountID: account.id,
      workflowID: provider === "github" && !target ? (workflow?.id ?? null) : null,
      workflowName: provider === "github" ? (rerun?.name ?? (target ? null : (workflow?.name ?? null))) : null,
      ref: ref.trim(), sha: onCommit?.sha ?? null, runID: target?.runID ?? null, jobName: target?.jobName ?? null,
      inputs: provider === "github" ? inputs : {}, variables: provider === "gitlab" ? vars : [],
      runAt: at, createdAt: now, state: "scheduled", message: null,
    });
    close();
  };

  const update = (id: number, patch: Partial<Variable>) => setVariables((vs) => vs.map((v) => (v.id === id ? { ...v, ...patch } : v)));

  return (
    <SharedSheet
      title={provider === "gitlab" ? t("Run pipeline") : t("Run workflow")}
      context={store.target ? `${store.target.host} / ${store.target.path}` : null}
      onClose={close}
      className="run-pipeline-sheet"
      primary={{
        label: later ? t("Schedule run") : t("Run"),
        onClick: run,
        disabledReason: later && !timeOK ? t("Choose a time in the future.") : null,
        disabled: !canRun,
        busy: loading,
      }}
    >
      <div className="col run-pipeline-body">
        <div className="form-row">
          <label>{t("Branch")}</label>
          <div className="row">
            {branches.length ? (
              <select className="select grow" value={ref} onChange={(e) => setRef(e.target.value)}>
                {branches.map((b) => (
                  <option key={b} value={b}>
                    {b}
                  </option>
                ))}
              </select>
            ) : (
              <input className="input grow" placeholder={t("Branch name")} value={ref} onChange={(e) => setRef(e.target.value)} />
            )}
          </div>
        </div>

        {/* the branch's tip by default, or one of its commits that already has runs on the branch, found by message or SHA */}
        <div className="form-row">
          <label htmlFor="run-commit-search">{t("Commit")}</label>
          <CommitChoices ref_={ref.trim()} commits={commits} query={query} setQuery={setQuery} sha={sha} choose={setSha} />
        </div>

        {commit && provider === "gitlab" ? (
          !jobs.length ? (
            <span className="muted">{loading ? t("Reading the jobs…") : t("This pipeline has no jobs.")}</span>
          ) : (
            <>
              <div className="form-row">
                <label htmlFor="run-commit-job">{t("Job")}</label>
                <div className="row">
                  <select id="run-commit-job" className="select grow" value={jobName ?? ""} onChange={(e) => setJobName(e.target.value || null)}>
                    {jobs.map((j) => (
                      <option key={j.id} value={j.name}>
                        {`${j.name} · ${statusInfo[j.status].title}`}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
              <span className="muted" data-run-commit-note>
                {chosenJob && chosenJob.status !== "manual" && chosenJob.status !== "scheduled"
                  ? t("Runs this job again in the pipeline of {0} on {1}.", commit.sha.slice(0, 7), ref.trim())
                  : t("Presses this job in the pipeline of {0} on {1}.", commit.sha.slice(0, 7), ref.trim())}
              </span>
            </>
          )
        ) : commit ? (
          <>
            <div className="form-row">
              <label htmlFor="run-commit-run">{t("Workflow run")}</label>
              <div className="row">
                <select id="run-commit-run" className="select grow" value={runID ?? ""} onChange={(e) => setRunID(e.target.value ? Number(e.target.value) : null)}>
                  {commitWorkflowRuns(commit).map((r) => (
                    <option key={r.id} value={r.id}>
                      {`${r.name} · ${t("run #{0}", String(r.number))}`}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <span className="muted" data-run-commit-note>{t("Re-runs this run of {0} on {1} with its original inputs.", commit.sha.slice(0, 7), ref.trim())}</span>
          </>
        ) : provider === "gitlab" ? (
          <div className="col" style={{ gap: 8 }}>
            <div className="row">
              <span style={{ fontWeight: 600 }}>{t("Variables")}</span>
              <span className="spacer" />
              <IconButton
                small
                icon={<span style={{ fontSize: 15, lineHeight: 1 }}>+</span>}
                tip={t("Add variable")}
                onClick={() => setVariables((vs) => [...vs, { id: nextVarID++, key: "", value: "", description: "", options: [], fixed: false }])}
              />
            </div>
            {!variables.length && <span className="muted">{t("Runs without variables.")}</span>}
            <div className="col" style={{ gap: 8, maxHeight: 300, overflow: "auto" }}>
              {variables.map((v) => (
                <div key={v.id} className="col" style={{ gap: 2 }}>
                  <div className="row" style={{ gap: 6 }}>
                    {v.fixed ? (
                      <span className="mono ellipsis" style={{ width: 170, flex: "none" }}>
                        {v.key}
                      </span>
                    ) : (
                      <input className="input mono" style={{ width: 170, flex: "none" }} placeholder={t("Name")} value={v.key} onChange={(e) => update(v.id, { key: e.target.value })} />
                    )}
                    {v.options.length ? (
                      <select className="select grow" value={v.value} onChange={(e) => update(v.id, { value: e.target.value })}>
                        {v.options.map((o) => (
                          <option key={o} value={o}>
                            {o}
                          </option>
                        ))}
                      </select>
                    ) : (
                      <input className="input grow" placeholder={t("Value")} value={v.value} onChange={(e) => update(v.id, { value: e.target.value })} />
                    )}
                    <IconButton small icon={<span style={{ fontSize: 15, lineHeight: 1 }}>−</span>} tip={t("Remove this variable")} onClick={() => setVariables((vs) => vs.filter((x) => x.id !== v.id))} />
                  </div>
                  {v.description && <span className="muted" style={{ fontSize: 11.5 }}>{v.description}</span>}
                </div>
              ))}
            </div>
          </div>
        ) : loadError ? (
          <span className="error-text" style={{ whiteSpace: "pre-wrap" }}>
            {loadError}
          </span>
        ) : !workflows.length ? (
          <span className="muted">{loading ? t("Reading the workflow…") : t("This branch has no workflow with 'Run workflow' (workflow_dispatch).")}</span>
        ) : (
          <>
            <div className="form-row">
              <label>{t("Workflow")}</label>
              <div className="row">
                <select className="select grow" value={workflowID ?? ""} onChange={(e) => pick(workflows, Number(e.target.value), values)}>
                  {workflows.map((w) => (
                    <option key={w.id} value={w.id}>
                      {w.name}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            {workflow && workflow.inputs.length > 0 && (
              <div className="col" style={{ gap: 10, maxHeight: 320, overflow: "auto" }}>
                {workflow.inputs.map((i) => (
                  <InputField key={i.name} input={i} value={values[i.name] ?? ""} onChange={(v) => setValues((cur) => ({ ...cur, [i.name]: v }))} />
                ))}
              </div>
            )}
          </>
        )}

        {/* run now, or at a date and time: the app keeps the run and starts it then */}
        <div className="form-row">
          <label>{t("When")}</label>
          <div className="row run-when">
            <Segmented value={later ? "later" : "now"} onChange={(v) => setLater(v === "later")}
              options={[{ value: "now", label: t("Run now") }, { value: "later", label: t("Run later") }]} />
            {later && <input id="run-later-at" type="datetime-local" className="input" aria-label={t("Run at")} value={runAt} onChange={(e) => setRunAt(e.target.value)} />}
          </div>
          {later && <span className="run-when-note">{t("Gitrochi starts the run at this time if it is open. Otherwise the run is marked missed.")}</span>}
        </div>
      </div>
    </SharedSheet>
  );
}

function InputField({ input, value, onChange }: { input: CIInput; value: string; onChange: (v: string) => void }) {
  const label = (input.description || input.name) + (input.required ? " *" : "");
  if (input.type === "boolean") return <Checkbox checked={value === "true"} onChange={(v) => onChange(v ? "true" : "false")} label={input.description || input.name} />;
  return (
    <div className="col" style={{ gap: 3 }}>
      <span>{label}</span>
      {input.type === "choice" && input.options.length ? (
        <select className="select" value={value} onChange={(e) => onChange(e.target.value)}>
          {input.options.map((o) => (
            <option key={o} value={o}>
              {o}
            </option>
          ))}
        </select>
      ) : (
        <input className="input" placeholder={input.name} value={value} onChange={(e) => onChange(e.target.value)} />
      )}
    </div>
  );
}

/**
 * The commit to run on: a search field over a list with the branch's tip first, then the commits that have runs on
 * it. A row is a status mark, the message and "sha · when", with the selection tint and a lighter hover
 * (docs/design.md, Selection). (macOS: commitForm and RunCommitRow in RunPipelineSheet.swift)
 */
function CommitChoices({ ref_, commits, query, setQuery, sha, choose }: {
  ref_: string;
  commits: RunCommit[];
  query: string;
  setQuery: (q: string) => void;
  sha: string | null;
  choose: (sha: string | null) => void;
}) {
  const shown = filterRunCommits(commits, query);
  const latest = t("Latest on {0}", ref_);
  const showLatest = !query.trim() || latest.toLowerCase().includes(query.trim().toLowerCase());
  const row = (key: string, selected: boolean, title: string, meta: string, status: CIStatus | null, onClick: () => void) => (
    <button key={key} type="button" role="option" aria-selected={selected} data-sha={key === "latest" ? "" : key} className={`run-commit-row ${selected ? "on" : ""}`} title={title} onClick={onClick}>
      <span className="run-commit-mark">{status ? <CIStatusIcon status={status} size={12} /> : <ArrowUp size={12} />}</span>
      <span className="run-commit-text">
        <span className="run-commit-title ellipsis">{title}</span>
        <span className="run-commit-meta ellipsis">{meta}</span>
      </span>
    </button>
  );
  return (
    <div className="col run-commit-choices">
      <label className="run-commit-search">
        <Search size={13} />
        <input id="run-commit-search" value={query} placeholder={t("Search commits by message or SHA")} spellCheck={false} onChange={(e) => setQuery(e.target.value)} />
      </label>
      <div className="run-commit-list" role="listbox" aria-label={t("Commits")}>
        {showLatest && row("latest", sha === null, latest, t("Runs on the branch's newest commit when it starts."), null, () => choose(null))}
        {shown.map((c) => row(c.sha, sha === c.sha, c.subject || c.sha.slice(0, 7), [c.sha.slice(0, 7), ...(c.created !== null ? [listWhen(c.created)] : [])].join(" · "), c.runs[0]?.status ?? null, () => choose(c.sha)))}
        {!shown.length && !showLatest && <span className="muted run-commit-empty">{t("No commits match.")}</span>}
      </div>
    </div>
  );
}
