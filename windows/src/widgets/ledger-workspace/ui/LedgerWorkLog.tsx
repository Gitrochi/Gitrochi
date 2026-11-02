import { useEffect, useState } from "react";
import type { LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { Button, Empty, Markdown, Modal, Spinner } from "@/shared/ui";
import "./ledger-work-log.css";

type WorkItem = { id: string; title: string; bundle: string; status: string; stem?: string; output?: string; scope?: string[] };
type WorkEvent = { id: number; date: string; event: string; text: string; estimated?: boolean; refs?: string[] };
type WorkList = { items: WorkItem[]; warnings: { message?: string; item?: string }[] };
type WorkHistory = { id: number; action: string; date: string; before?: Record<string, unknown>; after?: Record<string, unknown> };
type WorkDetail = { item: WorkItem; events: WorkEvent[]; history: WorkHistory[] };
const message = (error: unknown): string => {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object") {
    if ("message" in error && typeof error.message === "string") return error.message;
    if ("error" in error) return message(error.error);
  }
  return String(error);
};
const changeText = (value?: Record<string, unknown>) => {
  if (!value) return "";
  const fields = { text: "Work description", date: "Work date", title: "Title", output: "Expected output", scope: "Work scope", stem: "Work group", item: "Work ID", bundle: "Bundle", from_item: "From item", to_item: "To item", field: "Field", value: "Value" };
  return Object.entries(fields).filter(([key]) => value[key] !== undefined && value[key] !== null && value[key] !== "").map(([key, label]) => `${t(label)}: ${Array.isArray(value[key]) ? value[key].join(", ") : String(value[key])}`).join(" · ");
};
const today = () => { const date = new Date(); return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`; };
const kinds = [["progress", "Progress"], ["started", "Started"], ["completed", "Completed"], ["issue", "Issue"], ["held", "Held"], ["resumed", "Resumed"], ["frozen", "Frozen"], ["cancelled", "Cancelled"], ["plan", "Plan"], ["transfer", "Transfer"], ["stem", "Set group"], ["item_fix", "Edit work item"], ["text_fix", "Correct text"], ["date_fix", "Correct date"], ["move", "Move record"], ["carry", "Carry issue"], ["bundle_completed", "Complete bundle"], ["bundle_reopened", "Reopen bundle"], ["skipped", "Leave unassigned"], ["note", "Message to work agents"]] as const;
const eventLabel = (event: string) => {
  const legacy: Record<string, string> = { work_text_fixes: "text_fix", work_date_fixes: "date_fix", work_item_fixes: "item_fix", work_stems: "stem", work_moves: "move", work_carries: "carry", work_splits: "split" };
  const kind = legacy[event] ?? event;
  return t(kinds.find(([key]) => key === kind)?.[1] ?? (kind === "split" ? "Split work item" : kind === "registered" ? "Registered" : event));
};
const emptyForm = () => ({ item: "", title: "", bundle: "", output: "", scope: "", stem: "", from: "", date: today(), event: "progress", text: "", refs: "", to: "", eventId: "", was: "", conservative: "", slack: "" });

/** Dated work and reports span conversations without changing their cleanup state. */
export function LedgerWorkLog({ store, onClose }: { store: LedgerStore; onClose: () => void }) {
  const [project, setProject] = useState(store.project ?? store.state?.projects[0]?.key ?? "");
  const [list, setList] = useState<WorkList>({ items: [], warnings: [] });
  const [selected, setSelected] = useState("");
  const [detail, setDetail] = useState<WorkDetail | null>(null);
  const [creating, setCreating] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [filter, setFilter] = useState("");
  const [range, setRange] = useState({ from: "", to: "" });
  const [reportOptions, setReportOptions] = useState({ summary: false, refs: false });
  const [report, setReport] = useState<string | null>(null);
  const [unassigned, setUnassigned] = useState<WorkEvent[] | null>(null);
  const [paste, setPaste] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const field = (key: keyof typeof form, value: string) => setForm((old) => ({ ...old, [key]: value }));
  const call = (args: Record<string, unknown>) => store.backend.call("work", { project, ...args });
  const reload = async () => { if (project) setList(await call({ action: "list" }) as WorkList); };
  useEffect(() => { let alive = true; if (project) void call({ action: "list" }).then((value) => { if (alive) { setList(value as WorkList); setError(""); } }).catch((e) => { if (alive) setError(message(e)); }); return () => { alive = false; }; }, [store, project]);
  useEffect(() => { let alive = true; setDetail(null); if (selected && project) void call({ action: "detail", item: selected }).then((value) => { if (alive) setDetail(value as WorkDetail); }).catch((e) => { if (alive) setError(message(e)); }); return () => { alive = false; }; }, [store, selected, project]);
  const run = async (operation: () => Promise<void>) => { setBusy(true); setError(""); setNotice(""); try { await operation(); } catch (e) { setError(message(e)); } finally { setBusy(false); } };
  const save = () => run(async () => {
    const item = list.items.find((entry) => entry.id === selected);
    const args: Record<string, unknown> = { action: creating ? "add_item" : form.event === "note" ? "note" : "event", item: creating ? form.item : selected, date: form.date, event: creating ? "registered" : form.event, text: form.text, refs: form.refs.split(",").map((s) => s.trim()).filter(Boolean), bundle: creating ? form.bundle : item?.bundle };
    if (creating || form.event === "item_fix") Object.assign(args, { title: form.title, output: form.output, scope: form.scope.split(",").map((s) => s.trim()).filter(Boolean) });
    if (creating) Object.assign(args, { stem: form.stem, ...(form.from ? { from: form.from } : {}) });
    if (!creating) {
      if (form.event === "note") args.target = selected;
      if (form.event === "plan") args.plan = { conservative: form.conservative, slack: form.slack };
      if (["transfer", "move", "carry"].includes(form.event)) args.to = form.to;
      if (form.event === "stem") args.stem = form.stem;
      if (isCorrection && form.eventId) args.eventId = Number(form.eventId);
      if (form.event === "date_fix") args.was = form.was;
    }
    await call(args);
    await reload();
    const id = creating ? form.item : selected;
    setSelected(id); setCreating(false); setDetail(await call({ action: "detail", item: id }) as WorkDetail); setForm(emptyForm()); setNotice(t("Work record saved"));
  });
  const isCorrection = ["text_fix", "date_fix", "move", "carry"].includes(form.event);
  const chooseRecord = (entry: WorkEvent, event = isCorrection ? form.event : "text_fix") => setForm((old) => ({ ...old, event, eventId: String(entry.id), was: entry.date, date: event === "date_fix" || event === "carry" ? today() : entry.date, text: event === "text_fix" ? entry.text : "", refs: (entry.refs ?? []).join(", ") }));
  const chooseType = (event: string) => {
    const item = detail?.item ?? list.items.find((entry) => entry.id === selected);
    const record = detail?.events.find((entry) => String(entry.id) === form.eventId);
    setForm((old) => ({ ...old, event, date: today(), title: item?.title ?? "", output: item?.output ?? "", scope: (item?.scope ?? []).join(", "), stem: item?.stem ?? "", text: "", refs: "", eventId: "", was: "" }));
    if (record && ["text_fix", "date_fix", "move", "carry"].includes(event)) chooseRecord(record, event);
  };
  return <Modal title={t("Work log")} width={1040} onClose={onClose} footer={<><span className="spacer" /><Button onClick={onClose}>{t("Close")}</Button></>}>
    <div className="ledger-work-tools">
      <label>{t("Project")}<input className="input" aria-label={t("Work project")} value={project} disabled={busy} onChange={(e) => { setProject(e.target.value); setSelected(""); setCreating(false); setList({ items: [], warnings: [] }); setForm(emptyForm()); setReport(null); setUnassigned(null); }} /></label>
      <Button disabled={!project || busy} onClick={() => { setForm(emptyForm()); setCreating(true); setReport(null); setUnassigned(null); }}>{t("New work item")}</Button>
      <Button disabled={!project || busy} onClick={() => void run(async () => { const value = await call({ action: "report", bundle: filter || undefined, from: range.from || undefined, to: range.to || undefined, ...reportOptions }) as { markdown: string }; setReport(value.markdown); setUnassigned(null); })}>{t("Build report")}</Button>
      <Button disabled={!project || busy} onClick={() => void run(async () => { const result = await call({ action: "unassigned", from: range.from || undefined, to: range.to || undefined }) as { events?: WorkEvent[]; unassigned?: WorkEvent[] }; setUnassigned(result.events ?? result.unassigned ?? []); setReport(null); })}>{t("Unassigned reports")}</Button>
      <Button onClick={() => setPaste(paste === null ? "" : null)}>{t("Paste work records")}</Button>
      {busy && <Spinner size={14} />}
    </div>
    {!project && <span className="hint">{t("Choose or enter a project to keep its work records together.")}</span>}
    {error && <div className="error-text" role="alert">{error}</div>}{notice && <div role="status">{notice}</div>}
    {paste !== null && <div className="col"><textarea className="textarea" aria-label={t("Work records")} rows={6} value={paste} onChange={(e) => setPaste(e.target.value)} /><Button disabled={busy || !paste.trim() || !project} onClick={() => void run(async () => { const result = await call({ action: "import", text: paste }) as { results: { line: number; status: string; error?: unknown }[] }; await reload(); setNotice(result.results.map((r) => `${r.line}: ${r.error ? message(r.error) : t(r.status)}`).join(" · ")); })}>{t("Import work records")}</Button></div>}
    <div className="ledger-work-report-filters"><label>{t("Bundle")}<input className="input" value={filter} onChange={(e) => setFilter(e.target.value)} /></label><label>{t("From date")}<input className="input" type="date" value={range.from} onChange={(e) => setRange({ ...range, from: e.target.value })} /></label><label>{t("To date")}<input className="input" type="date" value={range.to} onChange={(e) => setRange({ ...range, to: e.target.value })} /></label></div>
    <div className="ledger-work-options"><label><input type="checkbox" checked={reportOptions.summary} onChange={(e) => setReportOptions({ ...reportOptions, summary: e.target.checked })} />{t("Summary report")}</label><label><input type="checkbox" checked={reportOptions.refs} onChange={(e) => setReportOptions({ ...reportOptions, refs: e.target.checked })} />{t("Include evidence references")}</label></div>
    {!!list.warnings.length && <details className="ledger-work-warnings"><summary>{t("Work warnings")} ({list.warnings.length})</summary>{list.warnings.map((warning, index) => <p key={index}>{warning.item && <code>{warning.item} · </code>}{t(warning.message ?? "")}</p>)}</details>}
    {report !== null ? <div className="ledger-work-report"><Button onClick={() => setReport(null)}>{t("Back")}</Button><Button onClick={() => void navigator.clipboard.writeText(report)}>{t("Copy report")}</Button><Markdown text={report} /></div> : unassigned !== null ? <div className="ledger-work-report"><Button onClick={() => setUnassigned(null)}>{t("Back")}</Button><h3>{t("Unassigned reports")}</h3>{unassigned.map((entry) => <p key={entry.id}><code>E{entry.id}</code> {entry.text || (entry as WorkEvent & { summary?: string }).summary}</p>)}{!unassigned.length && <Empty title={t("No unassigned reports")} />}</div> : <div className="ledger-work-columns">
      <div className="ledger-work-items" aria-label={t("Work items")}>{list.items.filter((entry) => !filter || entry.bundle === filter).map((entry) => <button type="button" disabled={busy} key={entry.id} className={selected === entry.id && !creating ? "selected" : ""} onClick={() => { setSelected(entry.id); setForm(emptyForm()); setCreating(false); }}><strong>{entry.title}</strong><span>{entry.id} · {entry.bundle}</span><span>{t(entry.status)}</span></button>)}{!list.items.length && <Empty title={t("No work items yet")} detail={t("Group work across conversations and turn dated records into reports.")} />}</div>
      <div className="ledger-work-editor">
        {(creating || selected) && <fieldset disabled={busy} className="ledger-work-fields">
          <h3>{creating ? t("New work item") : list.items.find((entry) => entry.id === selected)?.title}</h3>
          <div className="ledger-work-form">
            {!creating && <label>{t("Record type")}<select className="select" value={form.event} onChange={(e) => chooseType(e.target.value)}>{kinds.map(([key, label]) => <option key={key} value={key}>{t(label)}</option>)}</select></label>}
            {creating && <><label>{t("Work ID")}<input className="input" placeholder="W-app-01" value={form.item} onChange={(e) => field("item", e.target.value)} /></label><label>{t("Bundle")}<input className="input" value={form.bundle} onChange={(e) => field("bundle", e.target.value)} /></label><label>{t("Split from item (optional)")}<input className="input" value={form.from} onChange={(e) => field("from", e.target.value)} /></label></>}
            {(creating || form.event === "item_fix") && <><label>{t("Title")}<input className="input" value={form.title} onChange={(e) => field("title", e.target.value)} /></label><label>{t("Expected output")}<input className="input" value={form.output} onChange={(e) => field("output", e.target.value)} /></label><label>{t("Work scope")}<input className="input" value={form.scope} onChange={(e) => field("scope", e.target.value)} /></label></>}
            <label>{t("Work date")}<input className="input" value={form.date} placeholder="YYYY-MM-DD" onChange={(e) => field("date", e.target.value)} /></label>
            {(creating || form.event === "stem") && <label>{t("Work group")}<input className="input" value={form.stem} onChange={(e) => field("stem", e.target.value)} /></label>}
            {form.event === "plan" && !creating && <><label>{t("Conservative date")}<input className="input" type="date" value={form.conservative} onChange={(e) => field("conservative", e.target.value)} /></label><label>{t("Slack date")}<input className="input" type="date" value={form.slack} onChange={(e) => field("slack", e.target.value)} /></label></>}
            {["transfer", "move", "carry"].includes(form.event) && !creating && <label>{t("Destination")}<input className="input" value={form.to} onChange={(e) => field("to", e.target.value)} /></label>}
            {isCorrection && !creating && <label>{t("Record number")}<input className="input" type="number" min={1} step={1} value={form.eventId} onChange={(e) => { const entry = detail?.events.find((entry) => String(entry.id) === e.target.value); if (entry) chooseRecord(entry); else field("eventId", e.target.value); }} /></label>}
            {form.event === "date_fix" && !creating && <label>{t("Original date")}<input className="input" value={form.was} onChange={(e) => field("was", e.target.value)} /></label>}
          </div>
          <label>{t("Work description")}<textarea className="textarea" rows={3} value={form.text} onChange={(e) => field("text", e.target.value)} /></label>
          <label>{t("Evidence references")}<input className="input" placeholder="E12, docs/report.md" value={form.refs} onChange={(e) => field("refs", e.target.value)} /></label>
          <span className="hint">{t("Prefix an uncertain work date with ~. Corrections keep the original record in history.")}</span>
          <Button kind="primary" disabled={busy || !project || (!creating && !detail) || creating && (!form.item.trim() || !form.title.trim() || !form.bundle.trim()) || !creating && form.event === "item_fix" && !form.title.trim()} onClick={() => void save()}>{t("Save work record")}</Button>
          {!creating && <div className="ledger-work-history"><h3>{t("Work history")}</h3>{detail?.events.map((entry) => <article key={entry.id}><button type="button" className="ledger-work-record" disabled={busy} onClick={() => chooseRecord(entry)} title={t("Use this record")}><span>#{entry.id} · {entry.estimated ? "~" : ""}{entry.date} · {eventLabel(entry.event)}</span></button><p>{entry.text}</p>{!!entry.refs?.length && <span className="hint">{entry.refs.join(", ")}</span>}</article>)}{!!detail?.history.length && <details><summary>{t("{0} corrections retained", detail.history.length)}</summary>{detail.history.map((entry) => <article key={entry.id}><span className="hint">{entry.date} · {eventLabel(entry.action)}</span><p>{t("Before")}: {changeText(entry.before)}</p><p>{t("After")}: {changeText(entry.after)}</p></article>)}</details>}</div>}
        </fieldset>}
      </div>
    </div>}
  </Modal>;
}
