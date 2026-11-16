/** The words of the Agents sidebar that do not depend on the screen. (macOS: AgentsPanelText in AgentsPanel.swift) */

/** A long task is cut here in a Needs you card, which has no room for a paragraph */
const taskLimit = 80;

/**
 * A Needs you card's caption: what the session is about (its task's first line, or the folder when it has none), then
 * "Agent · tool · 2m ago" on a line of its own
 */
export function needCaption(s: { task: string; folder: string; kind: string; detail: string | null; ago: string }): string {
  const first = s.task.trim().split("\n")[0].trim();
  const about = first.length > taskLimit ? first.slice(0, taskLimit - 1).trimEnd() + "…" : first;
  return [about || s.folder, [s.kind, s.detail?.trim(), s.ago].filter(Boolean).join(" · ")].join("\n");
}

/** A worktree's path gets about this many characters beside the ahead/behind pills in a 240px sidebar */
const placeLimit = 24;

/**
 * Where a worktree is, short enough for the sidebar: a linked worktree by its last folder ("…/ai-lockout"), the
 * repository's own folder in full, or from its end by whole folders when it is long ("…/Projects/desktop"). The full
 * path stays in the tooltip.
 */
export function worktreePlace(path: string, isMain: boolean, limit = placeLimit): string {
  const separator = path.includes("\\") && !path.includes("/") ? "\\" : "/";
  const parts = path.split(/[\\/]/).filter(Boolean);
  if (parts.length < 2) return path;
  if (!isMain) return "…/" + parts[parts.length - 1];
  if (path.length <= limit) return path;
  let kept = parts.slice(-1);
  for (let i = parts.length - 2; i >= 0; i--) {
    if (["…", parts[i], ...kept].join(separator).length > limit) break;
    kept = [parts[i], ...kept];
  }
  return ["…", ...kept].join(separator);
}
