import { Check, Copy, FileText } from "lucide-react";
import { useEffect, useState } from "react";
import { type LedgerReleaseNotes as Notes, type LedgerStore, releaseNotesSummary } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, Markdown, Modal, Segmented, Spinner } from "@/shared/ui";
import "./ledger-release-notes.css";

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/**
 * Release notes…: a Markdown draft for one baseline from the sessions merged into it or absorbed by its release, written
 * by the core from what their agents reported (never answers, messages or notebook notes). Pick the project and
 * baseline, read it, copy it. (macOS: Views/Ledger/LedgerReleaseNotesSheet.swift)
 */
export function LedgerReleaseNotes({ store: ledger, project, version, onClose }: { store: LedgerStore; project?: string | null; version?: string | null; onClose: () => void }) {
  const store = useObserve(ledger);
  const projects = store.state?.projects ?? [];
  const [chosen, setChosen] = useState(project ?? store.graphProject ?? "");
  const [wanted, setWanted] = useState<string | null>(version ?? null);
  const [notes, setNotes] = useState<Notes | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [view, setView] = useState<"preview" | "markdown">("preview");
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!chosen) return;
    let live = true;
    setLoading(true);
    setCopied(false);
    store.releaseNotes(chosen, wanted).then(
      (next) => live && (setNotes(next), setError(null)),
      (e) => live && (setNotes(null), setError(message(e))),
    ).finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [store, chosen, wanted]);
  const copy = () => {
    if (!notes) return;
    void navigator.clipboard.writeText(notes.markdown).then(() => setCopied(true), () => {});
  };
  const footer = (
    <>
      <span className="hint ledger-release-hint">{t("A draft from what agents reported. Answers, messages and notebook notes are never included.")}</span>
      <Button onClick={onClose}>{t("Close")}</Button>
      <Button kind="primary" disabled={!notes} onClick={copy} data-release-copy>{copied ? <Check size={13} /> : <Copy size={13} />}{copied ? t("Copied") : t("Copy Markdown")}</Button>
    </>
  );
  return (
    <Modal title={t("Release notes")} width={720} onClose={onClose} footer={footer}>
      <div className="ledger-release" data-ledger-release>
        <div className="ledger-release-controls">
          <select className="select" aria-label={t("Project")} value={chosen} onChange={(e) => { setChosen(e.target.value); setWanted(null); }}>
            {!projects.some((p) => p.key === chosen) && <option value={chosen}>{chosen}</option>}
            {projects.map((p) => <option key={p.key} value={p.key}>{p.name}</option>)}
          </select>
          <select className="select" aria-label={t("Baseline")} value={notes?.version ?? wanted ?? ""} disabled={!notes} onChange={(e) => setWanted(e.target.value)}>
            {(notes?.versions ?? []).map((v, i) => <option key={v} value={v}>{i === 0 ? t("{0} (HEAD)", v) : v}</option>)}
          </select>
          {loading && <Spinner size={12} />}
          <span className="spacer" />
          <Segmented value={view} onChange={setView} options={[{ value: "preview", label: t("Preview") }, { value: "markdown", label: t("Markdown") }]} />
        </div>
        {error ? (
          <div className="ledger-release-empty"><Empty icon={<FileText size={24} />} title={t("No release notes for this baseline")} detail={error} /></div>
        ) : notes ? (
          <>
            <span className="hint" role="status">{releaseNotesSummary(notes, t)}</span>
            <div className="ledger-release-body">
              {view === "markdown" ? <pre className="mono selectable">{notes.markdown}</pre> : <Markdown text={notes.markdown} />}
            </div>
          </>
        ) : !projects.length && !loading ? (
          <div className="ledger-release-empty"><Empty icon={<FileText size={24} />} title={t("No projects yet")} detail={t("Release notes are drafted from sessions merged into a baseline.")} /></div>
        ) : (
          <div className="ledger-release-empty"><Spinner size={16} /></div>
        )}
      </div>
    </Modal>
  );
}
