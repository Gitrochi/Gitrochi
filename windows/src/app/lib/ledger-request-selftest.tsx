import { createRoot } from "react-dom/client";
import type { RepoTarget } from "@/entities/git";
import { DemoLedgerBackend, LedgerStore } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { LedgerWorkspace } from "@/widgets/ledger-workspace";

const pause = (ms = 40) => new Promise<void>((resolve) => setTimeout(resolve, ms));
async function until(f: () => unknown, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (f()) return true;
    await pause(30);
  }
  return !!f();
}

/**
 * Linked requests in the Ledger on the demo backend, with a fixture server behind the repository's own hosting access:
 * the state and checks pills next to the "#…" chip, the merged suggestion in the inspector and in the Inbox's To decide
 * group opening the existing version picker without changing anything, and the chip as before without a host.
 */
export async function ledgerRequestSelfTest(): Promise<[boolean, string]> {
  const original = ipc.http;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1400px;height:900px";
  document.body.append(host);
  let root = createRoot(host);
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const calls: { method: string; url: string; token: string }[] = [];
  try {
    // #139 is open with a failing check; #142 is merged with its checks passed
    ipc.http = async (method, url, headers) => {
      calls.push({ method, url, token: headers.Authorization ?? "" });
      const pull = /\/repos\/atlas\/pulls\/(\d+)$/.exec(url);
      if (pull) return { status: 200, body: JSON.stringify(pull[1] === "142" ? { number: 142, state: "closed", merged: true, draft: false, head: { sha: "f00d142" } } : { number: Number(pull[1]), state: "open", merged: false, draft: false, head: { sha: "f00d139" } }) };
      if (url.includes("/check-runs")) return { status: 200, body: JSON.stringify({ total_count: 2, check_runs: url.includes("f00d139") ? [{ id: 1, name: "test", status: "completed", conclusion: "failure" }, { id: 2, name: "lint", status: "completed", conclusion: "success" }] : [{ id: 3, name: "test", status: "completed", conclusion: "success" }, { id: 4, name: "lint", status: "completed", conclusion: "success" }] }) };
      if (url.includes("/status")) return { status: 200, body: JSON.stringify({ total_count: 0, statuses: [] }) };
      return { status: 404, body: "{}" };
    };
    const clock = Date.UTC(2026, 9, 31, 9);
    const store = new LedgerStore(new DemoLedgerBackend({ now: () => clock, repoPath: "C:/fixture/atlas" }));
    await store.refresh(true);
    const session = (title: string) => store.state!.sessions.find((s) => s.title === title)!;
    const apiRef = session("Export the API reference"), retry = session("Retry policy for the sign-in service");
    ensure(apiRef?.links.pr && retry?.links.pr, "The demo must link requests #139 and #142");
    const target: RepoTarget = { provider: "github", remote: "origin", host: "example.com", path: "atlas" };
    const requests = { path: "C:/fixture/atlas", target, hostingAccount: { id: "fixture" }, workspaceAccess: async () => ({ target, token: "fixture-token", apiBase: "https://api.example.com", me: "fixture" }) };

    // Without a host the chip stays as it was and nothing is asked
    root.render(<LedgerWorkspace repoPath="C:/fixture/atlas" ledger={store} />);
    store.select(retry.id);
    ensure(await until(() => $(".ledger-inspector .ledger-links button.ledger-link")?.textContent === "#142"), "The request chip did not show without a host");
    await pause(200);
    ensure(!$(".ledger-request") && !calls.length, "Without a host the Ledger must not read or decorate the request");
    root.unmount();
    root = createRoot(host);

    root.render(<LedgerWorkspace repoPath="C:/fixture/atlas" ledger={store} requests={requests} />);
    store.select(apiRef.id);
    ensure(await until(() => $(".ledger-inspector .ledger-request[data-request-state='open'] [data-request-checks='failing']")?.textContent === t("{0} failing", 1)), "An open request with a failing check did not show its pills");
    ensure(!$(".ledger-inspector [data-request-merged]"), "An open request must not suggest Mark merged…");

    store.select(retry.id);
    ensure(await until(() => $(".ledger-inspector .ledger-request[data-request-state='merged'] [data-request-checks='passing']")?.textContent === t("{0} passing", 2)), "A merged request did not show its pills");
    const suggestion = await until(() => $(".ledger-inspector [data-request-merged]"));
    ensure(suggestion && $(".ledger-inspector [data-request-merged]")?.textContent === t("Request merged — mark merged?"), "A merged request of an active session did not suggest Mark merged…");
    $<HTMLButtonElement>(".ledger-inspector [data-request-merged]")!.click();
    ensure(await until(() => [...document.querySelectorAll(".menu .menu-item .label")].some((label) => label.textContent === t("{0} (newest)", "1.4.2"))), "The suggestion did not open the version picker with the newest version marked");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    ensure(await until(() => !document.querySelector(".menu")), "Escape did not close the version picker");
    ensure(store.session(retry.id)?.status === "active", "The suggestion must never change the Ledger status by itself");

    // Its questions settled and done, it moves to To decide, where the Inbox offers the same suggestion
    for (const question of store.state!.questions.filter((q) => q.sessionId === retry.id && q.state === "open")) await store.dismiss(question);
    await store.human({ action: "set_status", sessionId: retry.id, status: "done" });
    ensure(await until(() => store.session(retry.id)?.verdict === "pending_merge"), `The finished session did not move to To decide: ${store.session(retry.id)?.verdict}`);
    store.setView("inbox");
    ensure(await until(() => $(`.ledger-inbox [data-group='decide'] [data-item='s:${retry.id}'] [data-request-merged]`)), "The Inbox's To decide group did not suggest Mark merged…");
    $<HTMLButtonElement>(`.ledger-inbox [data-item='s:${retry.id}'] [data-request-merged]`)!.click();
    ensure(await until(() => document.querySelector(".menu .menu-item")), "The Inbox suggestion did not open the version picker");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    ensure(await until(() => !document.querySelector(".menu")) && store.session(retry.id)?.status === "done", "The Inbox suggestion changed the status by itself");

    ensure(calls.length > 0 && calls.every((c) => c.method === "GET" && c.url.startsWith("https://api.example.com/repos/atlas/") && c.token === "Bearer fixture-token"), `Only reads of the repository through its account are allowed: ${calls.map((c) => `${c.method} ${c.url}`).join(", ")}`);
    const reads = calls.length;
    await pause(300);
    ensure(calls.length === reads, "A fresh request must not be read again");
    return [true, `state and checks pills, merged suggestion in the inspector and Inbox, ${reads} reads through the repository's account`];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    ipc.http = original;
    root.unmount();
    host.remove();
  }
}
