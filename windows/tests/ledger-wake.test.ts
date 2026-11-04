import { describe, expect, it } from "vitest";
import { agentWaits, DEFAULT_WAKE, DemoLedgerBackend, wakeSetting } from "@/entities/ledger";
import { shapeErrors, specs } from "./ledger-fixtures";

const START = Date.UTC(2026, 10, 3, 9);

describe("Wake waiting agents with my answers", () => {
  it("says an agent waits only until its Stop hook's time is up, on the core's clock", () => {
    expect(agentWaits({}, START)).toBe(false);
    expect(agentWaits({ wakeUntil: START + 1 }, START)).toBe(true);
    expect(agentWaits({ wakeUntil: START }, START)).toBe(false);
    expect(agentWaits({ wakeUntil: START - 60_000 }, START)).toBe(false);
  });

  it("is off by default, with the longest wait the Stop hook allows", () => {
    expect(DEFAULT_WAKE).toEqual({ enabled: false, waitSec: 300 });
    expect(wakeSetting({})).toEqual(DEFAULT_WAKE);
    expect(wakeSetting({ wakeAgents: { enabled: true, waitSec: 60 } })).toEqual({ enabled: true, waitSec: 60 });
  });

  it("is checked by the demo as the core checks it", async () => {
    const backend = new DemoLedgerBackend({ now: () => START, lively: false });
    const defaults = await backend.call("settings", {});
    expect(defaults.wakeAgents).toEqual(DEFAULT_WAKE);
    expect(shapeErrors(defaults, specs.settings)).toEqual([]);
    for (const wakeAgents of [{ enabled: "yes" }, { waitSec: 9 }, { waitSec: 301 }, { waitSec: 30.5 }, true]) {
      await expect(backend.call("settings_set", { values: { wakeAgents } } as never)).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    }
    // a missing field takes its default, as in the core
    expect((await backend.call("settings_set", { values: { wakeAgents: { enabled: true } } } as never)).settings.wakeAgents).toEqual({ enabled: true, waitSec: 300 });
    expect((await backend.call("settings_set", { values: { wakeAgents: { enabled: true, waitSec: 45 } } })).settings.wakeAgents).toEqual({ enabled: true, waitSec: 45 });
    expect((await backend.call("settings_set", { values: { wakeAgents: null } })).settings.wakeAgents).toEqual(DEFAULT_WAKE);
  });

  it("keeps a waiting agent's time on its session in the contract's shape", async () => {
    const backend = new DemoLedgerBackend({ now: () => START, lively: false });
    const waiting = backend.world.sessions.find((s) => s.status === "active" && !s.archivedAt)!;
    waiting.wakeUntil = START + 120_000;
    const state = await backend.call("state", {});
    const session = state.sessions.find((s) => s.id === waiting.id)!;
    expect(session.wakeUntil).toBe(START + 120_000);
    expect(shapeErrors(session, specs.session)).toEqual([]);
    expect(agentWaits(session, state.now)).toBe(true);
  });
});
