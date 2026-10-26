/**
 * Split terminal panes: a binary tree whose leaves hold terminal tabs (session ids). Pure functions, new tree each time.
 * macOS: Services/TerminalLayout.swift
 */

export type TermPane = { kind: "pane"; id: string; sessions: string[]; selected: string | null };
/** row: side by side (split right), column: stacked (split down); ratio is the first child's share */
export type TermSplit = { kind: "split"; id: string; axis: "row" | "column"; ratio: number; a: TermNode; b: TermNode };
export type TermNode = TermPane | TermSplit;

const newPane = (sessions: string[]): TermPane => ({ kind: "pane", id: crypto.randomUUID(), sessions, selected: sessions[sessions.length - 1] ?? null });

export function panes(n: TermNode): TermPane[] {
  return n.kind === "pane" ? [n] : [...panes(n.a), ...panes(n.b)];
}

export const paneOf = (n: TermNode | null, session: string | null) => (n && session ? (panes(n).find((p) => p.sessions.includes(session)) ?? null) : null);

/** The tab a pane shows: the focused session if it is here, otherwise the pane's own choice */
export const shownIn = (p: TermPane, active: string | null) => (active && p.sessions.includes(active) ? active : p.selected);

function mapPanes(n: TermNode, f: (p: TermPane) => TermNode): TermNode {
  return n.kind === "pane" ? f(n) : { ...n, a: mapPanes(n.a, f), b: mapPanes(n.b, f) };
}

/** Adds a tab to the pane (the first pane if it is gone), or starts the layout */
export function addTab(root: TermNode | null, paneId: string | null, session: string): TermNode {
  if (!root) return newPane([session]);
  const all = panes(root);
  const target = all.find((p) => p.id === paneId) ?? all[0];
  return mapPanes(root, (p) => (p.id === target.id ? { ...p, sessions: [...p.sessions, session], selected: session } : p));
}

/** Puts a new pane with the session beside (row) or below (column) the pane */
export function splitPane(root: TermNode, paneId: string, axis: TermSplit["axis"], session: string): TermNode {
  return mapPanes(root, (p) => (p.id === paneId ? { kind: "split", id: crypto.randomUUID(), axis, ratio: 0.5, a: p, b: newPane([session]) } : p));
}

export function selectTab(root: TermNode, session: string): TermNode {
  return mapPanes(root, (p) => (p.sessions.includes(session) ? { ...p, selected: session } : p));
}

/** Removes the tab; an emptied pane goes away and its sibling takes the split's place. null when nothing is left. */
export function removeTab(root: TermNode, session: string): TermNode | null {
  if (root.kind === "pane") {
    const i = root.sessions.indexOf(session);
    if (i < 0) return root;
    const sessions = root.sessions.filter((s) => s !== session);
    if (!sessions.length) return null;
    return { ...root, sessions, selected: root.selected === session ? sessions[Math.min(i, sessions.length - 1)] : root.selected };
  }
  const a = removeTab(root.a, session);
  const b = removeTab(root.b, session);
  if (!a) return b;
  if (!b) return a;
  return a === root.a && b === root.b ? root : { ...root, a, b };
}

export function setRatio(root: TermNode, splitId: string, ratio: number): TermNode {
  if (root.kind === "pane") return root;
  if (root.id === splitId) return { ...root, ratio: Math.min(0.85, Math.max(0.15, ratio)) };
  return { ...root, a: setRatio(root.a, splitId, ratio), b: setRatio(root.b, splitId, ratio) };
}

/** The top-right pane, which carries the panel's own buttons */
export function cornerPane(n: TermNode): TermPane {
  return n.kind === "pane" ? n : cornerPane(n.axis === "row" ? n.b : n.a);
}
