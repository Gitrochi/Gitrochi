import { createRoot } from "react-dom/client";
import { agents } from "@/entities/agent";
import { RepoStore } from "@/entities/repo";
import { AgentsPanel } from "@/widgets/sidebar";
import { ipc, type AgentScan } from "@/shared/api";
import { t } from "@/shared/i18n";

const pause = (ms = 40) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Agents in other apps from a fake process scan: listed under their app and folder, and a click brings the app forward. */
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
    // skip the shared five-second throttle so the fake scan is read now
    await agents.refreshExternal(Date.now() + 60_000);
    root.render(<AgentsPanel store={store} />); await pause(80);
    const rows = [...host.querySelectorAll<HTMLElement>(".external-agent")];
    ensure(host.textContent?.includes(t("Running in other apps")), "The section heading is missing");
    ensure(rows.map((r) => r.dataset.pid).join(",") === "100,200", `Only agents in this repository and its worktrees from other apps must show: ${rows.map((r) => r.dataset.pid)}`);
    ensure(rows[0].textContent?.includes("Windows Terminal") && rows[0].textContent.includes("main · src"), `First row: ${rows[0].textContent}`);
    ensure(rows[1].textContent?.includes("VS Code") && rows[1].textContent.includes("topic"), `Second row: ${rows[1].textContent}`);
    rows[0].click(); await pause();
    ensure(forwarded.join() === "10", `A click must bring the host app forward: ${forwarded}`);
    return [true, "Agents from a fake scan: Gitrochi's own and other folders left out, host app and folder shown, a click brings Windows Terminal forward"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    ipc.externalAgents = original.scan; ipc.bringAppForward = original.forward; agents.external = original.external;
  }
}
