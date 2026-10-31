import { ClipboardPaste, DatabaseBackup, FolderOpen, Plus, PlugZap, RefreshCw, X } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { type LedgerBaselineSource, ledgerBaselineSources, type LedgerInfo, type LedgerKindRule, type LedgerProjectChange, type LedgerProjectSettings, type LedgerRole, ledgerRoles, type LedgerScanResult, type LedgerSettings as Settings, type LedgerStore, ledgerStore } from "@/entities/ledger";
import { LedgerConnectSheet } from "@/features/connect-ledger-mcp";
import { LedgerImportSheet, LedgerLegacyImportSheet } from "@/features/import-ledger-reports";
import { ipc } from "@/shared/api";
import { displayPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Checkbox, IconButton, Spinner } from "@/shared/ui";
import "./ledger-settings.css";

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

const roleLabels: Record<LedgerRole, string> = { decision: "Decision", implementation: "Implementation", research: "Research", document: "Document", other: "Other" };
const sourceLabels: Record<LedgerBaselineSource, string> = { tags: "Git tags", folder: "Folder names", manual: "Registered versions only" };

/** A number typed in full and saved when the field is left (or on Enter); out of range, it goes back */
function NumberField({ value, min, max, label, onCommit, onInvalid }: { value: number; min: number; max: number; label: string; onCommit: (n: number) => void; onInvalid: (text: string) => void }) {
  const [draft, setDraft] = useState(String(value));
  useEffect(() => setDraft(String(value)), [value]);
  const commit = () => {
    const n = Number(draft);
    if (draft.trim() === String(value)) return;
    if (!draft.trim() || !Number.isFinite(n) || n < min || n > max) {
      onInvalid(t("Enter a number from {0} to {1}.", min, max));
      setDraft(String(value));
    } else onCommit(n);
  };
  return <input className="input" type="number" min={min} max={max} value={draft} aria-label={label} style={{ width: 96 }} onChange={(e) => setDraft(e.target.value)} onBlur={commit} onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()} />;
}

/** Text saved when the field is left (or on Enter); empty saves null */
function TextField({ value, label, placeholder, mono, onCommit }: { value: string; label: string; placeholder?: string; mono?: boolean; onCommit: (text: string | null) => void }) {
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  return <input className={`input grow${mono ? " mono" : ""}`} value={draft} aria-label={label} placeholder={placeholder} spellCheck={false} onChange={(e) => setDraft(e.target.value)} onBlur={() => draft.trim() !== value && onCommit(draft.trim() || null)} onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()} />;
}

/**
 * Settings › Ledger, shown with the Ledger preview only: how long a session may stay quiet, what each kind of session
 * means to the rules, where each project's baselines come from, backups, and the ways reports get in. The values live
 * in the ledger database, so the CLI, its MCP server and the hooks follow them too. Track agents I start, auto-continue
 * and notifications come with their own work. (macOS: Views/Settings/LedgerSettings.swift)
 */
