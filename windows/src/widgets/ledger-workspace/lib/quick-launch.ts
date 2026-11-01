import type { AgentKind } from "@/entities/agent";
import type { TerminalSpec } from "@/entities/terminal";
import { t } from "@/shared/i18n";
import type { MenuItem } from "@/shared/ui";

/** What the quick launches use of the repository's tab: a new tab in its terminal panel, and its Run agent action */
export interface LedgerLauncher {
  newTerminal(path?: string, spec?: Partial<TerminalSpec>): unknown;
  startAgent(path: string, task?: string, mode?: string | null, kind?: AgentKind): Promise<void>;
}

/** The bundled CLI's overview of a project, or of the most recent one without it: the text agents read */
export const overviewArguments = (project: string | null) => ["overview", ...(project ? ["-p", project] : [])];

/**
 * The Ledger page's quick launches (docs/ledger/DESIGN.md P4), through the tab's existing APIs only: the overview of the
 * project shown in a new terminal tab, and Claude Code started as Run agent starts it, so Track agents I start covers it.
 * The overview reads the ledger database, so it needs the bundled CLI and is off on the demo data.
 */
export function quickLaunchItems(o: { launcher: LedgerLauncher; repoPath: string; project: string | null; cli: string | null; demo: boolean }): MenuItem[] {
  const overviewTip = o.demo
    ? `${t("Demo data")}|${t("GITROCHI_LEDGER_DEMO is set, so the Ledger shows example sessions instead of the ledger database.")}`
    : `${t("Ledger overview")}|${t(o.cli ? "What agents read about this project, in a new tab of the terminal below." : "gitrochi-ledger.exe was not found next to Gitrochi.")}`;
  return [
    {
      label: t("Ledger overview"),
      disabled: o.demo || !o.cli,
      tip: overviewTip,
      onClick: () => {
        if (o.cli && !o.demo) o.launcher.newTerminal(o.repoPath, { program: o.cli, args: overviewArguments(o.project), title: t("Ledger overview") });
      },
    },
    {
      label: "Claude Code",
      tip: `Claude Code|${t("Runs in a new tab of the terminal below; its status is shown in the Agents tab.")}`,
      onClick: () => void o.launcher.startAgent(o.repoPath, "", null, "claude"),
    },
  ];
}
