import { type DemoLedgerBackend, LedgerError, type LedgerPendingPrompt, type LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";

const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
async function until(test: () => unknown) {
  const end = Date.now() + 4000;
  while (Date.now() < end) { if (test()) return true; await new Promise((resolve) => setTimeout(resolve, 30)); }
  return !!test();
}
function type(field: HTMLTextAreaElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(field, value);
  field.dispatchEvent(new Event("input", { bubbles: true }));
}
function tab(field: HTMLTextAreaElement, extra: KeyboardEventInit = {}) {
  const event = new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true, ...extra });
  field.dispatchEvent(event);
  return event.defaultPrevented;
}

/** Exercises editable choices through both live prompts and reported MCP questions. */
export async function ledgerAnswersSelfTest(host: HTMLElement, store: LedgerStore, backend: DemoLedgerBackend, clock: number) {
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const button = (scope: string, label: string) => [...host.querySelectorAll<HTMLButtonElement>(`${scope} button`)].find((item) => item.textContent?.trim() === t(label));
  const owner = store.state!.sessions.find((session) => session.project === "atlas" && session.status === "active" && !session.stream)!;
  const live: LedgerPendingPrompt = { id: backend.world.nextPrompt++, sessionId: owner.id, kind: "ask_user_question", state: "waiting", createdAt: clock, deadline: clock + 120_000, payload: { autoAnswer: false, questions: [
    { header: "Output", question: "Which output?", suggestedAnswer: "Start with a short summary.", options: [{ label: "Brief", description: "A short result", recommended: true }, { label: "Detailed", description: "Include evidence" }] },
    { header: "Checks", question: "Which checks?", multiSelect: true, options: [{ label: "Unit" }, { label: "Integration", recommended: true }, { label: "Browser" }] },
    { question: "Anything else?", suggestedAnswer: "Mention remaining risks", options: [] },
  ], proposed: { type: "answers", answers: { "Which output?": "Proposal" } } } };
  backend.world.prompts.push(live);
  backend.world.rev++;
  await store.refresh(true);
  const scope = `[data-prompt="${live.id}"]`;
  ensure(await until(() => button(scope, "Answer")), "The multi-question manual wait did not appear");
  ensure($(scope)?.textContent?.includes(t("Time left {0}", "2:00")) && !button(scope, "Not this time"), "A manual wait must not claim an automatic answer");
  button(scope, "Answer")!.click();
  ensure(await until(() => $(scope)?.querySelectorAll("fieldset").length === 3), "Every Ask question must have its own group");
  const fields = () => [...$(scope)!.querySelectorAll<HTMLTextAreaElement>("textarea")];
  ensure(fields().length === 3 && button(scope, "Send answer")?.disabled, "The form must wait for all three answers");
  ensure($(scope)?.textContent?.includes("A short result") && !$(scope)?.textContent?.includes("★"), "Choices must retain descriptions without star markers");
  ensure(tab(fields()[0]), "Tab did not fill an empty answer");
  ensure(await until(() => fields()[0].value === "Start with a short summary."), "Tab did not prefer the question's suggested answer");
  ensure(live.state === "waiting" && !live.answer, "Tab must not send an answer");
  ensure(!tab(fields()[2], { shiftKey: true }) && fields()[2].value === "", "Shift+Tab must keep normal reverse navigation");
  ensure(!tab(fields()[2], { isComposing: true }) && fields()[2].value === "", "Tab must leave IME composition alone");
  type(fields()[0], " ");
  await until(() => fields()[0].value === " ");
  ensure(!tab(fields()[0]) && fields()[0].value === " ", "Tab must not replace a typed whitespace draft");
  $<HTMLInputElement>(`${scope} input[value="Detailed"]`)!.click();
  ensure(await until(() => fields()[0].value === "Detailed"), "Choosing a single option did not fill the editable answer");
  ensure(live.state === "waiting", "Selecting an option must not send immediately");
  type(fields()[0], "Detailed, with a short summary.");
  ensure(await until(() => !$<HTMLInputElement>(`${scope} input[value="Detailed"]`)!.checked), "Editing an answer must update the selected option state");
  $<HTMLInputElement>(`${scope} input[value="Browser"]`)!.click();
  $<HTMLInputElement>(`${scope} input[value="Unit"]`)!.click();
  ensure(await until(() => fields()[1].value === "Unit, Browser"), "Multiple choices must compose in their question's order");
  type(fields()[2], "Mention risks and follow-up work.");
  ensure(await until(() => !button(scope, "Send answer")!.disabled), "A no-options custom answer must complete the form");
  button(scope, "Send answer")!.click();
  ensure(await until(() => live.state === "answered" && !$(scope)), "Send answer did not confirm the complete form");
  ensure(JSON.stringify(live.answer) === JSON.stringify({ answers: { "Which output?": "Detailed, with a short summary.", "Which checks?": "Unit, Browser", "Anything else?": "Mention risks and follow-up work." } }), "The Ask answer did not contain every edited per-question value");

  const stop: LedgerPendingPrompt = { id: backend.world.nextPrompt++, sessionId: owner.id, kind: "stop_question", state: "waiting", createdAt: clock, deadline: clock + 120_000, payload: { question: "Continue with the next step?", options: [{ label: "Continue", recommended: true }, { label: "Pause" }] } };
  backend.world.prompts.push(stop); backend.world.rev++;
  await store.refresh(true);
  const stopScope = `[data-prompt="${stop.id}"]`;
  button(stopScope, "Answer")!.click();
  ensure(await until(() => $(`${stopScope} textarea`)), "The stop question did not offer its editable choices");
  button(stopScope, "Use suggestion")!.click();
  ensure(await until(() => $<HTMLTextAreaElement>(`${stopScope} textarea`)!.value === "Continue"), "Use suggestion must fill rather than send");
  type($<HTMLTextAreaElement>(`${stopScope} textarea`)!, "Pause after recording the checks.");
  const originalCall = backend.call.bind(backend);
  backend.call = async (method, args) => { if (method === "prompt_answer") throw new LedgerError("CONFLICT", "Try this answer again"); return originalCall(method, args); };
  try {
    button(stopScope, "Send answer")!.click();
    ensure(await until(() => $(".ledger-toast")?.textContent?.includes("Try this answer again") && !button(stopScope, "Send answer")?.disabled), "A failed answer must show the error and leave the form retryable");
    ensure($<HTMLTextAreaElement>(`${stopScope} textarea`)!.value === "Pause after recording the checks.", "A failed answer lost the draft");
  } finally { backend.call = originalCall; }
  const originalAnswer = store.answerPrompt;
  store.answerPrompt = async (prompt, answer) => {
    if (prompt.id === stop.id) { stop.state = "auto"; stop.answer = { type: "reply", text: "Continue" }; backend.world.rev++; }
    return originalAnswer.call(store, prompt, answer);
  };
  try {
    button(stopScope, "Send answer")!.click();
    ensure(await until(() => $(stopScope)?.textContent?.includes(t("Your draft was not sent."))), "An automatic-answer race must keep the unsent draft visible");
    const draft = $<HTMLTextAreaElement>(`${stopScope} textarea`)!;
    ensure(draft.readOnly && draft.value === "Pause after recording the checks." && button(stopScope, "Send answer")?.disabled, "A closed prompt must retain the draft without offering a fake send");
    button(stopScope, "Close")!.click();
    ensure(await until(() => !$(stopScope)), "Closing the retained draft did not remove it");
  } finally { store.answerPrompt = originalAnswer; }

  const reported = { id: backend.world.nextQuestion++, sessionId: owner.id, text: "How should the report be shared?", state: "open" as const, createdAt: clock, suggestedAnswer: "Use a brief summary", options: [{ label: "Brief", description: "Focus on the outcome", recommended: true }, { label: "Detailed" }] };
  backend.world.questions.push(reported); backend.world.rev++;
  await store.refresh(true);
  const reportedScope = `[data-item="q:${reported.id}"]`;
  ensure(await until(() => $(`${reportedScope} fieldset`)), "A structured reported MCP question did not use the answer form");
  const reportField = $<HTMLTextAreaElement>(`${reportedScope} textarea`)!;
  reportField.focus();
  ensure(tab(reportField), "A reported question's suggestion did not support Tab");
  ensure(await until(() => reportField.value === "Use a brief summary"), "The reported suggestion did not fill an editable answer");
  ensure(store.unsentAnswers.get(reported.id) === "Use a brief summary", "A suggestion must persist the reported draft before sending");
  type(reportField, "A brief summary with the evidence link.");
  button(reportedScope, "Send answer")!.click();
  ensure(await until(() => !$(reportedScope)), "The reported answer did not leave the Inbox");
  store.select(owner.id);
  ensure(await until(() => store.detail?.questions.find((question) => question.id === reported.id)?.state === "answered"), "The reported answer did not appear in the inspector");
  const answered = [...host.querySelectorAll<HTMLElement>(".ledger-inspector .ledger-question")].find((item) => item.textContent?.includes(reported.text))!;
  ensure(answered?.textContent?.includes(t("Waiting for the session's next report")), "A reported answer must show queued delivery");
  let copied = "";
  const originalWrite = navigator.clipboard.writeText;
  navigator.clipboard.writeText = async (value) => { copied = value; };
  try {
    [...answered.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t("Copy answer"))!.click();
    ensure(await until(() => copied === "A brief summary with the evidence link."), "Copy answer did not copy the explicit reported answer");
  } finally { navigator.clipboard.writeText = originalWrite; }

  const raced = { id: backend.world.nextQuestion++, sessionId: owner.id, text: "Which follow-up should run?", state: "open" as const, createdAt: clock };
  backend.world.questions.push(raced); backend.world.rev++;
  await store.refresh(true);
  await backend.call("human", { action: "answer", sessionId: owner.id, questionId: raced.id, answer: "Another client's answer" });
  ensure(!await store.answer(raced, "Keep my unsent follow-up draft."), "A closed reported question must reject a late answer");
  ensure(await until(() => $<HTMLTextAreaElement>(".ledger-inspector .ledger-unsent-answer textarea")?.value === "Keep my unsent follow-up draft."), "A reported-question race lost the unsent draft from the inspector");
  ensure($<HTMLTextAreaElement>(".ledger-inspector .ledger-unsent-answer textarea")!.readOnly, "A closed reported-question draft must be selectable without offering a fake send");
  button(".ledger-inspector .ledger-unsent-answer", "Close")!.click();
  ensure(await until(() => !$(".ledger-inspector .ledger-unsent-answer")), "Closing an unsent reported draft did not discard it");

  // A polling update may close a question before Send is ever clicked; keep both editor kinds' raw drafts.
  for (const structured of [false, true]) {
    const external = { id: backend.world.nextQuestion++, sessionId: owner.id, text: `Which ${structured ? "structured" : "plain"} follow-up?`, state: "open" as const, createdAt: clock, ...(structured ? { options: [{ label: "Brief" }, { label: "Detailed" }], suggestedAnswer: "Suggested follow-up" } : {}) };
    backend.world.questions.push(external); backend.world.rev++;
    await store.refresh(true);
    const externalScope = `[data-item="q:${external.id}"]`;
    ensure(await until(() => $(`${externalScope} textarea`)), "The external-race question did not appear");
    if (structured) {
      $<HTMLInputElement>(`${externalScope} input[value="Detailed"]`)!.click();
      ensure(await until(() => store.unsentAnswers.get(external.id) === "Detailed"), "Selecting a reported option must persist its draft before sending");
    }
    const rawDraft = "  Keep this unsent draft.\nInclude the next action.  \n";
    type($<HTMLTextAreaElement>(`${externalScope} textarea`)!, rawDraft);
    ensure(await until(() => store.unsentAnswers.get(external.id) === rawDraft), "Every reported edit must persist its raw whitespace before sending");
    await backend.call("human", { action: "answer", sessionId: owner.id, questionId: external.id, answer: "The external client's decision" });
    await store.refresh(true);
    ensure(await until(() => !$(externalScope) && $<HTMLTextAreaElement>(".ledger-inspector .ledger-unsent-answer textarea")?.value === rawDraft), "A poll lost the unsent draft when another client settled the question before Send");
    ensure($<HTMLTextAreaElement>(".ledger-inspector .ledger-unsent-answer textarea")!.readOnly, "The retained pre-submit draft must remain selectable");
    ensure((await backend.call("session", { id: owner.id })).questions.find((question) => question.id === external.id)?.answer === "The external client's decision", "Retaining a pre-submit draft must not overwrite another client's answer");
    button(".ledger-inspector .ledger-unsent-answer", "Close")!.click();
    ensure(await until(() => !$(".ledger-inspector .ledger-unsent-answer") && !store.unsentAnswers.has(external.id)), "Close must clear a retained pre-submit draft");
  }
}
