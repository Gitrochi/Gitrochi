import { tabStatus } from "@/widgets/terminal-panel";
import { agents } from "@/entities/agent";
import { scheduledRuns, scheduledRunTime } from "@/entities/ci";
import type { RepoStore } from "@/entities/repo";
import { tabActivity } from "@/entities/terminal";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { basename, keepRunningInBackground, recents, samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { backgroundMenu, type MenuRepository, pendingRunCount, quitWarning, trayAction, trayItems } from "./background-menu";

/**
 * Gitrochi in the background: closing the window hides it into the tray (a setting, on by default), so runs scheduled
 * for later still start and terminals keep running; the tray menu lists them, and quitting asks once when it stops
 * them. (macOS: App/MenuBar.swift › BackgroundMode)
 */

/** The open repositories, each with its terminals still alive */
function repositories(): MenuRepository[] {
  return workspace.tabs.filter((tab) => !!tab.path).map((tab) => ({
    path: tab.path!,
    name: basename(tab.path!),
    terminals: tab.terminals.filter((term) => term.running).map((term) => ({ id: term.id, title: term.title, state: tabStatus(term).title })),
  }));
}

/** Terminals that something runs in or that wait for input: quitting ends them */
function busyTerminals(): number {
  return workspace.tabs.flatMap((tab) => tab.terminals).filter((term) => {
    if (!term.running) return false;
    const { busy, waiting } = tabActivity(agents.statusIn(term), term.busy);
    return busy || waiting;
  }).length;
}

/** Quit Gitrochi from the tray or by closing the window with the setting off; asks once when that stops something */
export async function requestQuit() {
  const message = quitWarning(pendingRunCount(scheduledRuns.runs), busyTerminals());
  const store = workspace.active;
  if (!message || !store) return void ipc.quitApp();
  await ipc.showWindow();
  store.confirm = { title: t("Quit Gitrochi?"), message, actionTitle: t("Quit"), action: () => ipc.quitApp() };
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
    case "run": return void reveal(action.path, (store) => store.navigate("actions"));
    case "repository": case "recent": return void reveal(action.path);
    case "terminal":
      return void reveal(action.path, (store) => {
        const term = store.terminals.find((x) => x.id === action.id);
        if (term) store.focusTerminal(term);
      });
  }
}

/** Keeps the tray menu current and answers its lines and the window's close button; returns the stop */
export function startTray(): () => void {
  let sent = "";
  let timer: ReturnType<typeof setTimeout> | null = null;
  const update = () => {
    timer = null;
    const now = Date.now();
    const items = trayItems(backgroundMenu({
      runs: scheduledRuns.runs,
      time: (at) => scheduledRunTime(at, now),
      repositories: repositories(),
      recents: recents(),
      same: samePath,
    }));
    const visible = keepRunningInBackground();
    const key = JSON.stringify([items, visible]);
    if (key === sent) return;
    sent = key;
    ipc.trayUpdate(items, visible).catch(console.error);
  };
  const schedule = () => { timer ??= setTimeout(update, 250); };
  const stops = [workspace.subscribe(schedule), scheduledRuns.subscribe(schedule), settings.subscribe(schedule), agents.subscribe(schedule)];
  // a terminal's title and state change without the workspace hearing of it
  const interval = setInterval(update, 5000);
  const listening = [
    ipc.onTrayAction(choose),
    ipc.onCloseRequested(() => void (keepRunningInBackground() ? ipc.hideWindow() : requestQuit())),
  ];
  update();
  return () => {
    stops.forEach((stop) => stop());
    clearInterval(interval);
    if (timer) clearTimeout(timer);
    for (const listener of listening) void listener.then((unlisten) => unlisten());
  };
}
