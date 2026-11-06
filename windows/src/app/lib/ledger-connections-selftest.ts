import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { t } from "@/shared/i18n";

const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
async function until(test: () => unknown) {
  const end = Date.now() + 4000;
  while (Date.now() < end) { if (test()) return true; await new Promise((resolve) => setTimeout(resolve, 25)); }
  return !!test();
}

/** Claude Code, Codex and the browser extension as equal rows; reading changes nothing, Set up, Repair and Remove are explicit and finish the job. */
export async function ledgerConnectionsSelfTest(): Promise<[boolean, string]> {
  const [{ DemoLedgerBackend, LedgerStore }, { LedgerConnections }, { LedgerWorkspace }] = await Promise.all([import("@/entities/ledger"), import("@/features/connect-ledger-mcp"), import("@/widgets/ledger-workspace")]);
  const backend = new DemoLedgerBackend({ now: () => Date.now() });
  const call = backend.call.bind(backend), calls: string[] = [];
  let noClient = false;
  backend.call = async (method, args) => { if (noClient && method === "integration_mcp") throw new Error("The Claude Code command was not found."); calls.push(method === "integration_command" && (args as { create?: boolean }).create ? "integration_command:create" : method); return call(method, args); };
  const store = new LedgerStore(backend);
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:900px;height:900px";
  document.body.append(host);
  const root = createRoot(host);
  const row = (id: string) => host.querySelector<HTMLElement>(`[data-connection="${id}"]`);
  const action = (id: string, name: string) => row(id)?.querySelector<HTMLButtonElement>(`button[data-action="${name}"]`);
  let browserOpened = 0;
  try {
    root.render(createElement(LedgerConnections, { store, onOpenBrowser: () => browserOpened++ }));
    ensure(await until(() => row("claude")?.dataset.state && row("codex")?.dataset.state && row("browser")?.dataset.state), "The three connection rows did not load");
    ensure(row("claude")!.dataset.state === "connected" && row("claude")!.querySelector('.status-pill[data-tone="passed"]'), "Claude Code did not show when its data last arrived");
    ensure(row("codex")!.dataset.state === "repair" && row("codex")!.textContent?.includes(t("Needs repair")), "An outdated Codex command did not ask for repair");
    ensure(row("browser")!.dataset.state === "not_set_up", "The browser extension is not set up in the demo");
    ensure(!calls.some((m) => m === "integration_install" || m === "integration_remove" || m === "integration_mcp" || m === "integration_command:create" || m === "browser_remove"), "Reading connections must not change anything");
    action("codex", "repair")!.click();
    ensure(await until(() => row("codex")?.dataset.state === "no_data"), "Repair did not reinstall the Codex hooks");
    ensure(row("codex")!.textContent?.includes("/hooks"), "Codex must say that its hooks need trust after installing");
    ensure(calls.filter((m) => m === "integration_install").length === 1 && calls.filter((m) => m === "integration_mcp").length === 1, "Repair installs and registers once");
    // A client that cannot register leaves the hooks, says why, and the command stays there to copy
    ensure(row("claude")!.textContent?.includes(t("Activity reaches this Ledger, but agents cannot report yet. Set up registers the Ledger tools.")), "Hooks alone must not promise reports");
    noClient = true;
    action("claude", "setup")!.click();
    ensure(await until(() => row("claude")?.querySelector('[role="alert"]')?.textContent?.includes("The Claude Code command was not found.")), "A failed registration did not say why");
    ensure(action("claude", "copy") && action("claude", "setup"), "A failed registration must leave Copy MCP command and Set up");
    noClient = false;
    action("claude", "setup")!.click();
    ensure(await until(() => row("claude")?.textContent?.includes(t("Activity and reports reach this Ledger."))), "Set up did not register the Ledger tools");
    ensure(!action("claude", "setup") && !row("claude")!.querySelector('[role="alert"]'), "A complete connection has nothing left to set up");
    action("claude", "remove")!.click();
    ensure(await until(() => row("claude")?.dataset.state === "not_set_up"), "Remove did not remove the Claude Code hooks and tools");
    ensure(action("claude", "setup"), "A removed connection offers Set up");
    action("browser", "setup")!.click();
    ensure(browserOpened === 1 && !calls.includes("browser_install"), "Browser setup opens its own confirmation instead of installing");

    root.render(createElement(LedgerWorkspace, { repoPath: null, ledger: store }));
    ensure(await until(() => host.querySelector("[data-connect-claude]")), "The Ledger toolbar has no Claude Code entry");
    ensure(host.querySelector("[data-chatgpt-browser]"), "The existing ChatGPT entry must stay");
    return [true, "Connections rows for Claude Code, Codex and the browser extension: read-only status, explicit setup and its failure, repair and removal, toolbar entry"];
  } catch (cause) { return [false, cause instanceof Error ? cause.message : String(cause)]; }
  finally { root.unmount(); host.remove(); store.stop(); }
}
