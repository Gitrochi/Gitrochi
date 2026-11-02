import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { env } from "@/shared/config";
import { t } from "@/shared/i18n";

const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
async function until(test: () => unknown) {
  const end = Date.now() + 4000;
  while (Date.now() < end) { if (test()) return true; await new Promise((resolve) => setTimeout(resolve, 25)); }
  return !!test();
}
function type(field: HTMLInputElement, text: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(field, text);
  field.dispatchEvent(new Event("input", { bubbles: true }));
}

/** Registration needs a reviewed confirmation; browser drafts never overwrite existing edits. */
export async function ledgerBrowserSelfTest(): Promise<[boolean, string]> {
  const [{ DemoLedgerBackend, LedgerStore }, { LedgerBrowserSheet }, { LedgerAnswerField }] = await Promise.all([import("@/entities/ledger"), import("@/features/connect-chatgpt-browser"), import("@/features/answer-ledger-question")]);
  const backend = new DemoLedgerBackend({ now: () => Date.UTC(2026, 0, 2, 12) });
  const call = backend.call.bind(backend), calls: string[] = [];
  backend.call = async (method, args) => { calls.push(method); return call(method, args); };
  const store = new LedgerStore(backend), resourceDir = env.resourceDir;
  env.resourceDir = "C:/fixture/resources";
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:900px;height:900px";
  document.body.append(host);
  const root = createRoot(host);
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const button = (key: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t(key));
  try {
    root.render(createElement(LedgerBrowserSheet, { store, onClose: () => {} }));
    ensure(await until(() => host.textContent?.includes(t("Browser host not installed"))), "Browser setup did not show installation status");
    ensure(calls.join() === "browser_status", "Opening setup must not install or remove browser access");
    const field = $<HTMLInputElement>(`input[aria-label="${t("Extension ID")}"]`)!;
    type(field, "not-an-extension-id");
    ensure(await until(() => button("Allow browser connection")?.disabled), "An invalid extension ID must not enable access");
    const id = "abcdefghijklmnopabcdefghijklmnop";
    type(field, id);
    ensure(await until(() => !button("Allow browser connection")?.disabled), "A valid extension ID did not enable review");
    button("Allow browser connection")!.click();
    ensure(await until(() => $("[role='alertdialog']")), "Browser access must have an explicit confirmation");
    ensure(host.textContent?.includes(id) && !calls.includes("browser_install"), "Review must name the exact extension and not install yet");
    button("Cancel")!.click();
    ensure(await until(() => $<HTMLInputElement>("input")), "Cancel did not return to setup");
    ensure(!calls.includes("browser_install"), "Cancel must not grant access");
    button("Allow browser connection")!.click();
    ensure(await until(() => $("[role='alertdialog']")), "The second request did not ask for confirmation");
    button("Allow browser connection")!.click();
    ensure(await until(() => host.textContent?.includes(t("Browser host installed"))), "Confirmed demo install did not update status");
    ensure(calls.filter((method) => method === "browser_install").length === 1, "Only the confirmed action may install once");
    button("Remove browser connection")!.click();
    ensure(await until(() => host.textContent?.includes(t("Browser host not installed"))), "Removing demo access did not update status");
    ensure(calls.filter((method) => method === "browser_remove").length === 1, "Removal must be explicit");

    const raw = "  Stable with my change.\n";
    let source = { id: 99020, sessionId: "fixture", text: "Which channel?", state: "open" as const, createdAt: 1, options: [{ label: "Stable", recommended: true }], suggestedAnswer: "Model recommendation", browserDraft: raw, browserSourceUrl: "https://chatgpt.com/c/00000000-0000-4000-8000-000000000000" };
    const sent: string[] = [];
    const render = () => root.render(createElement(LedgerAnswerField, { question: source, initialText: "My existing draft", placeholder: "", label: "Browser answer", onSubmit: async (text: string) => { sent.push(text); return false; } }));
    render();
    ensure(await until(() => $("textarea")), "Browser answer did not render");
    const answer = $<HTMLTextAreaElement>("textarea")!;
    ensure(answer.value === "My existing draft" && host.textContent?.includes(t("Browser draft accepted with Tab")), "Browser source must be labeled and leave the user's draft intact");
    answer.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
    ensure(answer.value === "My existing draft" && sent.length === 0, "Tab must not overwrite an existing answer or send it");
    source = { ...source, browserDraft: "A later browser draft" };
    render();
    ensure(await until(() => host.textContent?.includes("A later browser draft")), "Updated source suggestion did not appear");
    ensure(answer.value === "My existing draft", "A later capture must not overwrite an edit");
    button("Use suggestion")!.click();
    ensure(await until(() => answer.value === "A later browser draft"), "Explicit Use suggestion must fill the latest browser draft");
    ensure(sent.length === 0 && button("Save answer") && !host.textContent?.includes(t("The session reads it with its next report.")), "Browser filling must stay unsent and show local-only saving");
    button("Save answer")!.click();
    ensure(await until(() => sent.length === 1), "Only Save answer may submit the local answer");
    ensure(answer.value === "A later browser draft", "Failed saving must retain the exact draft");
    return [true, "Reviewed host setup, explicit revocation and provenance-aware editable browser drafts checked without registering a real host"];
  } catch (cause) { return [false, cause instanceof Error ? cause.message : String(cause)]; }
  finally { root.unmount(); host.remove(); store.stop(); env.resourceDir = resourceDir; }
}
