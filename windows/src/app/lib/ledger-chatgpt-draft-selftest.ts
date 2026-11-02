import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => unknown) {
  const end = Date.now() + 4000;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return !!test();
}
const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
function type(field: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const prototype = field instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(field, value);
  field.dispatchEvent(new Event("input", { bubbles: true }));
}
function choose(field: HTMLSelectElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(field, value);
  field.dispatchEvent(new Event("change", { bubbles: true }));
}

/** Explicit pasted text can fill a local draft or create a reviewed question only after Save. */
export async function ledgerChatGPTDraftSelfTest(): Promise<[boolean, string]> {
  const [{ DemoLedgerBackend, LedgerStore }, { LedgerChatGPTDraftSheet }] = await Promise.all([import("@/entities/ledger"), import("@/features/transfer-chatgpt-draft")]);
  const backend = new DemoLedgerBackend({ now: () => Date.UTC(2026, 0, 2, 12) });
  const store = new LedgerStore(backend);
  const owner = backend.world.sessions.find((session) => session.project === "atlas" && session.status === "active" && !session.stream)!;
  const first = { id: backend.world.nextQuestion++, sessionId: owner.id, text: "Which cache?", state: "open" as const, createdAt: owner.lastAt };
  const second = { ...first, id: backend.world.nextQuestion++, text: "Which fallback?" };
  backend.world.questions = [first, second];
  const calls: { method: string; args: unknown }[] = [];
  const originalCall = backend.call.bind(backend), originalSet = settings.set;
  backend.call = async (method, args) => { calls.push({ method, args }); return originalCall(method, args); };
  settings.set = () => {};
  store.projectChoice = owner.project;
  store.selectedId = owner.id;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:900px;height:900px";
  document.body.append(host);
  const root = createRoot(host);
  let instance = 0, closed = 0;
  const opened: string[] = [];
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t(label));
  const copied = () => $<HTMLTextAreaElement>(`textarea[aria-label="${t("Copied text")}"]`)!;
  const field = (label: string) => $<HTMLInputElement>(`input[aria-label="${t(label)}"]`)!;
  const select = (label: string) => $<HTMLSelectElement>(`select[aria-label="${t(label)}"]`)!;
  const imports = () => calls.filter((call) => call.method === "import");
  const mount = async () => {
    root.render(createElement(LedgerChatGPTDraftSheet, { key: ++instance, store, onClose: () => { closed++; }, onOpenQuestion: (id: string) => { opened.push(id); } }));
    ensure(await until(() => copied() && copied().value === ""), "The explicit-paste sheet did not mount with an empty draft");
  };
  try {
    await store.refresh(true);
    await mount();
    const raw = "  Keep the exact copied draft.\nInclude the fallback.  \n";
    type(copied(), raw);
    ensure(await until(() => !button("Use draft")?.disabled), "Pasted text did not enable Use draft");
    button("Use draft")!.click();
    ensure(await until(() => closed === 1), "Use draft did not close the transfer sheet");
    ensure(store.unsentAnswers.get(first.id) === raw && first.state === "open" && opened[0] === owner.id,
      "Use draft must preserve exact text locally without answering the question");
    ensure(!calls.some((call) => ["human", "prompt_answer", "import"].includes(call.method)), "Filling a draft must not write to the backend");

    await mount();
    type(copied(), raw);
    await until(() => copied().value === raw);
    backend.world.questions[0].state = "answered";
    backend.world.rev++;
    await store.refresh(true);
    ensure(await until(() => button("Use draft")?.disabled), "A closed question must disable Use draft");
    ensure(copied().value === raw && select("Question in your Ledger").value === "" && host.textContent?.includes(t("The selected question is no longer open. Choose another question; your copied text is still here.")),
      "A closed question must retain the copied text without silently selecting another question");
    button("Use draft")!.click();
    ensure(closed === 1 && !store.unsentAnswers.has(second.id), "A stale question must not receive or retarget a draft");
    choose(select("Question in your Ledger"), String(second.id));
    ensure(await until(() => !button("Use draft")?.disabled), "Choosing another open question did not restore Use draft");
    button("Use draft")!.click();
    ensure(await until(() => closed === 2 && store.unsentAnswers.get(second.id) === raw), "Only an explicit new target may receive the preserved draft");

    await mount();
    button("Add a question")!.click();
    ensure(await until(() => field("Project")), "Add a question did not expose its destination");
    const pasted = JSON.stringify({ event: "question", project: "foreign-project", session: "foreign-session", question: { text: "Which output?", multiSelect: true, suggestedAnswer: "Keep it brief", options: [{ label: "Brief (Recommended)", recommended: false }, { label: "Detailed", description: "Keep evidence", recommended: true }] } });
    type(copied(), pasted);
    ensure(await until(() => !button("Preview")?.disabled), "Question text did not enable Preview");
    const before = JSON.stringify(backend.world);
    button("Preview")!.click();
    ensure(await until(() => $(".ledger-chatgpt-preview") && button("Save question")), "Question parsing did not show an explicit preview");
    ensure(JSON.stringify(backend.world) === before && imports().length === 0, "Preview must not create a Ledger record");
    ensure(select("Session").value === owner.id && field("Project").value === owner.project && $(".ledger-chatgpt-preview")?.textContent?.includes("Keep evidence"), "Pasted targets must be ignored while choices remain reviewable");
    type(copied(), pasted + "\n");
    ensure(await until(() => !$(".ledger-chatgpt-preview") && !button("Save question") && button("Preview")), "Editing pasted text must invalidate its preview and Save action");
    button("Preview")!.click();
    ensure(await until(() => button("Save question")), "Edited text did not require a fresh preview");
    type(field("Project"), "capture-destination");
    ensure(await until(() => select("Session").value === ""), "Changing project must explicitly choose a new-session destination");
    ensure(imports().length === 0, "Changing destination must not save the preview");
    button("Save question")!.click();
    ensure(await until(() => closed === 3 && imports().length === 1), "Only Save question should import the reviewed question");
    const report = JSON.parse((imports()[0].args as { text: string }).text);
    const saved = backend.world.questions.find((question) => question.text === "Which output?")!;
    ensure(report.project === "capture-destination" && !report.session && report.question.multiSelect === true && report.question.options[0].recommended === false && report.question.suggestedAnswer === "Keep it brief",
      "The saved report must use the chosen destination and preserve reviewed question metadata");
    ensure(saved?.state === "open" && backend.world.sessions.find((session) => session.id === saved.sessionId)?.project === "capture-destination" && !backend.world.sessions.some((session) => session.id === "foreign-session"),
      "Saving must create an open question at the selected destination without importing the pasted source target");

    ensure(store.project === "capture-destination", "Saving to another project must reveal that project's question");
    store.setProjectChoice(owner.project);
    await mount();
    button("Add a question")!.click();
    ensure(await until(() => select("Session")?.value === owner.id), "The active selected session did not initialize the question destination");
    type(copied(), "What should happen next?\n- Continue\n- Pause");
    ensure(await until(() => !button("Preview")?.disabled), "The final question draft did not become previewable");
    button("Preview")!.click();
    ensure(await until(() => button("Save question")), "The final question did not preview");
    owner.status = "done";
    backend.world.rev++;
    await store.refresh(true);
    ensure(await until(() => button("Save question")?.disabled), "A closed destination must disable Save question");
    ensure(select("Session").value === owner.id && copied().value.startsWith("What should happen next?") && host.textContent?.includes(t("The selected session is no longer active. Choose a destination again.")),
      "A closed session must keep its identity and draft without silently creating a different destination");
    button("Save question")!.click();
    ensure(imports().length === 1 && closed === 3 && !calls.some((call) => ["human", "prompt_answer"].includes(call.method)), "Capture must never send an answer or save to a stale destination");
    return [true, "Exact local drafts, pinned targets, explicit preview invalidation, ignored pasted targets and one explicit question save checked"];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    root.unmount();
    host.remove();
    store.stop();
    settings.set = originalSet;
  }
}
