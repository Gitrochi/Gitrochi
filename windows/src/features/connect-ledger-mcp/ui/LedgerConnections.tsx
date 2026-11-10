import { CircleDashed, Code, Wrench } from "lucide-react";
import { CircleCheck, CircleX, Globe } from "@/shared/icons";
import { Clock, SquareTerminal } from "@/shared/icons";
import { type ReactNode, useCallback, useEffect, useState } from "react";
import type { LedgerBrowserStatus, LedgerIntegrationStatus, LedgerStableCommand, LedgerStore } from "@/entities/ledger";
import { isWindows } from "@/shared/config";
import { t } from "@/shared/i18n";
import { shortDate } from "@/shared/lib";
import { tools } from "@/shared/platform";
import { Button, Spinner, StatusPill } from "@/shared/ui";
import { agentConnection, browserConnection, type ConnectionAction, type ConnectionLook, mcpCommand } from "../lib/connections";
import "./ledger-connections.css";

type Client = LedgerIntegrationStatus["client"];
const clients: { id: Client; title: string; icon: ReactNode }[] = [
  { id: "claude", title: "Claude Code", icon: <SquareTerminal size={14} /> },
  { id: "codex", title: "Codex", icon: <Code size={14} /> },
];

function Pill({ look }: { look: ConnectionLook }) {
  switch (look.state) {
    case "not_set_up": return <StatusPill tone="neutral" icon={<CircleDashed />}>{t("Not set up")}</StatusPill>;
    case "connected": return <StatusPill tone="passed" icon={<CircleCheck />}>{look.lastDataAt ? t("Connected · last data {0}", shortDate(look.lastDataAt / 1000)) : t("Connected")}</StatusPill>;
    case "no_data": return <StatusPill tone="info" icon={<Clock />}>{t("Connected · no data yet")}</StatusPill>;
    case "repair": return <StatusPill tone="waiting" icon={<Wrench />}>{t("Needs repair")}</StatusPill>;
    case "missing": return <StatusPill tone="failed" icon={<CircleX />}>{t("Command missing")}</StatusPill>;
  }
}

const actionLabels: Record<ConnectionAction, [plain: string, dialog: string]> = {
  setup: ["Set up", "Set up…"],
  repair: ["Repair", "Repair…"],
  remove: ["Remove", "Remove"],
  copy: ["Copy MCP command", "Copy MCP command"],
};

function Row({ id, title, icon, look, error, detail, busy, disabled, dialogs, onAction }: { id: string; title: string; icon: ReactNode; look: ConnectionLook | null; error?: string; detail?: string; busy: boolean; disabled: boolean; dialogs?: boolean; onAction: (action: ConnectionAction) => void }) {
  return (
    <div className="ledger-connection" data-connection={id} data-state={look?.state ?? ""} data-tip={detail || undefined}>
      <span className="ledger-connection-icon" aria-hidden>{icon}</span>
      <div className="ledger-connection-text">
        <div className="ledger-connection-head"><strong>{title}</strong>{look ? <Pill look={look} /> : !error && <Spinner size={11} />}</div>
        {error ? <span role="alert" className="error-text">{error}</span> : look && <span className="hint">{t(look.explanation, title)}</span>}
      </div>
      <div className="ledger-connection-actions">
        {busy && <Spinner size={12} />}
        {look?.actions.map((action) => (
          <Button key={action} size="small" disabled={disabled} data-action={action} onClick={() => onAction(action)}>{t(actionLabels[action][dialogs ? 1 : 0])}</Button>
        ))}
      </div>
    </div>
  );
}

/**
 * Claude Code, Codex and the ChatGPT browser extension as equals: whether each one's data reaches this Ledger, and the
 * action that fixes it. Set up and Repair install hooks that run the stable ledger command and have the client register
 * its MCP server, and the command stays there to copy when it cannot. Shown in the Connect agents sheet and Settings › Ledger.
 * (macOS: Views/Ledger/LedgerConnectionsSection.swift)
 */
