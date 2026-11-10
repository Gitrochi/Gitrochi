import { useEffect, useState } from "react";
import { canSchedule, type CIInput, type CIWorkflow, dateTimeInputValue, nextFullHour, parseDateTimeInput, scheduledRuns } from "@/entities/ci";
import type { Provider } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { describe } from "@/shared/platform";
import { Button, Checkbox, IconButton, Modal, Segmented, Spinner } from "@/shared/ui";

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

/** GitLab: 브랜치·변수로 새 파이프라인 / GitHub: workflow_dispatch 워크플로를 브랜치·입력값으로 실행 */
export function RunPipelineSheet({ store, close }: { store: RepoStore; close: () => void }) {
  const ci = store.ci;
  const provider: Provider = store.target?.provider ?? "gitlab";
  const branches = ci.branches;
  const [ref, setRef] = useState(() => branches[0] ?? ci.currentRef ?? "");
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

  const canRun = (() => {
    if (!ref.trim()) return false;
    if (provider === "gitlab") return true;
    if (!workflow) return false;
    return workflow.inputs.every((i) => !i.required || i.type === "boolean" || !!(values[i.name] ?? "").trim());
  })();

  const run = () => {
    if (!canRun) return;
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
  const schedule = (vars: [string, string][], inputs: Record<string, string>) => {
    const now = scheduledRuns.now(), at = parseDateTimeInput(runAt);
    setCheckedAt(now);
    const target = store.target, account = store.hostingAccount, path = store.path;
    if (!canSchedule(at, now) || !target || !account || !path || (provider === "github" && !workflow)) return;
    scheduledRuns.add({
      id: crypto.randomUUID(), repoPath: path, provider, host: target.host, remote: target.remote, path: target.path, accountID: account.id,
      workflowID: provider === "github" ? (workflow?.id ?? null) : null, workflowName: provider === "github" ? (workflow?.name ?? null) : null,
      ref: ref.trim(), inputs: provider === "github" ? inputs : {}, variables: provider === "gitlab" ? vars : [],
      runAt: at, createdAt: now, state: "scheduled", message: null,
    });
    close();
  };

  const update = (id: number, patch: Partial<Variable>) => setVariables((vs) => vs.map((v) => (v.id === id ? { ...v, ...patch } : v)));

  return (
    <Modal
      title={provider === "gitlab" ? t("Run pipeline") : t("Run workflow")}
      width={540}
      onClose={close}
      footer={
        <>
          {loading && <Spinner />}
          <span className="spacer" />
          <Button onClick={close}>{t("Cancel")}</Button>
          {/* the reason sits beside the primary it disables */}
          {later && !timeOK && <span className="muted">{t("Choose a time in the future.")}</span>}
          <Button kind="primary" disabled={!canRun || (later && !timeOK)} onClick={run}>
            {later ? t("Schedule run") : t("Run")}</Button>
        </>
      }
    >
      <div className="col" style={{ gap: 12 }}>
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

        {provider === "gitlab" ? (
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
        <div className="col" style={{ gap: 8 }}>
          <div className="row">
            <Segmented value={later ? "later" : "now"} onChange={(v) => setLater(v === "later")}
              options={[{ value: "now", label: t("Run now") }, { value: "later", label: t("Run later") }]} />
          </div>
          {later && (
            <>
              <div className="form-row">
                <label htmlFor="run-later-at">{t("Run at")}</label>
                <div className="row">
                  <input id="run-later-at" type="datetime-local" className="input grow" value={runAt} onChange={(e) => setRunAt(e.target.value)} />
                </div>
              </div>
              <span className="muted">{t("Gitrochi starts the run at this time if it is open. Otherwise the run is marked missed.")}</span>
            </>
          )}
        </div>
      </div>
    </Modal>
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