export function LedgerSettings({ ledger }: { ledger?: LedgerStore }) {
  const store = useObserve(ledger ?? ledgerStore(null));
  const [info, setInfo] = useState<LedgerInfo | null>(null);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [projects, setProjects] = useState<LedgerProjectSettings[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [backup, setBackup] = useState<string | null>(null);
  const [sheet, setSheet] = useState<"connect" | "import" | "legacy" | null>(null);
  const load = useCallback(async () => {
    try {
      const [i, s, p] = await Promise.all([store.info(), store.readSettings(), store.readProjects()]);
      setInfo(i);
      setSettings(s);
      setProjects(p);
      setError(null);
    } catch (e) {
      setError(message(e));
    }
    if (!store.state) void store.refresh(true);
  }, [store]);
  useEffect(() => {
    void load();
  }, [load]);
  const run = async (work: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await work();
    } catch (e) {
      setError(message(e));
    } finally {
      setBusy(false);
    }
  };
  const save = (values: Parameters<LedgerStore["saveSettings"]>[0]) => run(async () => setSettings(await store.saveSettings(values)));
  const saveProject = (change: LedgerProjectChange) => run(async () => {
    const project = await store.saveProject(change);
    setProjects((list) => list.map((p) => (p.key === project.key ? project : p)));
  });
  const backUp = () => run(async () => setBackup((await store.backup()).path));
  // a kind sessions use that has no rule counts as other until a person gives it one
  const used = [...new Set(store.state?.sessions.map((s) => s.kind) ?? [])].filter((kind) => settings && !settings.kinds[kind]).sort();

  if (!settings) {
    return (
      <div className="col" style={{ gap: 10 }}>
        {error ? <span role="alert" className="error-text">{t("The Ledger could not be read")}: {error}</span> : <Spinner size={14} />}
        {error && <div className="row"><Button size="small" onClick={() => void load()}>{t("Try again")}</Button></div>}
      </div>
    );
  }
  return (
    <div className="col ledger-settings" style={{ gap: 14 }}>
      <span className="hint">{t("The Ledger keeps agent sessions in one database on this PC. Its settings live there too, so the CLI, its MCP server and the hooks follow them.")}</span>
      {info && (
        <div className="form-row">
          <label>{t("Database")}</label>
          <div className="row">
            <span className="ellipsis grow mono" style={{ fontSize: 11.5 }} data-tip={info.dbPath}>{info.dbPath === "demo" ? t("Demo data") : displayPath(info.dbPath)}</span>
            {info.dbPath !== "demo" && <IconButton small icon={<FolderOpen size={14} />} tip={t("Show in Explorer")} aria-label={t("Show in Explorer")} onClick={() => void ipc.reveal(info.dbPath)} />}
          </div>
        </div>
      )}
      {error && <span role="alert" className="error-text">{error}</span>}

      <div className="form-section">
        <span className="form-section-title">{t("Stale sessions")}</span>
        <div className="form-row">
          <label>{t("Stale after")}</label>
          <div className="row">
            <NumberField value={settings.staleHours} min={1} max={10000} label={t("Stale after")} onCommit={(staleHours) => void save({ staleHours })} onInvalid={setError} />
            <span>{t("hours")}</span>
          </div>
        </div>
        <span className="hint">{t("A session no agent has reported on for this long shows as Stale, until a person marks it still active.")}</span>
      </div>

      <KindsSection kinds={settings.kinds} used={used} disabled={busy} onSave={(kinds) => void save({ kinds })} onRestore={() => void save({ kinds: null })} />

      <div className="form-section">
        <span className="form-section-title">{t("Projects")}</span>
        {projects.length ? projects.map((p) => <ProjectSettings key={p.key} project={p} store={store} disabled={busy} onSave={saveProject} onError={setError} />) : <span className="hint">{t("Projects appear here with their first report.")}</span>}
      </div>

      <div className="form-section">
        <span className="form-section-title">{t("Backups")}</span>
        <div className="form-row">
          <label>{t("Backups to keep")}</label>
          <NumberField value={settings.backupKeep} min={1} max={365} label={t("Backups to keep")} onCommit={(backupKeep) => void save({ backupKeep })} onInvalid={setError} />
        </div>
        <div className="row">
          <Button size="small" disabled={busy} onClick={() => void backUp()}><DatabaseBackup size={13} />{t("Back up now")}</Button>
          {info && info.dbPath !== "demo" && <Button size="small" onClick={() => void ipc.reveal(backup ?? info.dbPath)}><FolderOpen size={13} />{t("Show in Explorer")}</Button>}
          {busy && <Spinner size={12} />}
        </div>
        {backup && <span className="hint ellipsis" role="status" data-tip={backup}>{t("Backed up to {0}", displayPath(backup))}</span>}
      </div>

      <div className="form-section">
        <span className="form-section-title">{t("Connect and import")}</span>
        <div className="row" style={{ flexWrap: "wrap" }}>
          <Button size="small" onClick={() => setSheet("connect")}><PlugZap size={13} />{t("Connect Claude Code…")}</Button>
          <Button size="small" onClick={() => setSheet("import")}><ClipboardPaste size={13} />{t("Import…")}</Button>
          <Button size="small" onClick={() => setSheet("legacy")}><DatabaseBackup size={13} />{t("Import from claude-ledger…")}</Button>
        </div>
      </div>

      {sheet === "connect" && <LedgerConnectSheet store={store} onClose={() => setSheet(null)} />}
      {sheet === "import" && <LedgerImportSheet store={store} onClose={() => setSheet(null)} onImportLegacy={() => setSheet("legacy")} />}
      {sheet === "legacy" && <LedgerLegacyImportSheet store={store} onClose={() => { setSheet(null); void load(); }} />}
    </div>
  );
}

