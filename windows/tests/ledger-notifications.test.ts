import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { startLedgerNotifications } from "@/app/lib/ledger-notifications";
import { ledgerNotifier } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { initEnv, settings } from "@/shared/config";

// When the app starts the Ledger's notifications and taskbar badge (docs/ledger/DESIGN.md §10.11): each by its own switch
// in Settings › Ledger alone, with no environment variable, and nothing at all while both are off.

const keys = ["ledgerNotifications", "ledgerBadge", "ledgerAgentTools"];
afterEach(() => {
  for (const key of keys) settings.set(key, undefined);
  vi.restoreAllMocks();
});

describe("Ledger notifications at start-up", () => {
  it("start with their own switch alone, and read nothing while both are off", async () => {
    await initEnv({ os: "windows", home: "", dataDir: "", exe: "", temp: "", shell: "", version: "", selftest: null, selftestOpen: null, appData: "", localAppData: "", resourceDir: "" });
    for (const key of keys) settings.set(key, undefined);
    vi.spyOn(ipc, "writeText").mockResolvedValue();
    const listen = vi.spyOn(ipc, "onLedgerNotification").mockResolvedValue(() => {});
    const start = vi.spyOn(ledgerNotifier, "start").mockImplementation(() => {});
    const core = vi.spyOn(ipc, "ledgerCall").mockRejectedValue(new Error("Start-up must not read the ledger"));
    const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
    const counts = () => [listen.mock.calls.length, start.mock.calls.length, core.mock.calls.length];
    await startLedgerNotifications();
    // another setting changing, such as the tools switch, starts nothing
    settings.set("ledgerAgentTools", false);
    await settle();
    expect(counts()).toEqual([0, 0, 0]);
    settings.set("ledgerBadge", true);
    await vi.waitFor(() => expect(start).toHaveBeenCalledOnce());
    expect(listen).toHaveBeenCalledOnce();
    // the second switch does not start it twice
    settings.set("ledgerNotifications", true);
    await settle();
    expect(counts()).toEqual([1, 1, 0]);
  });

  it("start at once when a switch was already on", async () => {
    await initEnv({ os: "windows", home: "", dataDir: "", exe: "", temp: "", shell: "", version: "", selftest: null, selftestOpen: null, appData: "", localAppData: "", resourceDir: "" });
    vi.spyOn(ipc, "writeText").mockResolvedValue();
    settings.set("ledgerNotifications", true);
    const listen = vi.spyOn(ipc, "onLedgerNotification").mockResolvedValue(() => {});
    const start = vi.spyOn(ledgerNotifier, "start").mockImplementation(() => {});
    await startLedgerNotifications();
    expect([listen.mock.calls.length, start.mock.calls.length]).toEqual([1, 1]);
  });
});
