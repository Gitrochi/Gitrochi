import type { LedgerEvent, LedgerInsights, LedgerRange, LedgerReleaseNotes, LedgerReleaseNotesEntry, LedgerRole, LedgerSession } from "../model/types";
import { ledgerRoles } from "../model/types";
import { compareVersions } from "../lib/version";
import { LedgerError } from "./backend";
import type { DemoWorld } from "./demo-data";

const GROUPS: [LedgerRole, string][] = [["decision", "Decisions"], ["implementation", "Implementation"], ["research", "Research"], ["document", "Documents"], ["other", "Other"]];
const SUMMARY_CHARS = 160;
const pad = (n: number) => String(n).padStart(2, "0");

/** The first line of a summary, spaces collapsed, cut to a readable length (crates/gitrochi-ledger/src/release_notes.rs) */
function oneLine(text?: string): string | undefined {
  const line = text?.split("\n").map((l) => l.trim()).find(Boolean)?.split(/\s+/).join(" ");
  if (!line) return undefined;
  return [...line].length <= SUMMARY_CHARS ? line : `${[...line].slice(0, SUMMARY_CHARS - 1).join("").trimEnd()}…`;
}

function summaryOf(events: LedgerEvent[]): string | undefined {
  for (const type of ["done", "decision", "merged"]) {
    for (const e of [...events].reverse()) {
      if (e.actor !== "agent" || e.type !== type || (type === "merged" && e.data?.by)) continue;
      const line = oneLine(e.summary);
      if (line) return line;
    }
  }
  return undefined;
}

function artifactsOf(events: LedgerEvent[]): LedgerReleaseNotesEntry["artifacts"] {
  const out: LedgerReleaseNotesEntry["artifacts"] = [];
  for (const e of events.filter((x) => x.actor === "agent")) {
    for (const a of e.artifacts ?? []) {
      const artifact = { name: a.name, ...(a.ver ?? a.ssot ? { ver: a.ver ?? a.ssot } : {}) };
      const at = out.findIndex((x) => x.name === a.name);
      if (at >= 0) out[at] = artifact;
      else out.push(artifact);
    }
  }
  return out;
}

