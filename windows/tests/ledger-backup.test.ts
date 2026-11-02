import { afterEach, describe, expect, it, vi } from "vitest";
import { DemoLedgerBackend, type LedgerBackend, type LedgerMethod, type LedgerMethods, LedgerStore } from "@/entities/ledger";

const HOUR = 3_600_000;
const RETRY = 300_000;
const NOW = Date.UTC(2026, 10, 2, 9);

const harness = (kind: "native" | "demo", backup: () => Promise<unknown>) => {
  const demo = new DemoLedgerBackend({ empty: true });
  const calls: string[] = [];
  const backend: LedgerBackend = {
    kind,
    call: <M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]): Promise<LedgerMethods[M]["result"]> => {
      calls.push(method);
      if (method === "backup") {
        expect(args).toEqual({ daily: true });
        return backup() as Promise<LedgerMethods[M]["result"]>;
      }
      return demo.call(method,args);
    },
  };
  return { store: new LedgerStore(backend), calls };
};

describe("automatic Ledger snapshots", () => {
  afterEach(() => vi.useRealTimers());

  it("checks at most hourly for a native backend and leaves demos alone", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(NOW);
    const { store, calls } = harness("native", async () => ({ created: true }));
    await store.refresh(true);
    await store.refresh();
    expect(calls.filter((m) => m === "backup")).toHaveLength(1);
    vi.setSystemTime(NOW + HOUR - 1); await store.refresh();
    expect(calls.filter((m) => m === "backup")).toHaveLength(1);
    vi.setSystemTime(NOW + HOUR); await store.refresh();
    expect(calls.filter((m) => m === "backup")).toHaveLength(2);
    store.dispose();
    const d = harness("demo", async () => { throw new Error("Demo must not back up"); });
    await d.store.refresh(true); expect(d.calls).not.toContain("backup"); d.store.dispose();
  });

  it("does not block reads or duplicate an in-flight backup", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(NOW);
    let finish: ((value: unknown) => void) | undefined;
    const { store, calls } = harness("native", () => new Promise((resolve) => { finish = resolve; }));
    await store.refresh(true); expect(store.state).not.toBeNull();
    vi.setSystemTime(NOW + 2 * HOUR); await store.refresh();
    expect(calls.filter((m) => m === "backup")).toHaveLength(1);
    finish?.({ created: true }); await Promise.resolve();
    expect(store.error).toBeNull(); store.dispose();
  });

  it("retries a failed backup after five minutes without replacing UI errors", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(NOW);
    let attempts = 0;
    const { store, calls } = harness("native", async () => { if (++attempts === 1) throw new Error("Snapshot folder unavailable"); return { created: true }; });
    await store.refresh(true); expect(store.error).toBeNull();
    vi.setSystemTime(NOW + RETRY - 1); await store.refresh();
    expect(calls.filter((m) => m === "backup")).toHaveLength(1);
    vi.setSystemTime(NOW + RETRY); await store.refresh();
    expect(calls.filter((m) => m === "backup")).toHaveLength(2);
    expect(store.error).toBeNull(); store.dispose();
  });
});
