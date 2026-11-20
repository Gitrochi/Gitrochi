import { tabStatus } from "@/widgets/terminal-panel";
import { agents } from "@/entities/agent";
import { scheduledRuns, scheduledRunTime } from "@/entities/ci";
import type { RepoStore } from "@/entities/repo";
import { readTerminalMeta, tabActivity } from "@/entities/terminal";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { basename, keepRunningInBackground, recents, samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { backgroundMenu, backgroundRepositories, type HostTerminal, type MenuRepository, pendingRunCount, quitWarning, trayAction, trayItems } from "./background-menu";

/**
 * Gitrochi in the background: closing the window can hide it into the tray (a setting, off by default), so runs
 * scheduled for later still start. Terminals outlive the app in the terminal host either way; the tray shows while
 * some belong to repositories that are not open, lists them, and offers to end them with the app. Quitting asks once
 * when it stops something. (macOS: App/MenuBar.swift › BackgroundMode)
 */

/** The open repositories, each with its terminals still alive */
function repositories(): MenuRepository[] {
  return workspace.tabs.filter((tab) => !!tab.path).map((tab) => ({
    path: tab.path!,
    name: basename(tab.path!),
    terminals: tab.terminals.filter((term) => term.running).map((term) => ({ id: term.id, title: term.title, state: tabStatus(term).title })),
  }));
}

/** Terminals that something runs in or that wait for input; hosted ones only when ending them too */
function busyTerminals(hostedToo: boolean): number {
  return workspace.tabs.flatMap((tab) => tab.terminals).filter((term) => {
    if (!term.running || (term.hosted && !hostedToo)) return false;
    const { busy, waiting } = tabActivity(agents.statusIn(term), term.busy);
    return busy || waiting;
  }).length;
}

/** Host terminals of repositories that are not open, as the tray last saw them */
let backgroundCount = 0;

/**
 * Quit Gitrochi from the tray or by closing the window with the setting off; asks once when that stops something.
 * Host terminals keep running unless endTerminals asks to end them too.
 */
export async function requestQuit(endTerminals = false) {
  const terminals = busyTerminals(endTerminals) + (endTerminals ? backgroundCount : 0);
  const message = quitWarning(pendingRunCount(scheduledRuns.runs), terminals);
  const quit = async () => {
    if (endTerminals) await ipc.ptyEndAll().catch(() => undefined);
    await ipc.quitApp();
  };
  const store = workspace.active;
  if (!message || !store) return void quit();
  await ipc.showWindow();
  store.confirm = { title: t("Quit Gitrochi?"), message, actionTitle: t("Quit"), action: () => void quit() };
  store.changed();
}

/** Shows the window with the repository's tab in front, opening it when it is not, then runs then on it */
async function reveal(path: string, then?: (store: RepoStore) => void) {
  await ipc.showWindow();
  await workspace.openInNewTab(path);
  const store = workspace.tabs.find((tab) => samePath(tab.path, path));
  if (store) then?.(store);
}

function choose(id: string) {
  const action = trayAction(id);
  if (!action) return;
  switch (action.kind) {
    case "open": return void ipc.showWindow();
    case "settings":
      void ipc.showWindow();
      window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "about" }));
      return;
    case "quit": return void requestQuit();
    case "quitAndEnd": return void requestQuit(true);
    case "run": return void reveal(action.path, (store) => store.navigate("actions"));
    case "repository": case "recent": return void reveal(action.path);
    case "terminal":
      return void reveal(action.path, async (store) => {
        // a terminal in the background is a host session: its tab comes back with the repository
        await store.restoreTerminals();
        const term = store.terminals.find((x) => x.id === action.id || x.hostSession === action.id);
        if (term) store.focusTerminal(term);
      });
  }
}

/** Keeps the tray menu current and answers its lines and the window's close button; returns the stop */
export function startTray(): () => void {
  let sent = "";
  let timer: ReturnType<typeof setTimeout> | null = null;
  const update = async () => {
    timer = null;
    const sessions = (await ipc.ptySessions().catch(() => [])).flatMap((s): HostTerminal[] => {
      const meta = readTerminalMeta(s.meta);
      return meta ? [{ id: s.id, running: s.running, repository: meta.repository, directory: meta.spec.directory, program: meta.spec.program, title: meta.spec.title }] : [];
    });
    const now = Date.now();
    const open = repositories();
    const background = backgroundRepositories(sessions, open.map((r) => r.path), samePath, t("Running"));
    backgroundCount = background.reduce((n, r) => n + r.terminals.length, 0);
    const items = trayItems(backgroundMenu({
      runs: scheduledRuns.runs,
      time: (at) => scheduledRunTime(at, now),
      repositories: open,
      background,
      recents: recents(),
      same: samePath,
    }));
    const visible = keepRunningInBackground() || background.length > 0;
    const key = JSON.stringify([items, visible]);
    if (key === sent) return;
    sent = key;
    ipc.trayUpdate(items, visible).catch(console.error);
  };
  const schedule = () => { timer ??= setTimeout(() => void update(), 250); };
  const stops = [workspace.subscribe(schedule), scheduledRuns.subscribe(schedule), settings.subscribe(schedule), agents.subscribe(schedule)];
  // a terminal's title and state change without the workspace hearing of it
  const interval = setInterval(() => void update(), 5000);
  const listening = [
    ipc.onTrayAction(choose),
    ipc.onCloseRequested(() => void (keepRunningInBackground() ? ipc.hideWindow() : requestQuit())),
  ];
  void update();
  return () => {
    stops.forEach((stop) => stop());
    clearInterval(interval);
    if (timer) clearTimeout(timer);
    for (const listener of listening) void listener.then((unlisten) => unlisten());
  };
}
