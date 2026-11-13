import { createRoot } from "react-dom/client";
import { RepoPage } from "@/pages/repo";
import { addTab, panes, splitPane, tabOverflow, tabStripWidth, TerminalSession } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { MenuHost } from "@/shared/ui";
import { laneFixture } from "./graph-lanes-selftest";

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Waits for an effect instead of checking right after a render */
async function until(check: () => unknown, timeoutMs = 4000) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    if (check()) return true;
    if (Date.now() > end) return false;
    await sleep(30);
  }
}

function bufferText(session: TerminalSession) {
  const buffer = session.term.buffer.active;
  let text = "";
  for (let i = 0; i < buffer.length; i++) text += (buffer.getLine(i)?.translateToString(true) ?? "") + "\n";
  return text;
}

/**
 * The terminal panel on the real repository screen, with sessions that never start a process: it docks under the
 * centre column, marks tab status by shape, folds when narrow, and keeps every terminal view through layout changes.
 */
export async function terminalPanelSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion, run: ipc.run, http: ipc.http, write: ipc.writeText };
  // its own settings: no other step's saved widths, collapsed panels or panel height reach this one
  const memory = new Map<string, unknown>([["avatarFetch", false], ["inspectorWidth", 340], ["sidebarWidth", 240], ["terminalHeight", 260], ["recentRepositories", []]]);
  const listeners = new Set<() => void>();
  let version = 0;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1440px;height:720px";
  document.body.append(host);
  const root = createRoot(host);
  const store = laneFixture(6);
  store.destination = "repository";
  store.headBranch = "feature/terminal-dock";
  store.loadGlobalIdentity = async () => {};
  store.refreshWorktreeStats = async () => {};
  const sessions: TerminalSession[] = [];
  /** A terminal that counts as started, so mounting it opens its screen but never a shell */
  const inert = (title: string, program?: string) => {
    const session = new TerminalSession({ directory: store.path!, title, program });
    session.started = true;
    session.running = true;
    session.busy = !!program;
    session.subscribe(() => store.changed());
    sessions.push(session);
    return session;
  };
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const soon = async (check: () => unknown, message: () => string) => { if (!(await until(check))) throw new Error(message()); };
  const all = <T extends HTMLElement = HTMLElement>(selector: string, within: ParentNode = host) => [...within.querySelectorAll<T>(selector)];
  const one = <T extends HTMLElement = HTMLElement>(selector: string, within: ParentNode = host) => within.querySelector<T>(selector);
  const box = (selector: string) => one(selector)!.getBoundingClientRect();
  const near = (a: number, b: number) => Math.abs(a - b) <= 1;
  const marks = () => all(".term-tab .term-mark").map((mark) => mark.dataset.mark);
  const paneNodes = () => all(".term-pane");
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); version++; listeners.forEach((listener) => listener()); };
    settings.subscribe = (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
    settings.getVersion = () => version;
    ipc.run = async () => { throw new Error("Terminal fixture blocked process"); };
    ipc.http = async () => { throw new Error("Terminal fixture blocked network"); };
    ipc.writeText = async () => { throw new Error("Terminal fixture blocked write"); };

    const shell = inert("desktop"), agent = inert("Claude Code", "claude"), logs = inert("npm run dev"), done = inert("Codex review");
    done.running = false;
    done.exitCode = 0;
    logs.unseenOutput = true;
    store.terminals = [shell, agent, logs, done];
    store.terminalLayout = [shell, agent, logs, done].reduce<ReturnType<typeof addTab> | null>((layout, session) => addTab(layout, layout ? panes(layout)[0].id : null, session.id), null);
    store.activeTerminalID = shell.id;
    store.showTerminal = true;
    root.render(<><RepoPage store={store} openSettings={() => {}} /><MenuHost /></>);

    // 1. the dock: under the centre column, with the sidebar and the right panel at full height
    await soon(() => one(".repository-screen > .center > .term-panel") && shell.host.isConnected, () => "The panel must sit in the centre column with its terminal attached");
    const screen = box(".repository-screen"), sidebar = box(".repository-screen > .sidebar"), inspector = box(".repository-screen > .inspector");
    const center = box(".repository-screen > .center"), panel = box(".term-panel");
    ensure(near(sidebar.top, screen.top) && near(sidebar.bottom, screen.bottom) && near(inspector.top, screen.top) && near(inspector.bottom, screen.bottom),
      `The sidebar and the right panel must keep the full height: sidebar ${sidebar.height}, right ${inspector.height}, screen ${screen.height}`);
    ensure(panel.left >= sidebar.right - 1 && panel.right <= inspector.left + 1 && near(panel.width, center.width) && near(panel.bottom, center.bottom) && near(panel.height, 260),
      `The panel must span only the centre column at its saved height: ${panel.left}-${panel.right} in ${center.left}-${center.right}, height ${panel.height}`);

    // 2. tab status by shape, in a slot every tab reserves; no logo
    await soon(() => marks().join() === "none,ring,dot,hollow", () => `Idle, running, unseen and exited tabs must show nothing, a ring, a dot and a hollow circle: ${marks()}`);
    const slots = all(".term-tab .term-mark-slot").map((slot) => slot.getBoundingClientRect());
    const numbers = all(".term-tab").map((tab) => one(".term-tab-n", tab)!.getBoundingClientRect().left - tab.getBoundingClientRect().left);
    ensure(slots.length === 4 && slots.every((slot) => slot.width === 12 && slot.height === 12) && numbers.every((left) => near(left, numbers[0])), `Every tab must reserve the 12px slot so titles do not shift: ${slots.map((slot) => slot.width)} ${numbers}`);
    // sizes and stroke, not colours: a border width is rounded to device pixels, so only whether there is one counts
    const shapes = all(".term-tab .term-mark").map((mark) => { const style = getComputedStyle(mark); return [style.width, parseFloat(style.borderTopWidth) > 0 ? "stroked" : "plain", style.backgroundColor === "rgba(0, 0, 0, 0)" ? "open" : "filled"].join("/"); });
    ensure(shapes.join() === "0px/plain/open,9px/stroked/open,6px/plain/filled,7px/stroked/open", `The marks must differ by shape, not only by colour: ${shapes}`);
    const bar = one(".term-bar")!;
    ensure(bar.firstElementChild?.classList.contains("term-tabs") && !one(":scope > svg, :scope > img", bar), "The tab bar must start with the tabs: no logo");
    ensure(one(".term-status-state")!.dataset.state === "idle" && one(".term-status-unseen"), "The status line must say Idle and count the tab with new output");
    all<HTMLButtonElement>(".term-tab-select")[1].click();
    await soon(() => one(".term-status-state")?.dataset.state === "running" && all(".term-tab-select")[1].getAttribute("aria-selected") === "true", () => "Selecting the agent tab must show it and say Running");
    one<HTMLButtonElement>(".term-status-unseen")!.click();
    await soon(() => store.activeTerminal === logs && !one(".term-status-unseen") && marks().join() === "none,ring,none,hollow", () => `The unseen count must go to that terminal and clear its dot: ${marks()}`);
    store.selectTerminal(shell);

    // 3. wide: every command, the branch and the shell; a command is inserted, not run
    await soon(() => all(".term-cmd").length === 4 && !one(".term-cmd.commands") && one(".term-status-branch") && one(".term-status-shell"), () => "A wide panel must show the four commands, the branch and the shell");
    const typed: string[] = [];
    const listening = shell.term.onData((data) => typed.push(data));
    all<HTMLButtonElement>(".term-cmd")[0].click();
    await soon(() => typed.join("").includes("gitch ck"), () => `A command must be inserted into the terminal: ${JSON.stringify(typed)}`);
    ensure(!/[\r\n]/.test(typed.join("")), "An inserted command must wait for Enter");
    listening.dispose();

    // 4. the terminal views survive every layout change
    shell.term.write("KEEP-SCROLLBACK\r\n");
    await soon(() => bufferText(shell).includes("KEEP-SCROLLBACK"), () => "The fixture terminal must take output");
    shell.focus();
    const mount = shell.host.parentElement!, screenNode = shell.term.element;
    const kept = (what: string, sameMount: boolean) => soon(
      () => shell.host.isConnected && one(".term-panel")?.contains(shell.host) && shell.term.element === screenNode && bufferText(shell).includes("KEEP-SCROLLBACK") && (!sameMount || (shell.host.parentElement === mount && shell.host.contains(document.activeElement))),
      () => `${what} must keep the terminal's screen, scrollback${sameMount ? ", mount and focus" : ""}: connected=${shell.host.isConnected} mount=${shell.host.parentElement === mount} focus=${shell.host.contains(document.activeElement)}`,
    );
    settings.set("inspectorCollapsed", true);
    await soon(() => one(".repository-screen > .inspector")!.hidden, () => "The right panel must hide");
    await kept("Hiding the right panel", true);
    ensure(near(box(".term-panel").width, box(".repository-screen > .center").width) && box(".term-panel").width > panel.width, "The docked panel must take the freed width");
    settings.set("sidebarCollapsed", true);
    await soon(() => one(".repository-screen > .sidebar-rail"), () => "The branch list must fold into its rail");
    await kept("Folding the sidebar", true);
    settings.set("sidebarCollapsed", false);
    settings.set("inspectorCollapsed", false);
    await soon(() => one(".repository-screen > .sidebar") && !one(".repository-screen > .inspector")!.hidden, () => "Both side columns must come back");
    await kept("Showing the side columns again", true);
    // the Agents page is the sidebar's other mode: the same panel stays under the centre column
    settings.set("sidebarMode", "agents");
    await kept("Opening the Agents page", true);
    ensure(one(".repository-screen > .center > .term-panel") && near(box(".repository-screen > .sidebar").bottom, box(".repository-screen").bottom), "The Agents page must use the same docked panel");
    settings.set("sidebarMode", "list");
    // another worktree in the same tab
    const repository = store.path;
    store.path = "C:/fixture/graph-lanes-worktree"; store.changed();
    await kept("Switching worktrees", true);
    store.path = repository; store.changed();
    store.destination = "issues"; store.changed();
    await soon(() => one(".workspace-pane > .term-panel"), () => "Another page must show the panel below it");
    await kept("Switching pages", false);
    store.destination = "repository"; store.changed();
    await soon(() => one(".repository-screen > .center > .term-panel"), () => "The repository screen must dock the panel again");
    await kept("Returning to the repository screen", false);

    // 5. more tabs than fit go into »; the selected one stays in the bar
    const extra = ["gitch preflight", "Gemini plan", "Release checks", "Unit tests", "Build"].map((title) => inert(title));
    store.terminals = [...store.terminals, ...extra];
    for (const session of extra) store.terminalLayout = addTab(store.terminalLayout, panes(store.terminalLayout!)[0].id, session.id);
    store.selectTerminal(shell);
    const expected = () => tabOverflow(9, store.terminals.indexOf(store.activeTerminal!), tabStripWidth(paneNodes()[0].clientWidth, 3));
    await soon(() => all(".term-tab").length === expected().visible.length && expected().hidden.length > 0 && one(".term-overflow")?.textContent === String(expected().hidden.length),
      () => `Tabs that do not fit must move into »: ${all(".term-tab").length} tabs, » ${one(".term-overflow")?.textContent}, expected ${JSON.stringify(expected())}`);
    ensure(all(".term-tab").every((tab) => tab.getBoundingClientRect().width >= 119), `A tab in the bar must keep its title readable: ${all(".term-tab").map((tab) => tab.getBoundingClientRect().width)}`);
    one<HTMLButtonElement>(".term-overflow")!.click();
    await soon(() => all(".menu .menu-item").length === expected().hidden.length, () => `The » menu must list the hidden terminals: ${all(".menu .menu-item", document).length}`);
    const last = extra[extra.length - 1];
    all(".menu .menu-item").find((item) => item.textContent?.includes(last.title))!.click();
    await soon(() => store.activeTerminal === last && one(".term-tab.on")?.textContent?.includes(last.title) && !one(".menu"), () => "Choosing a terminal in » must select it and keep it in the bar");

    // 6. narrow panes fold: commands into one menu, then the branch, then the shell
    store.terminals = [shell, agent, logs, done];
    for (const session of extra) session.dispose();
    store.terminalLayout = panes(store.terminalLayout!)[0] && { ...panes(store.terminalLayout!)[0], sessions: [shell.id, agent.id], selected: shell.id };
    store.terminalLayout = splitPane(store.terminalLayout!, panes(store.terminalLayout!)[0].id, "row", logs.id);
    store.selectTerminal(shell);
    await soon(() => paneNodes().length === 2 && paneNodes().every((pane) => pane.clientWidth < 520 && one(".term-cmd.commands", pane) && all(".term-cmd", pane).length === 1 && !one(".term-status-branch", pane) && one(".term-status-shell", pane)),
      () => `Two panes side by side must fold the commands and drop the branch but keep the shell: ${paneNodes().map((pane) => `${pane.clientWidth}:${all(".term-cmd", pane).length}`)}`);
    ensure(all(".term-hide").length === 1 && one(".term-hide", paneNodes()[1]) && paneNodes()[1].classList.contains("unfocused") && !paneNodes()[0].classList.contains("unfocused"), "Hide appears once, in the corner pane, and only the focused pane keeps the accent underline");
    one<HTMLButtonElement>(".term-cmd.commands", paneNodes()[0])!.click();
    await soon(() => all(".menu .menu-item").length === 4 && all(".menu .menu-item")[0].textContent?.includes("gitch ck"), () => "The Commands menu must list the four commands with what they insert");
    const chosen: string[] = [];
    const choosing = shell.term.onData((data) => chosen.push(data));
    all(".menu .menu-item")[1].click();
    await soon(() => chosen.join("").includes("gitch preflight") && !one(".menu"), () => `Choosing in the Commands menu must insert that command: ${JSON.stringify(chosen)}`);
    choosing.dispose();
    store.terminalLayout = splitPane(store.terminalLayout!, panes(store.terminalLayout!)[1].id, "row", done.id);
    store.selectTerminal(shell);
    // without the right panel the centre is wide enough for a quarter of it to land between the two widths
    settings.set("inspectorCollapsed", true);
    await soon(() => paneNodes().length === 3 && paneNodes()[2].clientWidth < 320 && paneNodes()[2].clientWidth >= 260, () => `The fixture needs a pane between 260 and 320px: ${paneNodes().map((pane) => pane.clientWidth)}`);
    await soon(() => !one(".term-status-shell", paneNodes()[2]) && !one(".term-rail-hint", paneNodes()[2]) && one(".term-rail-hint", paneNodes()[0]) && one(".term-status-state", paneNodes()[2])?.dataset.state === "exited" && one(".term-status-path", paneNodes()[2]) && one(".term-mark.hollow", paneNodes()[2]),
      () => "The narrowest pane must drop the shell too and keep the path, the state and the tab's mark");
    ensure(shell.host.isConnected && bufferText(shell).includes("KEEP-SCROLLBACK") && panes(store.terminalLayout!).length === 3, "Splitting must keep the first terminal and its scrollback");
    settings.set("terminalHeight", 120);
    await soon(() => !one(".term-rail") && all(".term-bar").length === 3 && all(".term-status").length === 3, () => "A short panel must hide the command rail and keep the tab bars and status lines");
    return [true, "Docked under the centre column with full-height sidebar and right panel, also on the Agents page; ring, dot and hollow marks in a reserved 12px slot and no logo; commands insert without running; screen, scrollback, mount and focus survive hiding either side column, the Agents page and a worktree switch, and the screen survives page switches; extra tabs go into » with the selected one kept; narrow panes fold the commands, then drop the branch, then the shell; a short panel hides the rail"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    for (const session of sessions) session.dispose();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
    ipc.run = original.run; ipc.http = original.http; ipc.writeText = original.write;
  }
}