/** Kind → role, and for implementation kinds the stream line and whether it hands off; saved as a whole */
function KindsSection({ kinds, used, disabled, onSave, onRestore }: { kinds: Record<string, LedgerKindRule>; used: string[]; disabled: boolean; onSave: (kinds: Record<string, LedgerKindRule>) => void; onRestore: () => void }) {
  const [name, setName] = useState("");
  const [role, setRole] = useState<LedgerRole>("other");
  const put = (kind: string, rule: LedgerKindRule) => onSave({ ...kinds, [kind]: rule.role === "implementation" ? { role: rule.role, line: rule.line?.trim() || "core", handoff: rule.handoff !== false } : { role: rule.role } });
  const remove = (kind: string) => {
    const next = { ...kinds };
    delete next[kind];
    onSave(next);
  };
  const add = (kind: string, as: LedgerRole) => {
    if (!kind.trim() || kinds[kind.trim()]) return;
    put(kind.trim(), { role: as });
    setName("");
  };
  const roleSelect = (value: LedgerRole, onChange: (role: LedgerRole) => void, label: string) => (
    <select className="select" value={value} aria-label={label} disabled={disabled} onChange={(e) => onChange(e.target.value as LedgerRole)}>
      {ledgerRoles.map((r) => <option key={r} value={r}>{t(roleLabels[r])}</option>)}
    </select>
  );
  return (
    <div className="form-section">
      <span className="form-section-title">{t("Roles and stream lines")}</span>
      <span className="hint">{t("Each kind of session has a role. Implementation kinds report in cycles on a stream line; a line that hands off confirms the decision sessions whose baselines it applies.")}</span>
      <div className="ledger-kinds" role="table" aria-label={t("Roles and stream lines")}>
        <div className="ledger-kind head" role="row">
          <span role="columnheader">{t("Kind")}</span>
          <span role="columnheader">{t("Role")}</span>
          <span role="columnheader">{t("Stream line")}</span>
          <span role="columnheader">{t("Hands off")}</span>
          <span />
        </div>
        {Object.keys(kinds).sort().map((kind) => {
          const rule = kinds[kind], implementation = rule.role === "implementation";
          return (
            <div key={kind} className="ledger-kind" role="row" data-kind={kind}>
              <span className="mono ellipsis" role="cell">{kind}</span>
              {roleSelect(rule.role, (r) => put(kind, { ...rule, role: r }), `${t("Role")} · ${kind}`)}
              {implementation ? <TextField value={rule.line ?? "core"} label={`${t("Stream line")} · ${kind}`} mono onCommit={(line) => put(kind, { ...rule, line: line ?? "core" })} /> : <span className="faint" role="cell">—</span>}
              {implementation ? <input type="checkbox" checked={rule.handoff !== false} disabled={disabled} aria-label={`${t("Hands off")} · ${kind}`} style={{ accentColor: "var(--accent)", justifySelf: "start" }} onChange={(e) => put(kind, { ...rule, handoff: e.target.checked })} /> : <span className="faint" role="cell">—</span>}
              <IconButton small icon={<X size={13} />} tip={t("Remove")} aria-label={`${t("Remove")} · ${kind}`} disabled={disabled} onClick={() => remove(kind)} />
            </div>
          );
        })}
        <div className="ledger-kind" role="row">
          <input className="input mono" value={name} placeholder={t("New kind")} aria-label={t("New kind")} spellCheck={false} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add(name, role)} />
          {roleSelect(role, setRole, `${t("Role")} · ${t("New kind")}`)}
          <span />
          <span />
          <IconButton small icon={<Plus size={13} />} tip={t("Add kind")} aria-label={t("Add kind")} disabled={disabled || !name.trim() || !!kinds[name.trim()]} onClick={() => add(name, role)} />
        </div>
      </div>
      {used.length > 0 && (
        <div className="row" style={{ flexWrap: "wrap", gap: 6 }}>
          <span className="hint">{t("Used by sessions without a rule, so they count as Other:")}</span>
          {used.map((kind) => (
            <Button key={kind} size="small" disabled={disabled} tip={t("Add kind")} onClick={() => add(kind, "other")}>
              <Plus size={12} />
              <span className="mono">{kind}</span>
            </Button>
          ))}
        </div>
      )}
      <div className="row">
        <Button size="small" disabled={disabled} onClick={onRestore}>{t("Restore defaults")}</Button>
      </div>
    </div>
  );
}

