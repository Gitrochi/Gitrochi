import { describe, expect, it } from "vitest";
import { DemoLedgerBackend, editAnswerDraft, emptyAnswerDraft, fillsSuggestion, LedgerStore, promptAnswerQuestions, promptDraftAnswer, reportedAnswerQuestion, selectAnswerOption, suggestedAnswerDraft } from "@/entities/ledger";
import { prompt, question } from "./ledger-fixtures";

const ask = () => prompt({ kind: "ask_user_question", payload: { questions: [
  { header: "Format", question: "Which format?", options: [{ label: "Brief", description: "A short result", recommended: true }, { label: "Detailed" }] },
  { header: "Checks", question: "Which checks?", multiSelect: true, options: [{ label: "Unit" }, { label: "Integration", recommended: true }, { label: "Browser", recommended: true }] },
  { question: "Anything else?", options: [] },
] } });

describe("Ledger editable question forms", () => {
  it("keeps every question, native option order, descriptions and selection mode", () => {
    const questions = promptAnswerQuestions(ask());
    expect(questions).toHaveLength(3);
    expect(questions[0]).toMatchObject({ id: "0", header: "Format", question: "Which format?", multiSelect: false, options: [{ label: "Brief", description: "A short result", recommended: true }, { label: "Detailed", recommended: false }], suggestedAnswer: "Brief" });
    expect(questions[1]).toMatchObject({ multiSelect: true, suggestedAnswer: "Integration, Browser" });
    expect(questions[2]).toMatchObject({ question: "Anything else?", options: [] });
    expect(questions[2].suggestedAnswer).toBeUndefined();
  });

  it("prefers a question's suggestion, then its proposed answer, then explicit recommendations", () => {
    const p = ask();
    p.payload.questions = [
      { question: "First?", suggestedAnswer: "Explain the tradeoff", options: [{ label: "A", recommended: true }] },
      { question: "Second?", options: [{ label: "B", recommended: true }] },
      { question: "Third?", options: [{ label: "C (Recommended)", recommended: false }, { label: "D" }] },
    ];
    p.payload.proposed = { type: "answers", answers: { "First?": "Proposal", "Second?": "Second proposal" } };
    expect(promptAnswerQuestions(p).map((q) => q.suggestedAnswer)).toEqual(["Explain the tradeoff", "Second proposal", undefined]);
  });

  it("never makes the first unmarked choice a suggestion", () => {
    const p = prompt({ payload: { question: "Continue?", options: ["Yes", "No"] } });
    expect(promptAnswerQuestions(p)[0].suggestedAnswer).toBeUndefined();
    expect(promptAnswerQuestions(prompt({ payload: { question: "Continue?", options: ["Yes", "No (Recommended)"] } }))[0].suggestedAnswer).toBe("No (Recommended)");
  });

  it("fills editable stop answers from choices and sends the text shape only on confirmation", () => {
    const p = prompt({ kind: "stop_question", payload: { question: "Continue?", options: ["Yes", "No"], proposed: { type: "reply", text: "Yes, with tests" } } });
    const questions = promptAnswerQuestions(p), q = questions[0];
    expect(q.suggestedAnswer).toBe("Yes, with tests");
    const picked = selectAnswerOption(q, emptyAnswerDraft(), "No");
    expect(picked).toEqual({ text: "No", selected: ["No"] });
    const edited = editAnswerDraft(picked, "No; first run the checks.");
    expect(edited.selected).toEqual([]);
    expect(promptDraftAnswer(p, questions, { [q.id]: edited })).toEqual({ text: "No; first run the checks." });
  });

  it("toggles multi-select in native order and preserves custom edits as the authoritative answer", () => {
    const q = promptAnswerQuestions(ask())[1];
    let draft = selectAnswerOption(q, emptyAnswerDraft(), "Browser");
    draft = selectAnswerOption(q, draft, "Unit");
    expect(draft).toEqual({ text: "Unit, Browser", selected: ["Unit", "Browser"] });
    draft = selectAnswerOption(q, draft, "Browser");
    expect(draft).toEqual({ text: "Unit", selected: ["Unit"] });
    expect(editAnswerDraft(draft, "Unit")).toEqual(draft);
    expect(editAnswerDraft(draft, "Unit plus performance checks")).toEqual({ text: "Unit plus performance checks", selected: [] });
    expect(suggestedAnswerDraft(q)).toEqual({ text: "Integration, Browser", selected: ["Integration", "Browser"] });
    expect(suggestedAnswerDraft({ ...q, suggestedAnswer: "Unit, Browser" })).toEqual({ text: "Unit, Browser", selected: ["Unit", "Browser"] });
  });

  it("requires every answer, supports no-options custom text and emits a complete per-question map", () => {
    const p = ask(), questions = promptAnswerQuestions(p);
    const drafts = Object.fromEntries(questions.map((q, index) => [q.id, { text: ["Detailed", "Unit, Browser", "Include measurements"][index], selected: [] }]));
    expect(promptDraftAnswer(p, questions, {})).toBeNull();
    expect(promptDraftAnswer(p, questions, { ...drafts, "2": { text: "  ", selected: [] } })).toBeNull();
    expect(promptDraftAnswer(p, questions, drafts)).toEqual({ answers: { "Which format?": "Detailed", "Which checks?": "Unit, Browser", "Anything else?": "Include measurements" } });
    expect(promptDraftAnswer(p, [questions[0], { ...questions[0], id: "duplicate" }], { ...drafts, duplicate: drafts["0"] })).toBeNull();
  });

  it("Tab fills only an untouched focused editor and leaves reverse navigation and IME alone", () => {
    expect(fillsSuggestion({ key: "Tab" }, "", "Yes")).toBe(true);
    for (const value of [" ", "\n", "My draft"]) expect(fillsSuggestion({ key: "Tab" }, value, "Yes")).toBe(false);
    for (const modifier of ["shiftKey", "ctrlKey", "metaKey", "altKey", "isComposing"]) expect(fillsSuggestion({ key: "Tab", [modifier]: true }, "", "Yes")).toBe(false);
    expect(fillsSuggestion({ key: "Enter" }, "", "Yes")).toBe(false);
    expect(fillsSuggestion({ key: "Tab" }, "")).toBe(false);
  });

  it("gives reported MCP questions the same suggestions and choices without changing their text identity", () => {
    const q = reportedAnswerQuestion(question({ id: 42, text: "Which route?", multiSelect: false, suggestedAnswer: "Use the stable route", options: [{ label: "Fast" }, { label: "Stable", recommended: true, description: "Keeps compatibility" }] }));
    expect(q).toMatchObject({ id: "42", question: "Which route?", suggestedAnswer: "Use the stable route", options: [{ label: "Fast", recommended: false }, { label: "Stable", recommended: true, description: "Keeps compatibility" }] });
    expect(suggestedAnswerDraft(q)).toEqual({ text: "Use the stable route", selected: [] });
  });
});

