import { createRoot } from "react-dom/client";
import { DemoLedgerBackend, LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { LedgerWorkspace } from "@/widgets/ledger-workspace";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 45));
const input = (element: HTMLInputElement | HTMLTextAreaElement, value: string) => {
  const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(element, value);
  element.dispatchEvent(new Event("input", { bubbles: true }));
};

/** Runs the added flows against isolated demo records through the actual React dialogs. */
export async function ledgerParitySelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:0;top:0;width:1200px;height:850px;z-index:10000;background:var(--bg)";
  document.body.append(host);
  const root = createRoot(host);
  const store = new LedgerStore(new DemoLedgerBackend());
  const ensure = (condition: unknown, text: string) => { if (!condition) throw new Error(text); };
  const button = (label: string) => [...document.querySelectorAll<HTMLButtonElement>("button")].find((row) => row.textContent?.trim() === t(label));
  const field = (label: string) => [...document.querySelectorAll(".ledger-work-editor label")].find((row) => row.textContent?.startsWith(t(label)))?.querySelector<HTMLInputElement>("input");
  const open = async (label: string) => { host.querySelector<HTMLButtonElement>("[data-ledger-extras]")!.click(); await pause(); const item = [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((row) => row.querySelector(".label")?.textContent === t(label)); ensure(item, `Menu item missing: ${label}`); item!.click(); await pause(); };
  try {
    await store.refresh(true);
    root.render(<LedgerWorkspace repoPath={null} ledger={store} />);
    await pause();
    await open("Notebook…");
    const title = document.querySelector<HTMLInputElement>(`[aria-label="${t("Note title")}"]`)!;
    const body = document.querySelector<HTMLTextAreaElement>(`[aria-label="${t("Note text")}"]`)!;
    ensure(title && body, "Notebook editor did not open");
    input(title, "Release checklist"); input(body, "## Review\n\n- Inspect the cache"); await pause(); button("Save")!.click(); await pause();
    ensure((await store.backend.call("notebook", { action: "list" }) as { notes: unknown[] }).notes.length === 1, "Notebook save did not retain the note");
    button("Close")!.click(); await pause();
    await open("Work log…"); button("New work item")!.click(); await pause();
    input(field("Work ID")!, "W-demo-01"); input(field("Title")!, "Review cache policy"); input(field("Bundle")!, "Release"); await pause();
    button("Save work record")!.click(); await pause();
    ensure(document.querySelector(".ledger-work-items")?.textContent?.includes("Review cache policy"), "New work item did not appear");
    button("Build report")!.click(); await pause();
    ensure(document.querySelector(".ledger-work-report")?.textContent?.includes("Review cache policy"), "Work report did not include the item");
    button("Close")!.click(); await pause();
    await open("Document tracker…");
    ensure(document.querySelector(".ledger-document-evidence"), "Document tracker did not open");
    ensure(!document.querySelector(".ledger-document-detail .markdown"), "An AI summary ran without a request");
    button("Close")!.click(); await pause();
    await open("Manage records…");
    const sessionTitle = [...document.querySelectorAll(".ledger-manage-form label")].find((row) => row.textContent?.startsWith(t("Title")))?.querySelector<HTMLInputElement>("input");
    ensure(sessionTitle, "Session metadata editor did not open");
    input(sessionTitle!, "Reviewed cache policy"); await pause(); button("Save session details")!.click(); await pause();
    ensure((await store.backend.call("state", { range: "all" })).sessions.some((row) => row.title === "Reviewed cache policy"), "Session metadata was not saved");
    button("Close")!.click();
    return [true, "Notebook save, dated work item, Markdown report, document tracker and metadata editing through Ledger actions"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); }
}
