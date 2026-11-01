import { describe, expect, it } from "vitest";
import { type LedgerLauncher, overviewArguments, quickLaunchItems } from "@/widgets/ledger-workspace/lib/quick-launch";
import type { MenuItem } from "@/shared/ui";

// The Ledger page's quick launches (docs/ledger/DESIGN.md P4): through the repository tab's terminal and Run agent only.

const CLI = "C:/Program Files/Gitrochi/gitrochi-ledger.exe";
const REPO = "C:/Work/atlas";
type Item = Exclude<MenuItem, "divider">;

function launcher() {
  const terminals: unknown[][] = [], agents: unknown[][] = [];
  const l: LedgerLauncher = { newTerminal: (...args) => void terminals.push(args), startAgent: async (...args) => void agents.push(args) };
  return { l, terminals, agents };
}

describe("Ledger quick launches", () => {
  it("opens the overview of the project shown in a new tab of the terminal", () => {
    const { l, terminals, agents } = launcher();
    const [overview] = quickLaunchItems({ launcher: l, repoPath: REPO, project: "atlas", cli: CLI, demo: false }) as Item[];
    expect(overview).toMatchObject({ label: "Ledger overview", disabled: false });
    overview.onClick!();
    expect(terminals).toEqual([[REPO, { program: CLI, args: ["overview", "-p", "atlas"], title: "Ledger overview" }]]);
    expect(agents).toEqual([]);
    // with all projects shown, the CLI picks the most recently active one
    expect(overviewArguments(null)).toEqual(["overview"]);
  });

  it("starts Claude Code as Run agent does, so Track agents I start covers it", () => {
    const { l, terminals, agents } = launcher();
    const [, claude] = quickLaunchItems({ launcher: l, repoPath: REPO, project: null, cli: null, demo: false }) as Item[];
    expect(claude.disabled).toBeFalsy();
    claude.onClick!();
    expect(agents).toEqual([[REPO, "", null, "claude"]]);
    expect(terminals).toEqual([]);
  });

  it("leaves the overview off without the CLI, and on the demo data", () => {
    const { l, terminals } = launcher();
    const [missing] = quickLaunchItems({ launcher: l, repoPath: REPO, project: "atlas", cli: null, demo: false }) as Item[];
    expect(missing.disabled).toBe(true);
    expect(missing.tip).toContain("gitrochi-ledger.exe was not found next to Gitrochi.");
    const [demo] = quickLaunchItems({ launcher: l, repoPath: REPO, project: "atlas", cli: CLI, demo: true }) as Item[];
    expect(demo.disabled).toBe(true);
    expect(demo.tip).toContain("GITROCHI_LEDGER_DEMO");
    missing.onClick!();
    demo.onClick!();
    expect(terminals).toEqual([]);
  });
});
