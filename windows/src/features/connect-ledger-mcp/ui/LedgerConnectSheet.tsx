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

function CopyBlock({ text, label, onCopied }: { text: string; label: string; onCopied: (ok: boolean) => void }) {
  return (
    <div className="ledger-code">
      <pre aria-label={label}>{text}</pre>
      <IconButton small icon={<Copy size={14} />} tip={t("Copy")} aria-label={`${t("Copy")} · ${label}`} onClick={() => void navigator.clipboard.writeText(text).then(() => onCopied(true), () => onCopied(false))} />
    </div>
  );
}

/**
 * Connect Claude Code: the command that registers the Ledger's MCP server with Claude Code, the same entry for other
 * MCP clients, and a connection test. It never edits a client's settings; the person runs or pastes them.
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
            {t("Test connection")}
          </Button>
          <span className="spacer" />
          <Button kind="primary" onClick={onClose}>{t("Done")}</Button>
        </>
      }
    >
      <span>{t("Agents report their sessions to the Ledger through its MCP server. Run this once in a terminal to add it to Claude Code for every project:")}</span>
      <CopyBlock text={command} label={t("Command for Claude Code")} onCopied={copied} />
      <span className="hint">{t("Other MCP clients: add this entry to their MCP settings.")}</span>
      <CopyBlock text={config} label={t("MCP settings entry")} onCopied={copied} />
      <span className="hint">{t("Gitrochi does not change any client's settings. Agents you start from Gitrochi will be connected for you.")}</span>
      {info && (
        <div className="card" role="status" style={{ gap: 4 }}>
          <strong>{info.enabled ? t("The Ledger answers.") : t("The Ledger is turned off.")}</strong>
          <span className="hint">{info.dbPath === "demo" ? t("Example sessions from GITROCHI_LEDGER_DEMO; nothing is written to the ledger database.") : t("Database: {0}", info.dbPath)}</span>
          <span className="hint">{t("Schema {0} · revision {1}", info.schemaVersion, info.rev)}</span>
        </div>
      )}
      {notice && <span role="status" className="hint">{notice}</span>}
      {error && <span role="alert" className="error-text">{error}</span>}
    </Modal>
  );
}
