import { Copy } from "lucide-react";
import { useState } from "react";
import type { LedgerInfo, LedgerStore } from "@/entities/ledger";
import { env, isWindows, joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, IconButton, Modal, Spinner } from "@/shared/ui";
import "./ledger-connect-sheet.css";

/** The bundled Ledger binary; agents talk to it over MCP (stdio) */
function ledgerBinary() {
  const name = isWindows() ? "gitrochi-ledger.exe" : "gitrochi-ledger";
  const path = env.resourceDir ? joinPath(env.resourceDir, name) : name;
  return isWindows() ? path.replace(/\//g, "\\") : path;
}

function CopyBlock({ text, label, copyLabel, onCopied }: { text: string; label: string; copyLabel?: string; onCopied: (ok: boolean) => void }) {
  return (
    <div className="ledger-code">
      <pre aria-label={label}>{text}</pre>
      <IconButton small icon={<Copy size={14} />} tip={copyLabel ?? t("Copy")} aria-label={copyLabel ?? `${t("Copy")} · ${label}`} onClick={() => void navigator.clipboard.writeText(text).then(() => onCopied(true), () => onCopied(false))} />
    </div>
  );
}

/**
 * Connect Claude Code: the command that registers the Ledger's MCP server with Claude Code, the same entry for other
 * MCP clients, and a probe of this app's Ledger. It never edits a client's settings; the person runs or pastes them.
 * (macOS: Views/Ledger/LedgerConnectSheet.swift)
 */
export function LedgerConnectSheet({ store, onClose }: { store: LedgerStore; onClose: () => void }) {
  const [notice, setNotice] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<LedgerInfo | null>(null);
  const [testing, setTesting] = useState(false);
  const binary = ledgerBinary();
  const command = `claude mcp add --scope user gitrochi-ledger -- "${binary}" mcp`;
  const config = JSON.stringify({ mcpServers: { "gitrochi-ledger": { command: binary, args: ["mcp"] } } }, null, 2);
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
      title={t("Connect Claude Code")}
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
      <span>{t("Register the Ledger tools with Claude Code by running this command in a terminal.")}</span>
      <CopyBlock text={command} label={t("Command for Claude Code")} onCopied={copied} />
      <span className="hint">{t("Registration makes the tools available. It does not import existing conversations or make agents report automatically.")}</span>
      <span>{t("Start or restart a Claude Code conversation, then ask it to call ledger_report with a start report for its current work.")}</span>
      <CopyBlock text={reportingInstruction} label={t("Reporting instruction")} copyLabel={t("Copy reporting instruction")} onCopied={copied} />
      <details>
        <summary>{t("Other MCP clients: add this entry to their MCP settings.")}</summary>
        <CopyBlock text={config} label={t("MCP settings entry")} onCopied={copied} />
      </details>
      <span className="hint">{t("To track new Claude Code agents launched from Gitrochi automatically, turn on Settings > Ledger > Track agents I start. It is off by default.")}</span>
      <span className="hint">{t("Nothing is written to Claude Code's settings by Gitrochi.")}</span>
      <span className="hint">{t("Checks this app's Ledger, not Claude Code's MCP configuration.")}</span>
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
