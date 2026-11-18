import type { ScheduledRun } from "@/entities/ci";
import type { TrayItem } from "@/shared/api";
import { t } from "@/shared/i18n";

/**
 * What the tray menu lists while Gitrochi keeps running: the next scheduled runs, the open repositories with their
 * terminal tabs, recent repositories to open, then the app's own commands. Pure, and the same as the macOS functions
 * named beside each. (macOS: Core/BackgroundMenu.swift)
 */

/** How many scheduled runs and recent repositories the menu lists (macOS: BackgroundMenu.runLimit, recentLimit) */
export const menuRunLimit = 5;
export const menuRecentLimit = 5;

export interface MenuTerminal {
  id: string;
  title: string;
  /** The tab mark's word: "Running", "Waiting for input" … */
  state: string;
}

export interface MenuRepository {
  path: string;
  name: string;
  /** The terminals still alive, in tab order */
  terminals: MenuTerminal[];
}

export type BackgroundMenuItem =
  | { kind: "header"; title: string }
  /** A line that cannot be chosen ("No scheduled runs") */
  | { kind: "note"; title: string }
  | { kind: "separator" }
  | { kind: "run"; title: string; path: string }
  | { kind: "repository"; title: string; path: string }
  | { kind: "terminal"; title: string; path: string; id: string }
  | { kind: "recent"; title: string; path: string }
  | { kind: "open" | "settings" | "quit" };

type RunFields = Pick<ScheduledRun, "repoPath" | "workflowName" | "ref" | "runAt" | "state">;

const nameOf = (path: string) => path.split(/[\\/]/).filter(Boolean).pop() ?? path;

/** The runs still to start, soonest first (macOS: BackgroundMenu.upcoming) */
export function upcomingRuns<R extends RunFields>(runs: R[], limit = menuRunLimit): R[] {
  return runs.filter((run) => run.state === "scheduled").sort((a, b) => a.runAt - b.runAt).slice(0, limit);
}

/** "Nov 18, 12:30 PM · demo · Deploy (main)" (macOS: BackgroundMenu.runLine) */
export function runLine(run: RunFields, time: string): string {
  return `${time} · ${nameOf(run.repoPath)} · ${run.workflowName ?? t("Pipeline")} (${run.ref})`;
}

/** Recent repositories that are not open, most recent first (macOS: BackgroundMenu.recentToOpen) */
export function recentToOpen(recents: string[], open: string[], same: (a: string, b: string) => boolean, limit = menuRecentLimit): string[] {
  return recents.filter((recent) => !open.some((path) => same(path, recent))).slice(0, limit);
}

/** The whole menu, top to bottom (macOS: BackgroundMenu.items) */
export function backgroundMenu(input: {
  runs: RunFields[];
  time: (at: number) => string;
  repositories: MenuRepository[];
  recents: string[];
  same: (a: string, b: string) => boolean;
}): BackgroundMenuItem[] {
  const items: BackgroundMenuItem[] = [{ kind: "header", title: t("Scheduled runs") }];
  const next = upcomingRuns(input.runs);
  if (!next.length) items.push({ kind: "note", title: t("No scheduled runs") });
  for (const run of next) items.push({ kind: "run", title: runLine(run, input.time(run.runAt)), path: run.repoPath });
  if (input.repositories.length) {
    items.push({ kind: "separator" }, { kind: "header", title: t("Open repositories") });
    for (const repository of input.repositories) {
      items.push({ kind: "repository", title: repository.name, path: repository.path });
      for (const term of repository.terminals) items.push({ kind: "terminal", title: `${term.title} — ${term.state}`, path: repository.path, id: term.id });
    }
  }
  const recent = recentToOpen(input.recents, input.repositories.map((r) => r.path), input.same);
  if (recent.length) {
    items.push({ kind: "separator" }, { kind: "header", title: t("Recent repositories") });
    for (const path of recent) items.push({ kind: "recent", title: nameOf(path), path });
  }
  items.push({ kind: "separator" }, { kind: "open" }, { kind: "settings" }, { kind: "separator" }, { kind: "quit" });
  return items;
}

/** What quitting stops, or null when nothing would: "2 scheduled runs won't start. 1 terminal session will end." (macOS: BackgroundMenu.quitWarning) */
export function quitWarning(scheduled: number, terminals: number): string | null {
  const lines: string[] = [];
  if (scheduled === 1) lines.push(t("1 scheduled run won't start."));
  else if (scheduled > 1) lines.push(t("{0} scheduled runs won't start.", scheduled));
  if (terminals === 1) lines.push(t("1 terminal session will end."));
  else if (terminals > 1) lines.push(t("{0} terminal sessions will end.", terminals));
  return lines.length ? lines.join(" ") : null;
}

/** Runs that would not start if the app quit now (macOS: BackgroundMenu.pendingRuns) */
export const pendingRunCount = (runs: Pick<ScheduledRun, "state">[]) => runs.filter((run) => run.state === "scheduled").length;

/** What a tray line does once chosen */
export type TrayAction =
  | { kind: "repository" | "recent" | "run"; path: string }
  | { kind: "terminal"; path: string; id: string }
  | { kind: "open" | "settings" | "quit" };

/**
 * The tray's lines: headers and notes cannot be chosen, terminals sit indented under their repository (a tray menu has
 * no indentation of its own), and the rest carry what choosing them does as their id
 */
export function trayItems(items: BackgroundMenuItem[]): TrayItem[] {
  // a tray menu reads & as the next letter's shortcut
  const text = (label: string) => label.replace(/&/g, "&&");
  return items.map((item): TrayItem => {
    switch (item.kind) {
      case "separator": return { id: null, label: null, enabled: false };
      case "header": case "note": return { id: null, label: text(item.title), enabled: false };
      case "terminal": return { id: JSON.stringify({ kind: "terminal", path: item.path, id: item.id }), label: `    ${text(item.title)}`, enabled: true };
      case "run": case "repository": case "recent": return { id: JSON.stringify({ kind: item.kind, path: item.path }), label: text(item.title), enabled: true };
      case "open": return { id: JSON.stringify({ kind: "open" }), label: text(t("Open Gitrochi")), enabled: true };
      case "settings": return { id: JSON.stringify({ kind: "settings" }), label: text(t("Settings…")), enabled: true };
      case "quit": return { id: JSON.stringify({ kind: "quit" }), label: text(t("Quit Gitrochi")), enabled: true };
    }
  });
}

/** A chosen tray line's action, or null for an id this menu did not make */
export function trayAction(id: string): TrayAction | null {
  try {
    const value = JSON.parse(id) as Partial<TrayAction> & { path?: unknown; id?: unknown };
    if (value.kind === "open" || value.kind === "settings" || value.kind === "quit") return { kind: value.kind };
    if (typeof value.path !== "string") return null;
    if (value.kind === "terminal") return typeof value.id === "string" ? { kind: "terminal", path: value.path, id: value.id } : null;
    if (value.kind === "repository" || value.kind === "recent" || value.kind === "run") return { kind: value.kind, path: value.path };
    return null;
  } catch {
    return null;
  }
}
