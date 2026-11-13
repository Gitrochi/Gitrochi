/**
 * The terminal panel's status and narrow-width rules, kept pure so both platforms decide alike.
 * macOS: Core/TerminalPanelLayout.swift (same names)
 */

/** The mark in a tab's 12px status slot: ring = a command runs, dot = unseen output or waiting for the user, hollow = exited */
export type TabMark = "ring" | "dot" | "hollow" | "none";
/** What the status line says about a terminal */
export type TerminalActivity = "running" | "idle" | "exited";

/** A tab shows its title down to this width; narrower and it moves into the » menu */
export const tabMinWidth = 120;
export const tabMaxWidth = 200;
/** The » button with its count */
export const overflowWidth = 44;
/** An icon button in the tab bar with its gap */
export const controlWidth = 28;

/** Whether the tab is busy or waits for the user. An agent session's own status wins over the shell's process state. */
export function tabActivity(agent: string | null, shellBusy: boolean): { busy: boolean; waiting: boolean } {
  if (agent === "working" || agent === "running") return { busy: true, waiting: false };
  if (agent === "permission" || agent === "waiting") return { busy: false, waiting: true };
  if (agent === "starting") return { busy: false, waiting: false };
  return { busy: shellBusy, waiting: false };
}

export function tabMark(s: { exited: boolean; busy: boolean; unseen: boolean; waiting: boolean }): TabMark {
  if (s.exited) return "hollow";
  if (s.unseen || s.waiting) return "dot";
  return s.busy ? "ring" : "none";
}

export const activity = (exited: boolean, busy: boolean): TerminalActivity => (exited ? "exited" : busy ? "running" : "idle");

/** The width left for tabs in a tab bar this wide with this many icon buttons */
export const tabStripWidth = (bar: number, controls: number) => Math.max(0, bar - 16 - controls * controlWidth - 8);

/** Which tabs stay in the bar and which go into the » menu, by index. The selected tab always stays. */
export function tabOverflow(count: number, selected: number | null, width: number): { visible: number[]; hidden: number[] } {
  if (count <= 0) return { visible: [], hidden: [] };
  const all = Array.from({ length: count }, (_, i) => i);
  if (count * tabMinWidth <= width) return { visible: all, hidden: [] };
  const fit = Math.min(count, Math.max(1, Math.floor((width - overflowWidth) / tabMinWidth)));
  const visible = all.slice(0, fit);
  if (selected !== null && selected >= fit && selected < count) visible[fit - 1] = selected;
  return { visible, hidden: all.filter((i) => !visible.includes(i)) };
}

/** New terminal and hide move into the actions menu when even one tab would not fit beside them */
export const compactBar = (width: number) => width < 260;

/** The command rail becomes one "Commands" menu below this width */
export const commandsFolded = (width: number) => width < 520;

/** "Insert, then Return" beside the commands goes when it would only show its first letters */
export const commandHintShown = (width: number) => width >= 320;

/** A short pane hides the command rail so the output keeps its lines */
export const railShown = (height: number) => height >= 140;

/** The status line drops the branch first, then the shell; the path and the state always stay */
export const statusLine = (width: number) => ({ branch: width >= 560, shell: width >= 320 });

/**
 * A shell is busy while it has more child processes than it does at the prompt (Windows has no foreground process
 * group to ask, as macOS does). `idle` is the fewest seen so far: a launcher such as Git Bash's keeps one child for
 * the whole session.
 */
export const shellBusy = (children: number, idle: number | null) => idle !== null && children > idle;