/** The core's `release_notes` on the demo world, Markdown included, so the sheet can be seen without a database */
export function demoReleaseNotes(w: DemoWorld, project: string, version?: string): LedgerReleaseNotes {
  const trunk = w.baselines.filter((b) => b.project === project).sort((a, b) => compareVersions(a.version, b.version));
  if (!trunk.length) throw new LedgerError("NOT_FOUND", `No project ${project}`);
  const wanted = !version || /^(latest|head)$/i.test(version) ? trunk[trunk.length - 1].version : version.replace(/^v/i, "");
  const index = trunk.findIndex((b) => b.version === wanted);
  if (index < 0) throw new LedgerError("NOT_FOUND", `No baseline ${wanted} in ${project}`);
  const found = trunk[index];
  const absorbed = new Set(w.events.filter((e) => e.type === "release" && e.version === wanted).flatMap((e) => (Array.isArray(e.data?.absorbs) ? (e.data.absorbs as string[]) : [])));
  const groups = GROUPS.map(([role, title]) => ({ role, title, sessions: [] as LedgerReleaseNotesEntry[] }));
  const rows = w.sessions.filter((s) => s.project === project && (s.mergedInto === wanted || absorbed.has(s.id))).sort((a, b) => a.kind.localeCompare(b.kind) || a.createdAt - b.createdAt);
  for (const s of rows) {
    const events = w.events.filter((e) => e.sessionId === s.id).sort((a, b) => a.ts - b.ts || a.id - b.id);
    const summary = summaryOf(events);
    groups.find((g) => g.role === s.role)?.sessions.push({ id: s.id, title: s.title, kind: s.kind, how: absorbed.has(s.id) ? "absorbed" : "merged", ...(summary ? { summary } : {}), artifacts: artifactsOf(events) });
  }
  const notes: LedgerReleaseNotes = {
    project, version: wanted, ...(index > 0 ? { previous: trunk[index - 1].version } : {}), releasedAt: found.ts,
    ...(found.bySession ? { releasedBy: found.bySession } : {}), ...(found.note?.trim() ? { note: found.note.trim() } : {}),
    versions: trunk.map((b) => b.version).reverse(), groups: groups.filter((g) => g.sessions.length), markdown: "",
  };
  const d = new Date(found.ts);
  const lines = [`# ${project} ${wanted}`, "", `Released ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}${notes.releasedBy ? ` by ${notes.releasedBy}` : ""}${notes.previous ? ` · changes since ${notes.previous}` : ""}.`];
  if (notes.note) lines.push("", ...notes.note.split("\n").map((l) => (l.trim() ? `> ${l.trimEnd()}` : ">")));
  if (!notes.groups.length) lines.push("", `No sessions were merged into ${wanted}.`);
  for (const g of notes.groups) {
    lines.push("", `## ${g.title}`, "");
    for (const e of g.sessions) {
      const label = e.kind === g.role || !e.kind ? `\`${e.id}\`` : `\`${e.id}\` · ${e.kind}`;
      lines.push(`- **${e.title || e.id}** (${label})${e.summary ? ` — ${e.summary}` : ""}`);
      if (e.artifacts.length) lines.push(`  - Artifacts: ${e.artifacts.map((a) => `\`${a.name}${a.ver ? `@${a.ver}` : ""}\`${a.path ? ` (${a.path})` : ""}`).join(", ")}`);
    }
  }
  notes.markdown = `${lines.join("\n")}\n`;
  return notes;
}

const DAY_MS = 86_400_000;

/** Nearest-rank percentiles of durations, as the core's insights.rs computes them */
function spread(values: number[]): LedgerInsights["questions"]["wait"] {
  const sorted = values.filter((v) => v >= 0).sort((a, b) => a - b);
  const rank = (p: number) => sorted[Math.min(sorted.length - 1, Math.max(1, Math.ceil((p * sorted.length) / 100)) - 1)];
  return sorted.length ? { count: sorted.length, medianMs: rank(50), p90Ms: rank(90), maxMs: sorted[sorted.length - 1] } : { count: 0 };
}

/** The core's `insights` on the demo world: counts and durations only */
export function demoInsights(w: DemoWorld, views: Map<string, LedgerSession>, project: string | undefined, range: LedgerRange, now: number): LedgerInsights {
  const from = range === "7d" ? now - 7 * DAY_MS : range === "30d" ? now - 30 * DAY_MS : undefined;
  const inProject = (sessionId?: string) => !project || views.get(sessionId ?? "")?.project === project;
  const inRange = (at?: number) => from === undefined || (at ?? 0) >= from;
  const questions = w.questions.filter((q) => inProject(q.sessionId));
  const settled = questions.filter((q) => q.state !== "open" && q.answeredAt !== undefined && inRange(q.answeredAt));
  const people = settled.filter((q) => q.resolvedBy !== "agent");
  const open = questions.filter((q) => q.state === "open" && !views.get(q.sessionId)?.archivedAt);
  const prompts = w.prompts.filter((p) => p.state === "auto" && inProject(p.sessionId) && inRange(p.createdAt));
  const corrected = (p: (typeof prompts)[number]) => !!p.reviewed && w.events.some((e) => e.sessionId === p.sessionId && e.type === "message" && e.actor === "human" && e.ts >= p.createdAt);
  const kinds = [...new Set(prompts.map((p) => p.kind))].sort().map((kind) => {
    const rows = prompts.filter((p) => p.kind === kind);
    return { kind, total: rows.length, reviewed: rows.filter((p) => p.reviewed).length, corrected: rows.filter(corrected).length, unreviewed: rows.filter((p) => !p.reviewed).length };
  });
  const sessions = [...views.values()].filter((s) => (!project || s.project === project) && (!s.archivedAt || inRange(s.archivedAt)));
  const byVerdict = Object.fromEntries(["needs_human", "confirm", "expirable", "pending_merge", "stale", "active", "shelved", "archived"].map((v) => [v, sessions.filter((s) => s.verdict === v).length])) as LedgerInsights["sessions"]["byVerdict"];
  const byRole = Object.fromEntries(ledgerRoles.map((r) => [r, sessions.filter((s) => s.role === r).length])) as LedgerInsights["sessions"]["byRole"];
  const stale = sessions.filter((s) => s.verdict === "stale");
  const reports = w.events.filter((e) => e.actor === "agent" && inProject(e.sessionId) && e.ts <= now);
  const days = range === "7d" ? 7 : range === "30d" ? 30 : 90;
  const today = new Date(now);
  const perDay = Array.from({ length: days }, (_, i) => {
    const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - (days - 1 - i));
    const start = d.getTime(), end = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
    return { day: `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`, reports: reports.filter((e) => e.ts >= start && e.ts < end).length };
  });
  return {
    ...(project ? { project } : {}), range, ...(from !== undefined ? { from } : {}), to: now,
    questions: { asked: questions.filter((q) => inRange(q.createdAt)).length, answered: people.filter((q) => q.state === "answered").length, dismissed: people.filter((q) => q.state === "dismissed").length, resolvedByAgent: settled.length - people.length, wait: spread(people.map((q) => (q.answeredAt ?? 0) - q.createdAt)), open: spread(open.map((q) => now - q.createdAt)) },
    autoAnswers: { total: prompts.length, reviewed: kinds.reduce((n, k) => n + k.reviewed, 0), corrected: kinds.reduce((n, k) => n + k.corrected, 0), unreviewed: kinds.reduce((n, k) => n + k.unreviewed, 0), byKind: kinds },
    sessions: { total: sessions.length, byVerdict, byRole, stale: stale.length, staleUnreported: stale.filter((s) => !s.lastAgentAt).length, unreported: sessions.filter((s) => !s.lastAgentAt).length },
    reports: reports.filter((e) => inRange(e.ts)).length,
    reportsPerDay: perDay,
  };
}
