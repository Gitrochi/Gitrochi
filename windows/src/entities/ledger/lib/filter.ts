import type { LedgerSession, LedgerState, LedgerVerdict } from "../model/types";
import { compareSessions, verdictDisplayOrder } from "./verdict";

export interface SessionFilter {
  /** Project key; null = every project */
  project: string | null;
  /** Verdict chips that are on; none on = every verdict but archived */
  verdicts: ReadonlySet<LedgerVerdict>;
  /** Free text matched against ID, title, kind, branch and touches */
  text: string;
  showArchived: boolean;
}

export const emptyFilter = (project: string | null = null): SessionFilter => ({ project, verdicts: new Set(), text: "", showArchived: false });

/** Lower case and composed, so typed and stored text compare the same */
export const foldText = (s: string) => s.normalize("NFC").toLocaleLowerCase();

/** Whether every word of the query is somewhere in the session's ID, title, kind, branch or touches */
export function matchesText(session: LedgerSession, query: string): boolean {
  const words = foldText(query).split(/\s+/).filter(Boolean);
  if (!words.length) return true;
  const hay = foldText([session.id, session.title, session.kind, session.role, session.links.branch ?? "", ...session.touches].join(" "));
  return words.every((w) => hay.includes(w));
}

export const inProject = (session: LedgerSession, project: string | null) => !project || session.project === project;

/**
 * The Board's rows: streams stay out (they show under Streams), archived only on request, then the verdict chips and
 * the text, in Board order. (macOS: LedgerFilter.apply)
 */
export function filterSessions(sessions: readonly LedgerSession[], f: SessionFilter): LedgerSession[] {
  return sessions
    .filter((s) => !s.stream && inProject(s, f.project) && (f.showArchived || f.verdicts.has("archived") || s.verdict !== "archived"))
    .filter((s) => !f.verdicts.size || f.verdicts.has(s.verdict))
    .filter((s) => matchesText(s, f.text))
    .sort(compareSessions);
}

/** Sessions per verdict for the chips, in display order; streams and other projects are not counted */
export function verdictCounts(sessions: readonly LedgerSession[], project: string | null): { verdict: LedgerVerdict; count: number }[] {
  const counts = new Map<LedgerVerdict, number>();
  for (const s of sessions) if (!s.stream && inProject(s, project)) counts.set(s.verdict, (counts.get(s.verdict) ?? 0) + 1);
  return verdictDisplayOrder.map((verdict) => ({ verdict, count: counts.get(verdict) ?? 0 }));
}

/** Streams kept out of the Board for the project */
export const streamCount = (sessions: readonly LedgerSession[], project: string | null) => sessions.filter((s) => s.stream && inProject(s, project)).length;

const trimPath = (p: string) => p.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

/**
 * The project of the open repository: the one most of whose sessions are linked to it, else the one named like its
 * folder. The contract's projects carry no repository yet, so this is inferred. (macOS: LedgerStore.project(for:))
 */
export function projectForRepository(state: Pick<LedgerState, "projects" | "sessions">, repoPath: string | null): string | null {
  if (!repoPath) return null;
  const key = trimPath(repoPath);
  const votes = new Map<string, number>();
  for (const s of state.sessions) {
    const linked = s.links.repoPath ?? s.links.worktree ?? s.links.cwd;
    if (linked && trimPath(linked) === key) votes.set(s.project, (votes.get(s.project) ?? 0) + 1);
  }
  const best = [...votes].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0];
  if (best) return best[0];
  const folder = key.slice(key.lastIndexOf("/") + 1);
  return state.projects.find((p) => p.key.toLowerCase() === folder || p.name.toLowerCase() === folder)?.key ?? null;
}