export function LedgerConnections({ store, onOpenBrowser }: { store: LedgerStore; onOpenBrowser: () => void }) {
  const [statuses, setStatuses] = useState<Partial<Record<Client, LedgerIntegrationStatus>>>({});
  const [browser, setBrowser] = useState<LedgerBrowserStatus | null>(null);
  const [stable, setStable] = useState<LedgerStableCommand | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [working, setWorking] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

  const load = useCallback(async (keep: Record<string, string> = {}) => {
    const next: Record<string, string> = { ...keep };
    setStable(await store.stableCommand().catch(() => null));
    const read = await Promise.all(clients.map(({ id }) => store.integrationStatus(id).then((s) => [id, s] as const, (e: unknown) => { next[id] ??= message(e); return null; })));
    setStatuses(Object.fromEntries(read.filter((r) => r !== null)));
    setBrowser(await store.backend.call("browser_status", {}).catch((e: unknown) => { next.browser ??= message(e); return null; }));
    setErrors(next);
  }, [store]);
  useEffect(() => void load(), [load]);

  /** One action at a time; afterwards everything is read again, since a repair can change more than its own row */
  const run = async (key: string, action: () => Promise<void>) => {
    if (working) return;
    setWorking(key);
    setNotice("");
    const failed: Record<string, string> = {};
    try {
      await action();
    } catch (e) {
      failed[key] = message(e);
    }
    setWorking(null);
    await load(failed);
  };
  const copyMcp = async (client: Client, registered: boolean) => {
    if (!stable?.path) return;
    await navigator.clipboard.writeText(mcpCommand(client, stable.path, registered, isWindows()));
    setNotice(t("Copied. Run it in a terminal to register the Ledger tools."));
  };
  const agentAction = (client: Client, look: ConnectionLook, status: LedgerIntegrationStatus, action: ConnectionAction) => {
    if (action === "copy") return void copyMcp(client, status.mcp.registered).catch(() => setNotice(t("Could not copy to the clipboard.")));
    const hooks = status.ownedHookCount > 0;
    const tool = tools.command(client);
    const program = tool?.kind === "native" ? tool.exe : null;
    void run(client, async () => {
      if (action === "remove") {
        if (hooks) await store.removeIntegration(client);
        if (status.mcp.registered) await store.removeMcp(client, program);
        return;
      }
      // Repairing only the MCP entry adds no hooks a person did not choose
      if (action === "setup" || hooks || !look.repairsMcp) await store.installIntegration(client);
      await store.registerMcp(client, program).catch((e: unknown) => {
        throw new Error(t("The Ledger tools were not registered: {0} Copy the MCP command and run it.", message(e)));
      });
    });
  };

  return (
    <div className="ledger-connections" data-ledger-connections>
      {clients.map(({ id, title, icon }) => {
        const status = statuses[id];
        const look = status ? agentConnection(status, !!stable?.exists) : null;
        const detail = [...new Set([status?.hookCommand?.path, status?.mcp.command?.path].filter(Boolean))].join("\n");
        return <Row key={id} id={id} title={title} icon={icon} look={look} error={errors[id]} detail={detail} busy={working === id} disabled={!!working} onAction={(action) => status && look && agentAction(id, look, status, action)} />;
      })}
      <Row
        id="browser"
        title={t("ChatGPT browser extension")}
        icon={<Globe size={14} />}
        look={browser ? browserConnection(browser) : null}
        error={errors.browser}
        detail={browser?.hostPath}
        busy={working === "browser"}
        disabled={!!working}
        dialogs
        onAction={(action) => (action === "remove" ? void run("browser", async () => void (await store.backend.call("browser_remove", {}))) : onOpenBrowser())}
      />
      {notice && <span role="status" className="hint">{notice}</span>}
    </div>
  );
}
