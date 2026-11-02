import { useEffect, useState } from "react";
import type { LedgerSession, LedgerState, LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { Button, Empty, Modal, Spinner } from "@/shared/ui";
import "./ledger-manage.css";

type Mode = "session" | "baseline";
type Form = { title: string; kind: string; touches: string; related: string; chatUrl: string };
type Pending = { kind: "delete" | "close" } | { kind: "session" | "project" | "version"; value: string } | { kind: "mode"; value: Mode };
const blank: Form = { title: "", kind: "", touches: "", related: "", chatUrl: "" };
const fields = (session: LedgerSession | undefined): Form => session ? { title: session.title, kind: session.kind, touches: session.touches.join("\n"), related: session.related.join("\n"), chatUrl: session.chatUrl ?? "" } : blank;

/** Person-only record metadata and explicit session deletion. (macOS: LedgerManageSheet) */
export function LedgerManage({ store, onClose }: { store: LedgerStore; onClose: () => void }) {
  const [project, setProject] = useState(store.project ?? store.state?.projects[0]?.key ?? "");
  const [snapshot, setSnapshot] = useState<LedgerState | null>(null);
  const [sessionId, setSessionId] = useState(store.selectedId ?? "");
  const [version, setVersion] = useState("");
  const [mode, setMode] = useState<Mode>("session");
  const [form, setForm] = useState<Form>(blank);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [pending, setPending] = useState<Pending | null>(null);
  const session = snapshot?.sessions.find((s) => s.id === sessionId);
  const baselines = snapshot?.baselines.filter((b) => b.project === project) ?? [];
  const baseline = baselines.find((b) => b.version === version);
  const dirty = mode === "session" ? JSON.stringify(form) !== JSON.stringify(fields(session)) : note !== (baseline?.note ?? "");
  const selectSession = (id: string, data = snapshot) => { setSessionId(id); setForm(fields(data?.sessions.find((s) => s.id === id))); setError(""); };
  const selectVersion = (value: string, data = snapshot) => { setVersion(value); setNote(data?.baselines.find((b) => b.project === project && b.version === value)?.note ?? ""); setError(""); };
  const load = async () => {
    const data = await store.backend.call("state", { range: "all", ...(project ? { project } : {}) });
    setSnapshot(data);
    const id = data.sessions.some((s) => s.id === sessionId) ? sessionId : data.sessions[0]?.id ?? "";
    const v = data.baselines.some((b) => b.project === project && b.version === version) ? version : data.baselines.find((b) => b.project === project)?.version ?? "";
    selectSession(id, data); selectVersion(v, data);
  };
  useEffect(() => {
    let alive = true;
    setBusy(true);
    void store.backend.call("state", { range: "all", ...(project ? { project } : {}) }).then((data) => {
      if (!alive) return;
      setSnapshot(data);
      const id = data.sessions.some((s) => s.id === sessionId) ? sessionId : data.sessions[0]?.id ?? "";
      selectSession(id, data);
      selectVersion(data.baselines.find((b) => b.project === project)?.version ?? "", data);
    }).catch((e: unknown) => { if (alive) setError(e instanceof Error ? e.message : String(e)); }).finally(() => { if (alive) setBusy(false); });
    return () => { alive = false; };
  }, [store, project]);

  const run = async (action: Pending) => {
    setPending(null);
    if (action.kind === "close") { onClose(); return; }
    if (action.kind === "session") { selectSession(action.value); return; }
    if (action.kind === "version") { selectVersion(action.value); return; }
    if (action.kind === "project") { setProject(action.value); return; }
    if (action.kind === "mode") {
      setForm(fields(session)); setNote(baseline?.note ?? ""); setMode(action.value); return;
    }
    setBusy(true); setError("");
    try {
      await store.backend.call("records", { action: "delete", sessionId, confirmed: true });
      if (store.selectedId === sessionId) store.select(null);
      await load(); await store.refresh(true);
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };
  const request = (action: Pending) => {
    if (busy) return;
    if (action.kind === "mode" && action.value === mode) return;
    if (action.kind === "session" && action.value === sessionId) return;
    if (action.kind === "delete" || dirty) setPending(action); else void run(action);
  };
  const save = async () => {
    setBusy(true); setError("");
    try {
      await store.backend.call("records", mode === "session" ? {
        action: "update", sessionId, title: form.title, kind: form.kind,
        touches: form.touches.split("\n").map((s) => s.trim()).filter(Boolean),
        related: form.related.split(/[\n,]/).map((s) => s.trim()).filter(Boolean), chatUrl: form.chatUrl || null,
      } : { action: "version_note", project, version, note });
      await load(); await store.refresh(true);
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };
  const field = (key: keyof Form, value: string) => setForm((previous) => ({ ...previous, [key]: value }));

  return <>
    <Modal title={t("Manage records")} width={760} onClose={() => request({ kind: "close" })} footer={<>
      {mode === "session" && session && <Button kind="danger" disabled={busy} onClick={() => request({ kind: "delete" })}>{t("Delete session…")}</Button>}
      <span className="ledger-manage-spacer" />{busy && <Spinner />}
      <Button disabled={busy} onClick={() => request({ kind: "close" })}>{t("Close")}</Button>
      <Button kind={busy || !dirty || (mode === "session" ? !session || !form.title.trim() || !form.kind.trim() : !baseline) ? undefined : "primary"} disabled={busy || !dirty || (mode === "session" ? !session || !form.title.trim() || !form.kind.trim() : !baseline)} onClick={() => void save()}>{mode === "session" ? t("Save session details") : t("Save baseline note")}</Button>
    </>}>
      <div className="ledger-tabs ledger-manage-tabs"><button className={mode === "session" ? "on" : ""} onClick={() => request({ kind: "mode", value: "session" })}>{t("Session details")}</button><button className={mode === "baseline" ? "on" : ""} onClick={() => request({ kind: "mode", value: "baseline" })}>{t("Baseline notes")}</button></div>
      <div className="ledger-manage-form">
        <label>{t("Project")}<select className="select" value={project} disabled={busy} onChange={(e) => request({ kind: "project", value: e.target.value })}>{(snapshot?.projects ?? store.state?.projects ?? []).map((p) => <option key={p.key} value={p.key}>{p.name}</option>)}</select></label>
        {mode === "session" ? <>
          <label>{t("Session")}<select className="select" value={sessionId} disabled={busy} onChange={(e) => request({ kind: "session", value: e.target.value })}>{snapshot?.sessions.map((s) => <option key={s.id} value={s.id}>{s.title} · {s.id}</option>)}</select></label>
          {session ? <>
            <label>{t("Title")}<input className="input" maxLength={500} value={form.title} disabled={busy} onChange={(e) => field("title", e.target.value)} /></label>
            <label>{t("Session kind")}<input className="input" maxLength={100} list="ledger-session-kinds" value={form.kind} disabled={busy} onChange={(e) => field("kind", e.target.value)} /><datalist id="ledger-session-kinds">{["research", "decision", "implementation", "document", "review", "baseline", "other"].map((kind) => <option key={kind} value={kind} />)}</datalist></label>
            <label>{t("Touched IDs and paths, one per line")}<textarea className="input" rows={4} value={form.touches} disabled={busy} onChange={(e) => field("touches", e.target.value)} /></label>
            <label>{t("Related session IDs")}<input className="input" value={form.related} disabled={busy} onChange={(e) => field("related", e.target.value)} /></label>
            <label>{t("Chat URL")}<input className="input" type="url" value={form.chatUrl} disabled={busy} onChange={(e) => field("chatUrl", e.target.value)} /></label>
          </> : !busy && <Empty title={t("No sessions in this project")} />}
        </> : <>
          <label>{t("Baseline")}<select className="select" value={version} disabled={busy} onChange={(e) => request({ kind: "version", value: e.target.value })}>{baselines.map((b) => <option key={b.version} value={b.version}>{b.version}</option>)}</select></label>
          {baseline ? <label>{t("Baseline note")}<textarea className="input" rows={8} maxLength={60000} value={note} disabled={busy} onChange={(e) => setNote(e.target.value)} /></label> : !busy && <Empty title={t("No baselines in this project")} />}
        </>}
        {error && <div className="ledger-manage-error" role="alert">{error}</div>}
      </div>
    </Modal>
    {pending && <Modal title={pending.kind === "delete" ? t("Delete this session?") : t("Discard unsaved changes?")} onClose={() => setPending(null)} footer={<><Button onClick={() => setPending(null)}>{t("Cancel")}</Button><Button kind={pending.kind === "delete" ? "danger" : "primary"} onClick={() => void run(pending)}>{pending.kind === "delete" ? t("Delete") : t("Discard changes")}</Button></>}>
      <p>{pending.kind === "delete" ? t("This removes its reports, questions and waiting prompts. Baselines and work records remain. A running agent can report again.") : t("Your draft will be replaced. Save it first to keep your changes.")}</p>
    </Modal>}
  </>;
}
