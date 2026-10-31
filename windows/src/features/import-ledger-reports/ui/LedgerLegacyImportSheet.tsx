import { FileUp } from "lucide-react";
import { useState } from "react";
import type { LedgerLegacyImport, LedgerStore } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { displayPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Modal, Spinner } from "@/shared/ui";
import "./ledger-import-sheet.css";

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** What an import copies (or would copy), in one line */
function countsLine(r: LedgerLegacyImport) {
  const c = r.counts;
  return t("Sessions: {0} · events: {1} · questions: {2} · baselines: {3} · projects: {4}", c.sessions, c.events, c.questions, c.baselines + c.baselinesUpdated, c.projects);
}

/**
 * Import from claude-ledger: a person picks the standalone tool's database, sees what an import would copy (a dry run
 * that writes nothing), then imports. The file is only read; sessions the Ledger already has are skipped and listed.
 * (macOS: Views/Ledger/LedgerImportSheet.swift)
 */
export function LedgerLegacyImportSheet({ store, onClose }: { store: LedgerStore; onClose: () => void }) {
  const [path, setPath] = useState<string | null>(null);
  const [preview, setPreview] = useState<LedgerLegacyImport | null>(null);
  const [done, setDone] = useState<LedgerLegacyImport | null>(null);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const count = async (file: string) => {
    setPath(file);
    setPreview(null);
    setDone(null);
    setError(null);
    setWorking(true);
    try {
      setPreview(await store.importLegacy(file, true));
    } catch (e) {
      setError(message(e));
    } finally {
      setWorking(false);
    }
  };
  const choose = async () => {
    const file = await ipc.ledgerPickDatabase(t("Choose a claude-ledger database"));
    if (file) await count(file);
  };
  const run = async () => {
    if (!path || working) return;
    setWorking(true);
    setError(null);
    try {
      setDone(await store.importLegacy(path, false));
      setPreview(null);
    } catch (e) {
      setError(message(e));
    } finally {
      setWorking(false);
    }
  };
  const result = done ?? preview;
  const nothing = !!preview && !preview.counts.sessions && !preview.counts.baselines && !preview.counts.baselinesUpdated && !preview.counts.imports;
  return (
    <Modal
      title={t("Import from claude-ledger")}
      width={600}
      onClose={onClose}
      footer={
        <>
          <span className="spacer" />
          <Button onClick={onClose}>{done ? t("Done") : t("Close")}</Button>
          {!done && (
            <Button kind="primary" disabled={!preview || nothing || working} onClick={() => void run()}>
              {working && !!preview && <Spinner size={11} />}
              {t("Import")}
            </Button>
          )}
        </>
      }
    >
      <span>{t("Copies the projects, baselines, sessions and questions of a claude-ledger database into the Ledger. The file is only read, never changed.")}</span>
      <div className="row">
        <span className={`grow ellipsis mono${path ? "" : " faint"}`} data-tip={path ?? undefined}>{path ? displayPath(path) : t("No file chosen")}</span>
        <Button disabled={working} onClick={() => void choose()}>
          <FileUp size={14} />
          {t("Choose a file")}
        </Button>
      </div>
      {working && !preview && !done && (
        <span className="row hint" role="status">
          <Spinner size={11} />
          {t("Counting what an import would copy…")}
        </span>
      )}
      {result && (
        <div className="card ledger-legacy-result" role="status" style={{ gap: 4 }}>
          <strong>{done ? t("Imported") : nothing ? t("Nothing new to import.") : t("An import would copy:")}</strong>
          {!nothing && <span>{countsLine(result)}</span>}
          {result.skipped.length > 0 && <span className="hint">{t("Already in the Ledger, skipped with their history: {0}", result.skipped.join(", "))}</span>}
          {result.errors.length > 0 && (
            <>
              <span className="hint">{t("Rows that could not be read, left out: {0}", result.errors.length)}</span>
              <ul className="ledger-legacy-errors">
                {result.errors.slice(0, 5).map((e, i) => <li key={i} className="hint">{e}</li>)}
              </ul>
            </>
          )}
        </div>
      )}
      {error && <span role="alert" className="error-text">{error}</span>}
    </Modal>
  );
}
