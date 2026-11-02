import { describe, expect, it } from "vitest";
import { advanceLearningDelivery, canAdvanceLedgerLearning, ledgerLearningSteps, ledgerLearningTopics, readLedgerLearning, searchLedgerGuide } from "@/entities/ledger";

describe("Ledger learning progress", () => {
  it("starts safely from missing, foreign or malformed local settings", () => {
    const initial = { version: 1, step: 0, completed: false, answerSent: false, deliveryState: "saved" };
    for (const value of [null, undefined, true, 4, "a setting", [], { version: 2, step: 4, completed: true }, { version: 1, step: NaN }]) expect(readLedgerLearning(value)).toEqual(initial);
    expect(readLedgerLearning({ version: 1, step: -20 }).step).toBe(0);
  });

  it("does not restore past an unfinished practice or claim an invalid completion", () => {
    expect(readLedgerLearning({ version: 1, step: 99, completed: true, deliveryState: "archived" })).toMatchObject({ step: 2, completed: false, answerSent: false, deliveryState: "saved" });
    expect(readLedgerLearning({ version: 1, step: 4, answerSent: true, deliveryState: "delivered", completed: true })).toMatchObject({ step: 3, completed: false });
    expect(readLedgerLearning({ version: 1, step: 4, answerSent: true, deliveryState: "unknown" })).toMatchObject({ step: 3, deliveryState: "saved" });
  });

  it("restores completed practice and keeps completion while revisiting an earlier step", () => {
    const finished = { version: 1, step: 4, completed: true, answerSent: true, deliveryState: "archived" };
    expect(readLedgerLearning(finished)).toEqual(finished);
    expect(readLedgerLearning({ ...finished, step: 1 })).toMatchObject({ step: 1, completed: true });
    expect(JSON.stringify(readLedgerLearning({ ...finished, draft: "Private practice text", sessionId: "real-session" }))).not.toMatch(/Private|real-session|draft|sessionId/);
  });

  it("requires an explicit practice answer, then delivery, confirmation and cleanup", () => {
    let progress = readLedgerLearning({ version: 1, step: 2 });
    expect(canAdvanceLedgerLearning(progress)).toBe(false);
    progress = { ...progress, answerSent: true };
    expect(canAdvanceLedgerLearning(progress)).toBe(true);
    progress.step = 3;
    for (const state of ["saved", "delivered", "confirmed"] as const) {
      expect(progress.deliveryState).toBe(state);
      expect(canAdvanceLedgerLearning(progress)).toBe(false);
      progress.deliveryState = advanceLearningDelivery(progress.deliveryState);
    }
    expect(progress.deliveryState).toBe("archived");
    expect(canAdvanceLedgerLearning(progress)).toBe(true);
    expect(advanceLearningDelivery("archived")).toBe("archived");
  });

  it("has five mirrored tutorial steps and every required guide topic", () => {
    expect(ledgerLearningSteps).toEqual(["concepts", "views", "answer", "delivery", "connect"]);
    expect(ledgerLearningTopics.map((topic) => topic.id)).toEqual(["setup", "concepts", "views", "answers", "delivery", "cleanup", "shortcuts", "troubleshooting", "privacy"]);
  });
});

describe("Ledger usage guide search", () => {
  it("finds all typed words across translated text and practical terms", () => {
    expect(searchLedgerGuide("  custom   multiple ").map((topic) => topic.id)).toEqual(["answers"]);
    expect(searchLedgerGuide("COPY clipboard").map((topic) => topic.id)).toEqual(["delivery"]);
    expect(searchLedgerGuide("STILL ACTIVE").map((topic) => topic.id)).toEqual(["cleanup"]);
    expect(searchLedgerGuide("연결", (key) => key === "Setup" ? "연결" : key).map((topic) => topic.id)).toEqual(["setup"]);
    expect(searchLedgerGuide("복사", (key) => key.startsWith("Use Copy answer") ? "저장된 답변을 복사합니다." : key).map((topic) => topic.id)).toEqual(["delivery"]);
    expect(searchLedgerGuide("[missing.*")).toEqual([]);
  });
});
