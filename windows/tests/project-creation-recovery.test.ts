import { afterEach, describe, expect, it, vi } from "vitest";
import {
  readCreationRecovery,
  saveCreationRecovery,
  clearCreationRecovery,
} from "../src/widgets/hosting-hub/lib/project-creation-recovery";
afterEach(() => vi.unstubAllGlobals());
describe("project creation reconciliation", () => {
  it("keeps uncertainty scoped by account and owner until explicit reconciliation", () => {
    const values = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
      removeItem: (key: string) => values.delete(key),
    });
    const key = "test-account:team";
    saveCreationRecovery(key, "created-project");
    expect(readCreationRecovery(key)?.projectID).toBe("created-project");
    expect(readCreationRecovery("other-account:team")).toBeUndefined();
    expect(readCreationRecovery("test-account:other-owner")).toBeUndefined();
    const raw = [...values.values()][0];
    expect(raw).not.toContain("token");
    expect(JSON.parse(raw)).toMatchObject({ projectID: "created-project" });
    clearCreationRecovery(key);
    expect(readCreationRecovery(key)).toBeUndefined();
  });
  it("retains a session lock when durable preferences are unavailable", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("Unavailable");
      },
      setItem: () => {
        throw new Error("Unavailable");
      },
      removeItem: () => {
        throw new Error("Unavailable");
      },
    });
    saveCreationRecovery("memory-account:owner");
    expect(readCreationRecovery("memory-account:owner")).toHaveProperty("at");
    clearCreationRecovery("memory-account:owner");
    expect(readCreationRecovery("memory-account:owner")).toBeUndefined();
  });
});
