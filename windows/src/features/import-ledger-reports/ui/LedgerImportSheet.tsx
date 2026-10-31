import { CircleCheck, CircleX, Equal } from "lucide-react";
import { useState } from "react";
import { countReports, type ImportSummary, type LedgerStore } from "@/entities/ledger";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Modal, Spinner } from "@/shared/ui";
import "./ledger-import-sheet.css";

/**
 * Paste reports: agents that cannot reach the Ledger (a web chat, another computer) end their answer with report
 * blocks, and a person pastes them here. Each report is imported on its own and gets its own line in the result:
 * imported, already imported, or the reason it failed. (macOS: Views/Ledger/LedgerImportSheet.swift)
 */
export function LedgerImportSheet({ store, onClose, onOpenSession }: { store: LedgerStore; onClose: () => void; onOpenSession: (id: string) => void }) {
  const [text, setText] = useState("");
  const [working, setWorking] = useState(false);
  const [summary, setSummary] = useState<ImportSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const reports = countReports(text);
  const project = store.project ? store.state?.projects.find((p) => p.key === store.project)?.name ?? store.project : null;
  const run = async () => {
    if (!reports || working) return;
    setWorking(true);
    setError(null);
    try {
      const result = await store.importReports(text);
      setSummary(result);
      if (!result.failed) setText("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setWorking(false);
    }
  };
  return (
    <Modal
      title={t("Paste reports")}
      width={640}
      onClose={onClose}
      footer={
        <>
          <span className="hint">{project ? t("New sessions go to {0} unless a report names its project.", project) : t("Reports that start a session must name their project.")}</span>
          <span className="spacer" />
          <Button onClick={onClose}>{t("Close")}</Button>
          <Button kind="primary" disabled={!reports || working} onClick={() => void run()} tip={`${t("Import")}||Ctrl+Enter`}>
            {working && <Spinner size={11} />}
            {reports > 1 ? t("Import {0} reports", reports) : t("Import")}
          </Button>
        </>
      }
    >
      <span>{t("Paste the end of a conversation. Every ```ledger block, or every line of JSON with an \"event\", becomes one report.")}</span>
      <textarea
        className="textarea mono"
        rows={10}
        value={text}
        autoFocus
        aria-label={t("Reports to import")}
        placeholder={'```ledger\n{"event": "start", "project": "…", "title": "…"}\n```'}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            void run();
          }
        }}
      />
      <span className="hint">{t("{0} imports · Importing the same report twice is recognised and skipped.", keyLabel("Ctrl+Enter"))}</span>
      {error && <span role="alert" className="error-text">{error}</span>}
      {summary && (
        <div className="col" style={{ gap: 6 }} aria-live="polite">
          <strong>{t("{0} imported · {1} already imported · {2} failed", summary.imported, summary.duplicates, summary.failed)}</strong>
          <div className="ledger-results">
            {summary.lines.map((line) => (
              <div key={line.number} className="ledger-result">
                {line.outcome === "imported" ? <CircleCheck size={14} className="ok" /> : line.outcome === "duplicate" ? <Equal size={14} className="dup" /> : <CircleX size={14} className="bad" />}
                <span className="mono faint">#{line.number}</span>
                <span className="grow ellipsis">{line.outcome === "imported" ? t("Imported") : line.outcome === "duplicate" ? t("Already imported") : line.error}</span>
                {line.sessionId && (
                  <button type="button" className="link mono" onClick={() => onOpenSession(line.sessionId!)}>
                    {line.sessionId}
                  </button>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
    </Modal>
  );
}
