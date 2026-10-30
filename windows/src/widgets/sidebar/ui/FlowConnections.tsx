import { useEffect, useState } from "react";
import { statusInfo, type CIStatus } from "@/entities/ci";
import { browseFlowConnection, listFlowConnections, saveFlowConnection, testFlowConnection, type FlowConnection, type FlowRemoteBrowse } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { Button, Modal, Spinner } from "@/shared/ui";
import "./flow-connections.css";

const fresh = (): FlowConnection => ({ name: "", kind: "jenkins", url: "", user: null, project: null, secret: "env:CI_TOKEN", allow: [] });
const providerNames: Record<FlowConnection["kind"], string> = { github: "GitHub Actions", gitlab: "GitLab CI/CD", jenkins: "Jenkins", http: "HTTP CI", webhook: "Webhook" };

/** Connection references live in user settings; no token is accepted by this form. */
export function FlowConnections({ repo }: { repo: string }) {
  const [open, setOpen] = useState(false);
  const [connections, setConnections] = useState<FlowConnection[]>([]);
  const [draft, setDraft] = useState<FlowConnection>(fresh);
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [browse, setBrowse] = useState<FlowRemoteBrowse | null>(null);
  const [job, setJob] = useState("");
  const [run, setRun] = useState<string | null>(null);
  const reload = async () => setConnections(await listFlowConnections(repo));
  useEffect(() => { let stale = false; void listFlowConnections(repo).then((values) => { if (!stale) setConnections(values); }).catch(() => {}); return () => { stale = true; }; }, [repo]);
  const action = async (work: () => Promise<void>) => {
    setBusy(true); setError(""); setMessage("");
    try { await work(); } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
    finally { setBusy(false); }
  };
  const choose = (value: FlowConnection) => { setDraft({ ...value }); setSelected(value.name); setBrowse(null); setJob(""); setRun(null); setError(""); setMessage(""); };
  const loadBuilds = (path: string, number?: string) => action(async () => {
    const result = await browseFlowConnection(repo, selected!, path, number);
    setBrowse(result); setJob(path); setRun(number ?? null);
  });
  const field = <K extends keyof FlowConnection>(key: K, value: FlowConnection[K]) => setDraft((old) => ({ ...old, [key]: value }));
  return <>
    <div className="flow-connections-summary"><div><strong>{t("Connected services")}</strong><span className="muted">{t("Docker, Compose, Jenkins and HTTP CI modules · GitHub Actions and GitLab runs")}</span></div><Button onClick={() => { setOpen(true); void action(reload); }}>{t("Manage connections")}{connections.length > 0 && ` (${connections.length})`}</Button></div>
    {open && <Modal title={t("Connected services")} width={940} onClose={() => { if (!busy) setOpen(false); }} footer={<>{busy && <Spinner size={12} />}<span className="spacer" /><Button disabled={busy} onClick={() => setOpen(false)}>{t("Done")}</Button></>}>
      <div className="flow-connections-manager"><aside><Button disabled={busy} onClick={() => { setSelected(null); setDraft(fresh()); setBrowse(null); setError(""); setMessage(""); }}>{t("Add connection")}</Button>{connections.map((value) => <button className={`flow-connection-item ${selected === value.name ? "selected" : ""}`} key={value.name} disabled={busy} onClick={() => choose(value)}><strong>{value.name}</strong><span>{providerNames[value.kind]}</span></button>)}<p className="muted">{t("Docker and Compose use your local Docker context. Add their modules in the visual editor.")}</p></aside>
        <section><div className="flow-connection-fields">
          <label>{t("Connection name")}<input value={draft.name} disabled={busy || selected !== null} onChange={(e) => field("name", e.target.value)} placeholder="build-server" /></label>
          <label>{t("Provider")}<select value={draft.kind} disabled={busy} onChange={(e) => field("kind", e.target.value as FlowConnection["kind"])}>{Object.entries(providerNames).map(([kind, name]) => <option key={kind} value={kind}>{name}</option>)}</select></label>
          <label className="wide">{t("Server address")}<input value={draft.url} disabled={busy} onChange={(e) => field("url", e.target.value)} placeholder="https://ci.example.com" /></label>
          <label>{t("User (optional)")}<input value={draft.user ?? ""} disabled={busy} onChange={(e) => field("user", e.target.value || null)} autoComplete="off" /></label>
          <label>{t("Project (optional)")}<input value={draft.project ?? ""} disabled={busy} onChange={(e) => field("project", e.target.value || null)} placeholder="owner/repository" /></label>
          <label className="wide">{t("Credential reference")}<input value={draft.secret} disabled={busy} onChange={(e) => field("secret", e.target.value)} autoComplete="off" spellCheck={false} /><span className="muted">{t("Use env:CI_TOKEN, app:account-id or gh:login. Existing saved tokens can use keystore.")}</span></label>
          <label className="wide">{t("Allowed jobs (comma separated)")}<input value={draft.allow.join(", ")} disabled={busy} onChange={(e) => field("allow", e.target.value.split(",").map((s) => s.trim()).filter(Boolean))} placeholder="team/*" /></label>
        </div><div className="row" style={{ gap: 8, marginTop: 12 }}><Button kind="primary" disabled={busy} onClick={() => void action(async () => { await saveFlowConnection(repo, draft); await reload(); setSelected(draft.name); setMessage(t("Connection saved.")); })}>{t("Save connection")}</Button><Button disabled={busy || !selected} onClick={() => void action(async () => { const result = await testFlowConnection(repo, selected!); if (!result.ok) throw new Error([result.message, result.action].filter(Boolean).join("\n")); setMessage(t("Connection is available.")); })}>{t("Test connection")}</Button>{selected && draft.kind === "jenkins" && <Button disabled={busy} onClick={() => void loadBuilds("")}>{t("Browse Jenkins builds")}</Button>}</div>
        {message && <p role="status" className="flow-connection-notice">{message}</p>}{error && <p role="alert" className="error-text">{error}</p>}
        {browse && <div className="flow-remote-browser"><div className="row"><strong>{job || t("Jenkins jobs")}{run && ` · #${run}`}</strong><span className="spacer" />{job && <Button disabled={busy} onClick={() => void loadBuilds(run ? job : job.split("/").slice(0, -1).join("/"))}>{t("Back")}</Button>}</div>
          {browse.jobs.map((value) => <button disabled={busy} className="flow-remote-row" key={value.path} onClick={() => void loadBuilds(value.path)}><span>{value.folder ? "▸" : "○"} {value.name}</span><span className="muted">{t("Open")}</span></button>)}
          {browse.runs.map((value) => <button disabled={busy} className="flow-remote-row" key={value.id} onClick={() => void loadBuilds(job, value.id)}><span>{value.title}</span><span style={{ color: statusInfo[value.status as CIStatus]?.color }}>{statusInfo[value.status as CIStatus]?.title ?? t("Unknown")}</span><span className="muted">{value.startedAt ? new Date(value.startedAt).toLocaleString() : ""}</span><span>{t("View logs")}</span></button>)}
          {browse.log !== null && <pre className="flow-connection-log">{browse.log || t("No log output yet.")}</pre>}{browse.truncated && <p className="muted">{t("The log preview is truncated.")}</p>}{!browse.jobs.length && !browse.runs.length && browse.log === null && <p className="muted">{t("No builds or jobs found.")}</p>}
        </div>}
        <p className="muted">{t("GitHub Actions and GitLab history, jobs and controls appear in the repository CI panel. Jenkins and other providers run through reviewed CI modules; HTTP CI endpoints are configured per module.")}</p>
        </section></div>
    </Modal>}
  </>;
}
