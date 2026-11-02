import { describe, expect, it } from "vitest";
import { parseChatGPTQuestion } from "@/entities/ledger";

describe("Explicit ChatGPT question paste", () => {
  it("keeps arbitrary pasted question text without inventing choices", () => {
    expect(parseChatGPTQuestion("  Explain the cache tradeoffs.\nKeep the original context.  ")).toEqual({ text: "Explain the cache tradeoffs.\nKeep the original context.", options: [] });
  });

  it("keeps complete contiguous bullet labels and only explicit recommendations", () => {
    expect(parseChatGPTQuestion("Which runtime?\n- Node.js: use the existing cache\n- Bun — alternative (추천)\n- Deno (Recommended)"))
      .toEqual({ text: "Which runtime?", options: [{ label: "Node.js: use the existing cache" }, { label: "Bun — alternative (추천)", recommended: true }, { label: "Deno (Recommended)", recommended: true }] });
    expect(parseChatGPTQuestion("Which format?\n1. **Brief**: keep details\n2) Detailed [권장]").options)
      .toEqual([{ label: "**Brief**: keep details" }, { label: "Detailed [권장]", recommended: true }]);
  });

  it("retains context after choices and refuses separate choice blocks", () => {
    expect(parseChatGPTQuestion("Which cache?\n• Memory\n• Disk\nKeep the fallback available.").text).toBe("Which cache?\nKeep the fallback available.");
    expect(() => parseChatGPTQuestion("Which cache?\n- Memory\n- Disk\n\nWhich format?\n- Brief\n- Detailed"))
      .toThrow("Use Paste reports for multiple questions.");
  });

  it("validates structured metadata while preserving false flags and labels", () => {
    const parsed = parseChatGPTQuestion(JSON.stringify({ text: "Which cache?", multiSelect: false, suggestedAnswer: "Keep the current cache",
      options: [{ label: "Memory (Recommended)", recommended: false, description: "Existing store" }, "Disk (권장)"], session: "foreign", project: "foreign" }));
    expect(parsed).toEqual({ text: "Which cache?", multiSelect: false, suggestedAnswer: "Keep the current cache",
      options: [{ label: "Memory (Recommended)", recommended: false, description: "Existing store" }, { label: "Disk (권장)", recommended: true }] });
    expect(parsed).not.toHaveProperty("session");
    expect(parsed).not.toHaveProperty("project");
  });

  it("accepts one question from a JSON report or ledger block and ignores source targets", () => {
    const expected = { text: "Which cache?", options: [{ label: "Memory" }, { label: "Disk" }], multiSelect: true };
    const report = { event: "question", project: "foreign", session: "foreign", questions: [{ text: expected.text, options: ["Memory", "Disk"], multiSelect: true }] };
    expect(parseChatGPTQuestion(JSON.stringify(report))).toEqual(expected);
    expect(parseChatGPTQuestion(`\`\`\`ledger\n${JSON.stringify(report)}\n\`\`\``)).toEqual(expected);
    expect(parseChatGPTQuestion('{"question":"What should the name be?","session":"foreign"}')).toEqual({ text: "What should the name be?", options: [] });
    expect(parseChatGPTQuestion('[{"text":"One"}]')).toEqual({ text: "One", options: [] });
    expect(parseChatGPTQuestion('{"question":"Which?","options":["A","B"]}')).toEqual({ text: "Which?", options: [{ label: "A" }, { label: "B" }] });
  });

  it("never silently drops additional structured questions", () => {
    for (const value of [[{ text: "First" }, { text: "Second" }], { questions: ["First", "Second"] }, { question: "First", questions: ["Second"] }, { text: "First", questions: ["Second"] }]) {
      expect(() => parseChatGPTQuestion(JSON.stringify(value))).toThrow("Use Paste reports for multiple questions.");
    }
    expect(() => parseChatGPTQuestion('```ledger\n{"question":"First"}\n```\n```ledger\n{"question":"Second"}\n```'))
      .toThrow("Use Paste reports for multiple questions.");
  });

  it("rejects empty or canonically duplicate option labels", () => {
    for (const options of [[""], ["A", " A "], ["é", "e\u0301"], [{}], [false]]) {
      expect(() => parseChatGPTQuestion(JSON.stringify({ text: "Choose", options }))).toThrow("Question option labels must be nonempty and distinct.");
    }
    expect(() => parseChatGPTQuestion("Which?\n- A\n- ")).toThrow("Question option labels must be nonempty and distinct.");
  });

  it("rejects mistyped flags, descriptions, suggestions and options", () => {
    for (const extra of [{ multiSelect: 1 }, { multiSelect: null }, { options: [{ label: "A", recommended: "yes" }] }]) {
      expect(() => parseChatGPTQuestion(JSON.stringify({ text: "Choose", ...extra }))).toThrow("Question flags must be true or false.");
    }
    for (const extra of [{ suggestedAnswer: ["A"] }, { options: [{ label: "A", description: false }] }]) {
      expect(() => parseChatGPTQuestion(JSON.stringify({ text: "Choose", ...extra }))).toThrow("Question descriptions and suggestions must be text.");
    }
    expect(() => parseChatGPTQuestion('{"text":"Choose","options":null}')).toThrow("Question options must be an array.");
    expect(() => parseChatGPTQuestion('{"text":1}')).toThrow("Question text must be nonempty text.");
  });

  it("reports malformed JSON and enforces a UTF-8 byte limit without splitting Unicode", () => {
    expect(() => parseChatGPTQuestion('{"text":')).toThrow("Could not read the pasted JSON.");
    expect(() => parseChatGPTQuestion('```json\n{"text":"Q"}\n```\nExtra content')).toThrow("Could not read the pasted JSON.");
    const boundary = "😀".repeat(16_384);
    expect(parseChatGPTQuestion(boundary).text).toBe(boundary);
    expect(() => parseChatGPTQuestion(`${boundary}a`)).toThrow("Pasted text is limited to 64 KiB.");
    expect(() => parseChatGPTQuestion("  \n")).toThrow("Paste a question first.");
  });
});