describe("Ledger demo structured reported questions", () => {
  it("keeps a failed reported draft when another client answered first", async () => {
    const backend = new DemoLedgerBackend({ empty: true });
    await backend.call("import", { text: JSON.stringify({ event: "question", project: "atlas", session: "raced-question", question: { text: "Which output?", options: ["Brief", "Detailed"] } }) });
    const q = (await backend.call("session", { id: "raced-question" })).questions[0];
    const store = new LedgerStore(backend);
    await store.refresh(true);
    await backend.call("human", { action: "answer", sessionId: q.sessionId, questionId: q.id, answer: "The other client's answer" });
    expect(await store.answer(q, "My unsent custom answer")).toBe(false);
    expect(store.unsentAnswers.get(q.id)).toBe("My unsent custom answer");
    expect((await backend.call("session", { id: q.sessionId })).questions[0].answer).toBe("The other client's answer");
    store.discardUnsentAnswer(q.id);
    expect(store.unsentAnswers.has(q.id)).toBe(false);
    store.dispose();
  });

  it("imports mixed question metadata and avoids a duplicate summary fallback", async () => {
    const backend = new DemoLedgerBackend({ empty: true });
    const report = { event: "question", project: "atlas", session: "structured", summary: "Three choices to review", questions: ["Plain question?", { text: "Which checks?", multiSelect: true, suggestedAnswer: "Unit, Browser", options: [{ label: "Unit", description: "Fast checks", recommended: true }, { label: "Browser (Recommended)", recommended: false }] }, { text: "Custom answer?", options: [], suggestedAnswer: "Explain the risk" }] };
    expect((await backend.call("import", { text: JSON.stringify(report) })).results[0].ok).toBe(true);
    const detail = await backend.call("session", { id: "structured" });
    expect(detail.questions.map((q) => q.text)).toEqual(["Plain question?", "Which checks?", "Custom answer?"]);
    expect(detail.questions[1]).toMatchObject({ multiSelect: true, suggestedAnswer: "Unit, Browser", options: [{ label: "Unit", description: "Fast checks", recommended: true }, { label: "Browser (Recommended)", recommended: false }] });
    expect(detail.questions[2]).toMatchObject({ suggestedAnswer: "Explain the risk" });
    const direct = { event: "question", session: "structured", question: { text: "Which format?", options: ["Brief", "Detailed (Recommended)"] } };
    expect((await backend.call("import", { text: JSON.stringify(direct) })).results[0].ok).toBe(true);
    expect((await backend.call("session", { id: "structured" })).questions.at(-1)).toMatchObject({ text: "Which format?", options: [{ label: "Brief", recommended: false }, { label: "Detailed (Recommended)", recommended: true }] });
  });

  it("rejects malformed metadata before creating sessions or questions", async () => {
    const backend = new DemoLedgerBackend({ empty: true });
    const result = await backend.call("import", { text: JSON.stringify({ event: "question", project: "atlas", session: "invalid", question: { text: "Which?", options: [{ label: "A" }, { label: "A" }] } }) });
    expect(result.results[0]).toMatchObject({ ok: false, error: "Question option labels must be distinct" });
    expect(backend.world.sessions).toEqual([]);
  });
});
