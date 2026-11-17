import { createRoot } from "react-dom/client";
import { agents, type AgentSession } from "@/entities/agent";
import { RepoStore } from "@/entities/repo";
import { AgentsPanel } from "@/widgets/sidebar";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const pause = (ms = 40) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const until = async (test: () => boolean) => {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(20); }
  return false;
};

/**
 * The Agents sidebar from fixture sessions, at the sidebar's narrowest width: Needs you lists every session waiting for
 * the user, worktree rows show their state icon and right-aligned ahead/behind, every session row has one structure
 * with the terminal tab's marks, and an agent at work is "Running". The Worktrees section also carries what the Branches
 * tab's worktree list offered: a worktree whose folder is gone is marked, "Clean up" is in the head's ⋯ menu, and a
 * row's menu copies the path and force-removes.
 */
export async function agentsSidebarSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, scan: ipc.externalAgents, sessions: agents.sessions, external: agents.external, canFocus: agents.canFocus, focus: agents.focus };
  const memory = new Map<string, unknown>();
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:240px;height:900px;display:flex;flex-direction:column";
  document.body.append(host);
  const root = createRoot(host);
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const focused: string[] = [];
  const now = Math.floor(Date.now() / 1000);
  const session = (id: string, status: AgentSession["status"], path: string, updated: number, extra: Partial<AgentSession> = {}): AgentSession =>
    ({ id, kind: "claude", path, task: `Task of ${id} with a description long enough to wrap in a narrow sidebar`, mode: "", created: now - 3600, status, detail: null, updated, ...extra });
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); (settings as unknown as { emit(): void }).emit(); };
    ipc.externalAgents = async () => ({ own: 900, processes: [] });
    agents.external = [];
    agents.canFocus = (s) => s.status !== "ended";
    agents.focus = (s) => { focused.push(s.id); };
    agents.sessions = [
      session("working", "working", "C:/fixture/agents", now - 60),
      session("asking", "waiting", "C:/fixture/agents", now - 120, { mode: "bypassPermissions" }),
      session("permission", "permission", "C:/fixture/agents-topic", now - 600, { kind: "codex", detail: "Edit" }),
      session("fresh", "starting", "C:/fixture/agents-topic", now - 30, { task: "" }),
      session("done", "ended", "C:/fixture/agents-topic", now - 900),
      session("away", "waiting", "D:/another/repository", now - 300),
    ];
    const store = new RepoStore();
    store.path = "C:/fixture/agents"; store.isActive = true;
    store.worktrees = [
      { path: "C:/fixture/agents", head: null, branch: "feature/workspace-search-with-a-long-name", isMain: true, locked: false, prunable: false },
      { path: "C:/fixture/agents-topic", head: null, branch: "fix/flaky-tests", isMain: false, locked: false, prunable: false },
      { path: "C:/fixture/agents-gone", head: null, branch: "fix/gone", isMain: false, locked: false, prunable: true },
    ];
    let pruned = 0;
    store.pruneWorktrees = async () => { pruned++; return true; };
    store.worktreeStats = {
      "C:/fixture/agents": { added: 1, modified: 2, deleted: 0, conflicted: 0, ahead: 12, behind: 0, hasUpstream: true },
      "C:/fixture/agents-topic": { added: 0, modified: 1, deleted: 0, conflicted: 1, ahead: 1, behind: 2, hasUpstream: true },
    };
    store.refreshWorktreeStats = async () => {};
    root.render(<AgentsPanel store={store} />);
    ensure(await until(() => host.querySelectorAll(".agent-worktree").length === 3), "The worktree rows did not mount");
    const all = <T extends HTMLElement = HTMLElement>(selector: string) => [...host.querySelectorAll<T>(selector)];
    const text = (el: Element | null | undefined) => el?.textContent ?? "";

    // Needs you: every session waiting for the user, here or in another folder, the one waiting longest first
    const needs = all(".agent-need");
    ensure(needs.length === 3, `Needs you must list the three waiting sessions: ${needs.length}`);
    ensure(text(needs[0]).includes(t("Needs permission")) && text(needs[0]).includes("Codex · Edit"), `The permission card: ${text(needs[0])}`);
    ensure(text(needs[1]).includes(t("Waiting for input")) && text(needs[2]).includes(t("Waiting for input")), "The waiting cards say so");
    ensure(text(host.querySelector('[data-section="agent-needs"] .side-count')) === "3", "The Needs you count is missing");
    [...needs[0].querySelectorAll("button")].find((b) => b.textContent === t("Respond"))!.click();
    ensure(focused.join() === "permission", `Respond must go to the session's terminal: ${focused}`);

    // worktree rows: the current marker, one state icon, ahead and behind at the right edge
    const [main, topic, gone] = all(".agent-worktree");
    ensure(main.querySelector(".side-current") && !topic.querySelector(".side-current"), "Only the open worktree has the current marker");
    ensure(main.querySelector('.agent-state[data-state="changed"]') && topic.querySelector('.agent-state[data-state="conflict"]') && gone.querySelector('.agent-state[data-state="prunable"]') && all(".agent-state").length === 3, "Each worktree shows one state icon: uncommitted files, a conflict, or a folder that is gone");
    for (const row of [main, topic]) {
      const line = row.querySelector<HTMLElement>(".agent-worktree-line2")!.getBoundingClientRect();
      const pills = [...row.querySelectorAll<HTMLElement>(".agent-ab")].map((pill) => pill.getBoundingClientRect());
      ensure(pills.length > 0 && Math.abs(pills[pills.length - 1].right - line.right) <= 1, "Ahead and behind must sit at the row's right edge");
      ensure(pills.every((pill) => Math.round(pill.height) === 18), "An ahead or behind pill is 18px tall");
    }
    ensure(all(".agent-ab").map(text).join(" ") === "↑12 ↑1 ↓2", `Ahead and behind: ${all(".agent-ab").map(text)}`);
    ensure(text(topic.querySelector(".agent-worktree-path")) === "…/agents-topic", `A linked worktree shows its last folder: ${text(topic.querySelector(".agent-worktree-path"))}`);

    // one structure for every session row, with the terminal tab's marks
    const rows = () => all(".agent-session");
    const mark = (row?: HTMLElement) => row?.querySelector<HTMLElement>(".agent-session-line > .term-mark-slot > .term-mark")?.dataset.mark;
    const byStatus = (status: string) => rows().find((row) => row.dataset.status === status);
    ensure(rows().length === 5, `Sessions under their worktrees and elsewhere, ended ones folded away: ${rows().length}`);
    for (const row of rows()) {
      const main = row.firstElementChild, line = main?.firstElementChild;
      ensure(main?.className === "agent-session-main" && line?.className === "agent-session-line" && line.children.length === 2
        && line.children[0].className === "term-mark-slot" && line.children[1].className === "agent-session-text", `A session row lost the shared structure: ${row.outerHTML.slice(0, 200)}`);
    }
    ensure(mark(byStatus("working")) === "ring" && mark(byStatus("waiting")) === "dot" && mark(byStatus("permission")) === "dot" && mark(byStatus("starting")) === "none", `Marks: ${rows().map(mark)}`);
    ensure(byStatus("working")?.getAttribute("aria-label")?.includes(t("Running")) && !text(host).includes(t("Working")), "An agent at work is Running");
    ensure(byStatus("waiting")?.querySelector(".agent-session-skips") && all(".agent-session-skips").length === 1, "Only the session started without permission checks says so");
    ensure(text(host.querySelector('[data-section="agent-elsewhere"]')).includes("another"), "A session in another folder is listed under Elsewhere with its folder");
    byStatus("working")!.click();
    ensure(focused.join() === "permission,working", "A click on a session goes to its terminal");

    // ended sessions start folded under Ended
    const ended = host.querySelector<HTMLElement>('[data-section="agent-ended"]')!;
    ensure(text(ended).includes(t("Ended")) && !ended.querySelector(".agent-session"), "Ended sessions start folded away");
    ended.querySelector<HTMLElement>(".side-head .row")!.click();
    ensure(await until(() => mark(byStatus("ended")) === "hollow"), "An ended session shows the hollow mark");
    ensure(host.querySelector(".agents-more"), "The ⋯ menu shows while there are ended sessions");

    // what the Branches tab's worktree list offered: Clean up in the ⋯ menu, Copy path and Force remove… in a row's menu
    const menuItems = () => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")];
    const labelOf = (item: HTMLElement) => item.querySelector(".label")?.textContent ?? item.textContent?.trim() ?? "";
    const closeMenu = async () => { if (document.querySelector(".menu")) { window.dispatchEvent(new MouseEvent("mousedown")); await until(() => !document.querySelector(".menu")); } };
    gone.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 8, clientY: 8 }));
    ensure(await until(() => menuItems().length > 0), "A worktree row's menu did not open");
    const rowMenu = menuItems().map(labelOf);
    await closeMenu();
    ensure(rowMenu.includes(t("Copy path")) && rowMenu.at(-1) === t("Force remove…") && rowMenu.at(-2) === t("Remove worktree…"), `A worktree row's menu must copy the path and end with the two removals: ${rowMenu}`);
    host.querySelector<HTMLElement>(".agents-more")!.click();
    ensure(await until(() => menuItems().some((item) => labelOf(item) === t("Clean up"))), `The ⋯ menu must offer Clean up while a worktree's folder is gone: ${menuItems().map(labelOf)}`);
    menuItems().find((item) => labelOf(item) === t("Clean up"))!.click();
    ensure(await until(() => pruned === 1 && !document.querySelector(".menu")), "Clean up did not prune the worktrees and close the menu");

    // nothing clips or squeezes at the sidebar's narrowest width
    const panel = host.querySelector<HTMLElement>(".agents-panel")!, box = panel.getBoundingClientRect();
    ensure(panel.scrollWidth <= panel.clientWidth, `The panel scrolls sideways at 240px: ${panel.scrollWidth} > ${panel.clientWidth}`);
    for (const el of all(".agent-need, .agent-worktree, .agent-session, .agents-start, .agent-ab, .agent-state")) {
      const r = el.getBoundingClientRect();
      ensure(r.left >= box.left - 0.5 && r.right <= box.right + 0.5 && r.width > 0, `${el.className} leaves the 240px sidebar`);
    }
    const start = all<HTMLButtonElement>(".agents-start > button");
    ensure(start.length === 2 && start.every((b) => Math.round(b.getBoundingClientRect().height) === 28) && text(start[0]).includes(t("Start agent session…")), "Start agent session… and the quick start are 28px buttons");
    return [true, "Needs you lists the three waiting sessions; worktree rows show a state icon and right-aligned ahead/behind; five session rows share one structure with the tab marks; Running, not Working; ended sessions fold away; a gone folder is marked and Clean up, Copy path and Force remove… are at hand; nothing clips at 240px"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    // a menu left open would take the keys of every later step
    if (document.querySelector(".menu")) window.dispatchEvent(new MouseEvent("mousedown"));
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; ipc.externalAgents = original.scan;
    agents.sessions = original.sessions; agents.external = original.external; agents.canFocus = original.canFocus; agents.focus = original.focus;
  }
}
