import { describe, expect, it } from "vitest";
import { barShare, DemoLedgerBackend, insightDuration, insightsEmpty } from "@/entities/ledger";

const NOW = Date.UTC(2026, 10, 3, 12);

describe("insights", () => {
  it("writes durations in their largest unit and the next one", () => {
    expect(insightDuration(undefined, "en")).toBe("—");
    expect(insightDuration(0, "en")).toBe("0s");
    expect(insightDuration(45_000, "en")).toBe("45s");
    expect(insightDuration(12 * 60_000 + 5_000, "en")).toBe("12m 5s");
    expect(insightDuration(2 * 3_600_000 + 10 * 60_000 + 59_000, "en")).toBe("2h 10m");
    expect(insightDuration(3 * 86_400_000 + 30 * 60_000, "en")).toBe("3d");
    expect(insightDuration(-5, "en")).toBe("0s");
    expect(insightDuration(90_000, "ko")).toContain("1");
  });

  it("sizes bars against the largest value and always shows a value above zero", () => {
    expect(barShare(0, 10)).toBe(0);
    expect(barShare(10, 10)).toBe(100);
    expect(barShare(5, 10)).toBe(50);
    expect(barShare(1, 1000)).toBe(2);
    expect(barShare(3, 0)).toBe(100);
  });

  it("the demo counts its example sessions, questions, automatic answers and reports", async () => {
    const demo = new DemoLedgerBackend({ now: () => NOW });
    const week = await demo.call("insights", { range: "7d" });
    expect(week.range).toBe("7d");
    expect(week.reportsPerDay).toHaveLength(7);
    expect(Object.values(week.sessions.byVerdict).reduce((a, b) => a + b, 0)).toBe(week.sessions.total);
    expect(Object.values(week.sessions.byRole).reduce((a, b) => a + b, 0)).toBe(week.sessions.total);
    expect(week.sessions.total).toBeGreaterThan(0);
    expect(week.questions.open.count).toBeGreaterThan(0);
    expect(week.autoAnswers.byKind.reduce((n, k) => n + k.total, 0)).toBe(week.autoAnswers.total);
    expect(insightsEmpty(week)).toBe(false);
    const all = await demo.call("insights", { range: "all", project: "atlas" });
    expect(all.reportsPerDay).toHaveLength(90);
    expect(all.from).toBeUndefined();
    expect(all.project).toBe("atlas");
    const month = await demo.call("insights", { range: "30d" });
    expect(month.reportsPerDay).toHaveLength(30);
    expect(month.reports).toBeGreaterThanOrEqual(week.reports);
    const empty = await new DemoLedgerBackend({ empty: true, now: () => NOW }).call("insights", { range: "7d" });
    expect(insightsEmpty(empty)).toBe(true);
  });
});
