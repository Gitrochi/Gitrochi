import { Copy } from "lucide-react";
import { useState } from "react";
import type { LedgerInfo, LedgerStore } from "@/entities/ledger";
import { env, isWindows, joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, IconButton, Modal, Spinner } from "@/shared/ui";
import { type LedgerClient, ledgerSetup } from "../lib/setup";
import { LedgerConnections } from "./LedgerConnections";
import "./ledger-connect-sheet.css";

/** The bundled Ledger binary; agents talk to it over MCP (stdio) */
function ledgerBinary() {
  const name = isWindows() ? "gitrochi-ledger.exe" : "gitrochi-ledger";
  const path = env.resourceDir ? joinPath(env.resourceDir, name) : name;
  return isWindows() ? path.replace(/\//g, "\\") : path;
}

function CopyBlock({ text, label, copyLabel, onCopied }: { text: string; label: string; copyLabel?: string; onCopied: (ok: boolean) => void }) {
  return (
    <div className="ledger-connect-code">
      <div className="ledger-code-head"><span>{label}</span><IconButton small icon={<Copy size={14} />} tip={copyLabel ?? t("Copy")} aria-label={copyLabel ?? `${t("Copy")} · ${label}`} onClick={() => void navigator.clipboard.writeText(text).then(() => onCopied(true), () => onCopied(false))} /></div>
      <div className="ledger-code"><pre aria-label={label}>{text}</pre></div>
    </div>
  );
}

/**
 * Connect local agents with separate commands for MCP reports and passive activity hooks. The backend probe checks
 * this app's Ledger; no client configuration or hook trust is changed by opening or testing the sheet.
 * (macOS: Views/Ledger/LedgerConnectSheet.swift)
 */
export function LedgerConnectSheet({ store, onClose, onOpenBrowser }: { store: LedgerStore; onClose: () => void; onOpenBrowser?: () => void }) {
  const [notice, setNotice] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<LedgerInfo | null>(null);
  const [testing, setTesting] = useState(false);
  const [client, setClient] = useState<LedgerClient>("claude");
  const binary = ledgerBinary();
  const setup = ledgerSetup(client, binary, isWindows());
  const commandLabel = (label: string) => `${t(label)}${isWindows() ? " · PowerShell" : ""}`;
  // macOS: LedgerConnectSheet.swift. The copied instruction stays in English like a project's CLAUDE.md.
  const reportingInstruction = "Use ledger_report to send a start report for this conversation and its current work. Include the project and a short title. Send progress, question and done reports as the work changes.";
  const copied = (ok: boolean) => (ok ? (setNotice(t("Copied")), setError(null)) : setError(t("Could not copy to the clipboard.")));
  const test = async () => {
    setTesting(true);
    setError(null);
    setNotice("");
    try {
      setInfo(await store.info());
    } catch (e) {
      setInfo(null);
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setTesting(false);
    }
  };
  return (
    <Modal
      title={t("Connect agents")}
      width={680}
      onClose={onClose}
      footer={
        <>
          <Button disabled={testing} onClick={() => void test()}>
            {testing && <Spinner size={11} />}
            {t("Test Ledger")}
          </Button>
          <span className="spacer" />
          <Button kind="primary" onClick={onClose}>{t("Done")}</Button>
        </>
      }
    >
      <strong>{t("Connections")}</strong>
      <LedgerConnections store={store} onOpenBrowser={onOpenBrowser ?? (() => {})} />
      <label className="ledger-connect-client"><span>{t("Agent")}</span><select className="select" aria-label={t("Agent")} value={client} onChange={(e) => { setClient(e.target.value as LedgerClient); setNotice(""); }}><option value="claude">Claude Code</option><option value="codex">Codex</option></select></label>
      {client === "codex" && <span className="hint">{t("Codex CLI and local Desktop tasks share this setup. Cloud-orchestrated tasks do not run these hooks; they appear only when the agent sends Ledger reports.")}</span>}
      <strong>{t("Ledger reports")}</strong>
      <span>{t("Register the Ledger tools by running this command in a terminal.")}</span>
      <CopyBlock text={setup.register} label={commandLabel("MCP registration command")} onCopied={copied} />
      <span className="hint">{t("Registration makes the tools available. It does not import existing conversations or make agents report automatically.")}</span>
      <span>{t("Start a new conversation, then ask the agent to send a start report with ledger_report.")}</span>
      <CopyBlock text={reportingInstruction} label={t("Reporting instruction")} copyLabel={t("Copy reporting instruction")} onCopied={copied} />
      <details>
        <summary>{t("MCP settings entry")}</summary>
        <CopyBlock text={setup.config} label={t("MCP settings entry")} onCopied={copied} />
      </details>
      <strong>{t("Automatic activity")}</strong>
      <span>{t("Install activity hooks for this agent. Existing hooks are kept. MCP registration is separate.")}</span>
      <CopyBlock text={setup.install} label={commandLabel("Activity setup command")} onCopied={copied} />
      <span className="hint">{t("Activity records do not mark work complete. Task details still come from the agent's reports.")}</span>
      {client === "codex" && <span className="hint">{t("After installing, open /hooks in Codex and review and trust the Ledger hooks. Installation does not trust them.")}</span>}
      <details>
        <summary>{t("Check or remove automatic activity")}</summary>
        <CopyBlock text={setup.status} label={commandLabel("Status")} onCopied={copied} />
        <span className="hint">{t("Setup status checks configuration only, not whether hooks are trusted or running.")}</span>
        <CopyBlock text={setup.remove} label={commandLabel("Remove")} onCopied={copied} />
      </details>
      <span className="hint">{t("To track new Claude Code agents launched from Gitrochi automatically, turn on Settings > Ledger > Track agents I start. It is off by default.")}</span>
      <span className="hint">{t("Set up, Repair and Remove change only Gitrochi's own entries in that client's hook settings and keep a backup first. MCP commands are only shown for you to copy.")}</span>
      <span className="hint">{t("Checks this app's Ledger, not agent configuration or hook trust.")}</span>
      {info && (
        <div className="card" role="status" style={{ gap: 4 }}>
          <strong>{info.enabled ? t("The Ledger responds.") : t("The Ledger is turned off.")}</strong>
          <span className="hint">{t("Connecting tools alone creates no session. Send a first report to see this conversation here.")}</span>
          <span className="hint">{t("Find progress in Board and Streams. Inbox only shows questions, reviews and decisions that need you.")}</span>
          <span className="hint">{info.dbPath === "demo" ? t("Example sessions from GITROCHI_LEDGER_DEMO; nothing is written to the ledger database.") : t("Database: {0}", info.dbPath)}</span>
          <span className="hint">{t("Schema {0} · revision {1}", info.schemaVersion, info.rev)}</span>
        </div>
      )}
      {notice && <span role="status" className="hint">{notice}</span>}
      {error && <span role="alert" className="error-text">{error}</span>}
    </Modal>
  );
}
