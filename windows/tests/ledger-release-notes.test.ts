import { describe, expect, it } from "vitest";
import { DemoLedgerBackend, type LedgerReleaseNotes, releaseNotesSummary } from "@/entities/ledger";

const translate = (text: string, ...values: (string | number)[]) => text.replace(/\{(\d+)\}/g, (_, i: string) => String(values[Number(i)]));

describe("release notes", () => {
  it("the demo drafts HEAD from the sessions merged into it, grouped by role", async () => {
    const demo = new DemoLedgerBackend({ now: () => Date.UTC(2026, 10, 3, 12) });
    const notes = await demo.call("release_notes", { project: "atlas" });
    expect(notes.version).toBe("1.4.2");
    expect(notes.versions[0]).toBe("1.4.2");
    expect(notes.previous).toBe("1.4.1");
    expect(notes.groups.map((g) => g.role)).toEqual(["decision", "document"]);
    expect(notes.groups[0].sessions[0]).toMatchObject({ title: "Cache invalidation design", how: "merged" });
    expect(notes.markdown.startsWith("# atlas 1.4.2\n\nReleased ")).toBe(true);
    expect(notes.markdown).toContain("## Decisions\n\n- **Cache invalidation design** (`");
    expect(notes.markdown.endsWith("\n")).toBe(true);
    const older = await demo.call("release_notes", { project: "atlas", version: "v1.4.1" });
    expect(older.version).toBe("1.4.1");
    await expect(demo.call("release_notes", { project: "atlas", version: "9.9" })).rejects.toMatchObject({ code: "NOT_FOUND" });
    await expect(demo.call("release_notes", { project: "nowhere" })).rejects.toMatchObject({ code: "NOT_FOUND" });
  });

  it("says how many sessions went in, or that none did", () => {
    const notes: LedgerReleaseNotes = { project: "atlas", version: "2.0.0", releasedAt: 0, versions: ["2.0.0"], groups: [], markdown: "# atlas 2.0.0\n" };
    expect(releaseNotesSummary(notes, translate)).toBe("No sessions were merged into 2.0.0.");
    const entry = { id: "S1", title: "Cache", kind: "decision", how: "merged" as const, artifacts: [] };
    notes.groups = [{ role: "decision", title: "Decisions", sessions: [entry, { ...entry, id: "S2" }] }];
    expect(releaseNotesSummary(notes, translate)).toBe("Sessions merged into 2.0.0: 2");
  });
});