/** One project: its name, the repository whose tags are its baselines, or the folder whose names are; and a scan */
function ProjectSettings({ project: p, store, disabled, onSave, onError }: { project: LedgerProjectSettings; store: LedgerStore; disabled: boolean; onSave: (change: LedgerProjectChange) => Promise<void>; onError: (text: string) => void }) {
  const [scan, setScan] = useState<LedgerScanResult | null>(null);
  const [scanning, setScanning] = useState(false);
  const change = (fields: Omit<LedgerProjectChange, "project">) => {
    setScan(null);
    void onSave({ project: p.key, ...fields });
  };
  const browse = async (field: "repoPath" | "baselineDir", title: string) => {
    const picked = await ipc.pickFolder(title, field === "repoPath" ? p.repoPath : p.baselineDir);
    if (picked) change({ [field]: picked });
  };
  const scanNow = async () => {
    setScanning(true);
    try {
      setScan(await store.scan(p.key));
    } catch (e) {
      onError(message(e));
    } finally {
      setScanning(false);
    }
  };
  const folder = p.baselineSource === "folder";
  return (
    <div className="col ledger-project" style={{ gap: 8 }} data-project={p.key}>
      <span className="mono" style={{ fontWeight: 600 }}>{p.key}</span>
      <div className="form-row">
        <label>{t("Name")}</label>
        <TextField value={p.name} label={`${t("Name")} · ${p.key}`} onCommit={(name) => change({ name })} />
      </div>
      <div className="form-row">
        <label>{t("Repository")}</label>
        <div className="row">
          <TextField value={p.repoPath ?? ""} label={`${t("Repository")} · ${p.key}`} mono onCommit={(repoPath) => change({ repoPath })} />
          <Button size="small" disabled={disabled} onClick={() => void browse("repoPath", t("Repository"))}>{t("Browse…")}</Button>
        </div>
      </div>
      <div className="form-row">
        <label>{t("Baselines from")}</label>
        <select className="select" value={p.baselineSource} aria-label={`${t("Baselines from")} · ${p.key}`} disabled={disabled} onChange={(e) => change({ baselineSource: e.target.value as LedgerBaselineSource })}>
          {ledgerBaselineSources.map((s) => <option key={s} value={s}>{t(sourceLabels[s])}</option>)}
        </select>
      </div>
      {p.baselineSource !== "manual" && (
        <div className="form-row">
          <label>{t("Version pattern")}</label>
          <TextField value={p.baselinePattern} label={`${t("Version pattern")} · ${p.key}`} mono onCommit={(baselinePattern) => change({ baselinePattern })} />
        </div>
      )}
      {folder && (
        <>
          <div className="form-row">
            <label>{t("Folder")}</label>
            <div className="row">
              <TextField value={p.baselineDir ?? ""} label={`${t("Folder")} · ${p.key}`} mono onCommit={(baselineDir) => change({ baselineDir })} />
              <Button size="small" disabled={disabled} onClick={() => void browse("baselineDir", t("Folder"))}>{t("Browse…")}</Button>
            </div>
          </div>
          <div className="form-row">
            <label>{t("Sub-folders")}</label>
            <TextField value={p.scanSubdirs.join(", ")} label={`${t("Sub-folders")} · ${p.key}`} placeholder="specs, releases" onCommit={(text) => change({ scanSubdirs: (text ?? "").split(",").map((s) => s.trim()).filter(Boolean) })} />
          </div>
          <Checkbox checked={p.scanFiles} onChange={(scanFiles) => change({ scanFiles })} label={t("Also read file names")} />
        </>
      )}
      <span className="hint">{p.baselineSource === "manual" ? t("Only versions an agent releases or a person registers count as baselines.") : t("The first group of the pattern is the version; without a group, the whole match.")}</span>
      {p.baselineSource !== "manual" && (
        <div className="row">
          <Button size="small" disabled={disabled || scanning} onClick={() => void scanNow()}>{scanning ? <Spinner size={11} /> : <RefreshCw size={13} />}{t("Scan now")}</Button>
          {scan && <span className={scan.error ? "error-text" : "hint"} role="status">{scan.error ?? t("Versions found: {0} · new: {1}", scan.found, scan.added)}</span>}
        </div>
      )}
    </div>
  );
}
