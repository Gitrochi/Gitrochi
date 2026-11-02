import { describe, expect, it } from "vitest";
import { documentSummaryContext, documentSummaryKey } from "../src/widgets/ledger-workspace/lib/document-summary";

describe("document summary evidence", () => {
  const entry = { root: "/example/docs", path: "plan.md", line: 7, text: "TASK-1 remains open", hash: "first" };
  it("keeps bounded valid JSON with source locations and omits absolute roots", () => {
    const context = documentSummaryContext(Array.from({ length: 200 }, () => ({ ...entry, text: "x".repeat(1000) })));
    expect(context.length).toBeLessThanOrEqual(12000);
    expect(context).not.toContain(entry.root);
    expect(JSON.parse(context)[0]).toEqual({ path: "plan.md", line: 7, text: "x".repeat(1000) });
    expect(documentSummaryContext([entry], 2)).toBe("[]");
  });
  it("invalidates cached summaries after a content or project change", () => {
    const key = documentSummaryKey("Example", "TASK-1", [entry]);
    expect(documentSummaryKey("Example", "TASK-1", [entry, entry])).toBe(key);
    expect(documentSummaryKey("Example", "TASK-1", [{ ...entry, hash: "changed" }])).not.toBe(key);
    expect(documentSummaryKey("Other", "TASK-1", [entry])).not.toBe(key);
  });
});
