import { createRoot } from "react-dom/client";
import { agents } from "@/entities/agent";
import { RepoStore } from "@/entities/repo";
import type { TerminalSession } from "@/entities/terminal";
import { AgentsPanel } from "@/widgets/sidebar";
import { ipc, type AgentScan } from "@/shared/api";
import { t } from "@/shared/i18n";

const pause = (ms = 40) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Agents in other apps from a fake process scan: listed under Elsewhere with their folder, and a click brings the app forward.
 * An agent typed into a tab of the terminal below shows under its worktree, and a click goes to that tab.
 */
export async function externalAgentsSelfTest(): Promise<[boolean, string]> {
  const original = { scan: ipc.externalAgents, forward: ipc.bringAppForward, external: agents.external };
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:320px;height:800px"; document.body.append(host);
  const root = createRoot(host);
  const forwarded: number[] = [];
  const terminal = { pid: 10, name: "WindowsTerminal.exe", window: true };
  const scan: AgentScan = {
    own: 900,
    processes: [
      { pid: 100, name: "claude.exe", args: [], cwd: "C:/fixture/agents/src", started: Math.floor(Date.now() / 1000) - 600, ancestors: [{ pid: 20, name: "pwsh.exe", window: false }, terminal] },
      { pid: 200, name: "node.exe", args: ["C:/npm/node_modules/@google/gemini-cli/dist/index.js"], cwd: "C:/fixture/agents-topic", started: 0, ancestors: [{ pid: 30, name: "Code.exe", window: true }] },
      { pid: 300, name: "claude.exe", args: [], cwd: "C:/fixture/agents", started: 0, ancestors: [{ pid: 900, name: "Gitrochi.exe", window: true }] },
      { pid: 400, name: "codex.exe", args: [], cwd: "D:/elsewhere", started: 0, ancestors: [terminal] },
      { pid: 500, name: "claude.exe", args: [], cwd: "C:/fixture/agents-topic/app", started: 0, ancestors: [{ pid: 50, name: "pwsh.exe", window: false }, { pid: 900, name: "Gitrochi.exe", window: true }] },
    ],
  };
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  try {
    ipc.externalAgents = async () => scan;
    ipc.bringAppForward = async (pid) => { forwarded.push(pid); };
    const store = new RepoStore();
    store.path = "C:/fixture/agents"; store.isActive = true;
    store.worktrees = [
      { path: "C:/fixture/agents", head: null, branch: "main", isMain: true, locked: false, prunable: false },
      { path: "C:/fixture/agents-topic", head: null, branch: "topic", isMain: false, locked: false, prunable: false },
    ];
    store.refreshWorktreeStats = async () => {};
    const tab = { pid: 50, running: true } as TerminalSession;
    const focused: TerminalSession[] = [];
    store.terminals = [tab];
    store.focusTerminal = (term) => { focused.push(term); };
    // skip the shared five-second throttle so the fake scan is read now
    await agents.refreshExternal(Date.now() + 60_000);
    root.render(<AgentsPanel store={store} />); await pause(80);
    const rows = [...host.querySelectorAll<HTMLElement>(".external-agent")];
    ensure(host.querySelector('[data-section="agent-elsewhere"]')?.textContent?.includes(t("Elsewhere")), "The section heading is missing");
    ensure(rows.map((r) => r.dataset.pid).join(",") === "100,200", `Only agents in this repository and its worktrees from other apps must show: ${rows.map((r) => r.dataset.pid)}`);
    const forwardLabel = (row: HTMLElement) => row.querySelector(".agent-forward")?.getAttribute("aria-label") ?? "";
    ensure(rows[0].textContent?.includes(`Claude Code · ${t("Running")}`) && rows[0].textContent.includes("main · src") && forwardLabel(rows[0]) === t("Bring {0} to the front", "Windows Terminal"), `First row: ${rows[0].textContent} / ${forwardLabel(rows[0])}`);
    ensure(rows[1].textContent?.includes("topic") && forwardLabel(rows[1]) === t("Bring {0} to the front", "VS Code"), `Second row: ${rows[1].textContent} / ${forwardLabel(rows[1])}`);
    rows[0].click(); await pause();
    rows[0].querySelector<HTMLButtonElement>(".agent-forward")!.click(); await pause();
    ensure(forwarded.join() === "10,10", `A click on the row or its button must bring the host app forward once each: ${forwarded}`);
    const worktrees = [...host.querySelectorAll<HTMLElement>(".agent-worktree")];
    const typed = [...host.querySelectorAll<HTMLElement>(".terminal-agent")];
    // a worktree's sessions follow its row, before the next worktree
    ensure(typed.length === 1 && worktrees.length === 2 && !!(worktrees[1].compareDocumentPosition(typed[0]) & Node.DOCUMENT_POSITION_FOLLOWING), `The agent typed into the terminal must show once, under the topic worktree: ${typed.length}`);
    ensure(typed[0].textContent?.includes("Claude Code") && typed[0].textContent.includes("app"), `Terminal agent row: ${typed[0].textContent}`);
    typed[0].click(); await pause();
    ensure(focused.length === 1 && focused[0] === tab, "A click must go to the terminal tab the agent runs in");
    return [true, "Agents from a fake scan: Gitrochi's own and other folders left out, host app and folder shown, a click brings Windows Terminal forward; one typed into the terminal shows under its worktree and a click goes to its tab"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    ipc.externalAgents = original.scan; ipc.bringAppForward = original.forward; agents.external = original.external;
  }
}
