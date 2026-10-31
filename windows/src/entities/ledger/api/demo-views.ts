import type { LedgerBaseline, LedgerEvent, LedgerGraph, LedgerGraphEdge, LedgerGraphNode, LedgerOverlap, LedgerRange, LedgerSearchHit, LedgerSession, LedgerStreamCycle, Ms } from "../model/types";
import { foldText } from "../lib/filter";
import { compareVersions } from "../lib/version";
import { computeVerdict, isFinished } from "../lib/verdict";
import type { DemoSession, DemoWorld } from "./demo-data";

const DAY = 86_400_000;

/** Where a period starts; "all" has no lower bound */
export const rangeStart = (range: LedgerRange, now: Ms) => (range === "7d" ? now - 7 * DAY : range === "30d" ? now - 30 * DAY : -Infinity);

/** Live = still being worked on: not finished, not shelved, not archived */
export const isLive = (s: Pick<LedgerSession, "status" | "archivedAt">) => !isFinished(s.status) && s.status !== "shelved" && !s.archivedAt;

/** Sessions as the contract shows them, with the verdict and open questions computed now */
export function sessionViews(w: DemoWorld, now: Ms): Map<string, LedgerSession> {
  const open = new Map<string, number>();
  for (const q of w.questions) if (q.state === "open") open.set(q.sessionId, (open.get(q.sessionId) ?? 0) + 1);
  return new Map(w.sessions.map((s): [string, LedgerSession] => {
    const openQuestions = open.get(s.id) ?? 0;
    return [s.id, { ...s, openQuestions, verdict: computeVerdict({ ...s, openQuestions }, now) }];
  }));
}

/**
 * A stream's cycles, newest version first: a sync to vX starts the vX cycle, the session's own applied vX attaches to
 * it, anything else joins the current cycle. A cycle with an applied report is applied, the newest other one active,
 * older ones skipped; each names the session that released its version.
 */
export function streamCycles(s: DemoSession, events: readonly LedgerEvent[], baselines: readonly LedgerBaseline[]): LedgerStreamCycle[] {
  const line = s.stream?.line ?? "";
  const cycles = new Map<string, LedgerStreamCycle>();
  const cycle = (version: string) => {
    let c = cycles.get(version);
    if (!c) {
      const releasedBy = baselines.find((b) => b.project === s.project && b.version === version)?.bySession;
      c = { sessionId: s.id, line, version, state: "skipped", eventIds: [], ...(releasedBy ? { releasedBy } : {}) };
      cycles.set(version, c);
    }
    return c;
  };
  let current: LedgerStreamCycle | null = null;
  for (const e of events) {
    if (e.actor !== "agent" && e.actor !== "auto") continue;
    if (e.type === "sync" && e.version) {
      current = cycle(e.version);
      current.syncedAt = e.ts;
      current.eventIds.push(e.id);
    } else if (e.type === "applied" && e.version) {
      const c = cycle(e.version);
      c.appliedAt = e.ts;
      c.eventIds.push(e.id);
      if (!current || compareVersions(e.version, current.version) > 0) current = c;
    } else current?.eventIds.push(e.id);
  }
  const list = [...cycles.values()].sort((a, b) => compareVersions(b.version, a.version));
  const newestOpen = list.find((c) => !c.appliedAt);
  for (const c of list) c.state = c.appliedAt ? "applied" : c === newestOpen && c === list[0] ? "active" : "skipped";
  return list;
}

/** Live, non-stream sessions of one project that share a touch, plus the likely overlaps the repository index adds */
export function overlaps(views: Map<string, LedgerSession>, coupled: DemoWorld["coupled"]): LedgerOverlap[] {
  const live = [...views.values()].filter((s) => isLive(s) && !s.stream);
  const out: LedgerOverlap[] = [];
  for (let i = 0; i < live.length; i++) for (let j = i + 1; j < live.length; j++) {
    const a = live[i], b = live[j];
    if (a.project !== b.project) continue;
    const paths = a.touches.filter((p) => b.touches.includes(p));
    if (paths.length) out.push({ a: a.id, b: b.id, paths, kind: "same" });
  }
  for (const c of coupled) {
    const a = views.get(c.a), b = views.get(c.b);
    if (a && b && isLive(a) && isLive(b) && !a.stream && !b.stream) out.push({ a: c.a, b: c.b, paths: c.paths, kind: "coupled" });
  }
  return out;
}

const KEY_EVENTS = new Set(["start", "artifact", "question", "decision", "sync", "applied", "release", "done", "merged", "closed", "dropped", "shelved"]);

/**
 * The Graph view for one project and period: lane 0 is the baseline trunk, each session a lane that forks from its base
 * and joins the version it merged into; key events only. Lanes are reused once a session's line has ended.
 */
export function buildGraph(w: DemoWorld, views: Map<string, LedgerSession>, project: string, range: LedgerRange, now: Ms): LedgerGraph {
  const from = rangeStart(range, now);
  const sessions = [...views.values()]
    .filter((s) => s.project === project && (s.lastAt >= from || (isLive(s) && s.verdict !== "archived")))
    .sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
  const needed = new Set(sessions.flatMap((s) => [s.baseVersion, s.mergedInto].filter((v): v is string => !!v)));
  const trunk = w.baselines.filter((b) => b.project === project && (b.ts >= from || needed.has(b.version))).sort((a, b) => a.ts - b.ts);
  const nodes: LedgerGraphNode[] = [];
  const edges: LedgerGraphEdge[] = [];
  const baselineId = (version: string) => `b:${version}`;
  const has = new Set(trunk.map((b) => baselineId(b.version)));
  trunk.forEach((b, i) => {
    nodes.push({ id: baselineId(b.version), lane: 0, ts: b.ts, color: 0, kind: b.source === "release" ? "release" : "baseline", version: b.version, label: b.version });
    if (i > 0) edges.push({ from: baselineId(trunk[i - 1].version), to: baselineId(b.version), kind: "trunk", color: 0 });
  });
  const byId = new Map<string, LedgerEvent[]>();
  for (const e of w.events) if (KEY_EVENTS.has(e.type) && (e.actor === "agent" || e.actor === "auto")) {
    const list = byId.get(e.sessionId);
    if (list) list.push(e);
    else byId.set(e.sessionId, [e]);
  }
  const busyUntil: number[] = [Infinity];
  for (const s of sessions) {
    const events = (byId.get(s.id) ?? []).sort((a, b) => a.ts - b.ts || a.id - b.id);
    const first = events[0]?.type === "start" ? events[0] : undefined;
    const rest = first ? events.slice(1) : events;
    const open = isLive(s);
    const end = open ? Infinity : Math.max(s.lastAt, ...rest.map((e) => e.ts));
    let lane = busyUntil.findIndex((until, i) => i > 0 && until < s.createdAt);
    if (lane < 0) lane = busyUntil.push(0) - 1;
    busyUntil[lane] = end;
    const ids: string[] = [];
    const startId = first ? `e:${first.id}` : `s:${s.id}`;
    nodes.push({ id: startId, lane, ts: first?.ts ?? s.createdAt, color: s.color, kind: "start", sessionId: s.id, ...(s.baseVersion ? { version: s.baseVersion } : {}), label: first?.summary ?? s.title });
    ids.push(startId);
    rest.forEach((e, i) => {
      // a finished session's line ends by its status: a merge joins the trunk, anything else is an end
      const last = i === rest.length - 1 && !open;
      const kind: LedgerGraphNode["kind"] = last ? (s.status === "merged" ? "merge" : "end") : "event";
      const id = `e:${e.id}`;
      nodes.push({ id, lane, ts: e.ts, color: s.color, kind, type: e.type, sessionId: s.id, ...(e.version ? { version: e.version } : {}), label: `${e.type}${e.summary ? `: ${e.summary}` : ""}` });
      ids.push(id);
      if (e.type === "sync" && e.version && has.has(baselineId(e.version))) edges.push({ from: baselineId(e.version), to: id, kind: "handoff", color: s.color });
      if (e.type === "applied" && s.stream && e.version && has.has(baselineId(e.version))) edges.push({ from: id, to: baselineId(e.version), kind: "handoff", color: s.color });
      if (kind === "merge" && s.mergedInto && has.has(baselineId(s.mergedInto))) edges.push({ from: id, to: baselineId(s.mergedInto), kind: "merge", color: s.color });
    });
    if (s.baseVersion && has.has(baselineId(s.baseVersion))) edges.push({ from: baselineId(s.baseVersion), to: startId, kind: "branch", color: s.color });
    for (let i = 1; i < ids.length; i++) edges.push({ from: ids[i - 1], to: ids[i], kind: "branch", color: s.color });
  }
  let low = Number.isFinite(from) ? from : now;
  for (const n of nodes) low = Math.min(low, n.ts);
  return { lanes: busyUntil.length, nodes, edges, from: low, to: now };
}

/** Report text around the match, on one line and without Markdown marks */
function snippet(text: string, query: string, room = 90): string {
  const flat = text.replace(/^#+\s*/gm, "").replace(/\|?\s*:?-{3,}:?\s*/g, " ").replace(/[|*`>]+/g, " ").replace(/\s+/g, " ").trim();
  const at = foldText(flat).indexOf(foldText(query));
  if (at < 0 || flat.length <= room) return flat.slice(0, room) + (flat.length > room ? "…" : "");
  const start = Math.max(0, at - Math.floor(room / 3));
  return (start > 0 ? "…" : "") + flat.slice(start, start + room) + (start + room < flat.length ? "…" : "");
}

/** Sessions, questions, report summaries and bodies, and baselines that contain the query (the core's `search`) */
export function searchWorld(w: DemoWorld, views: Map<string, LedgerSession>, query: string, project: string | undefined, limit: number): LedgerSearchHit[] {
  const q = foldText(query.trim());
  if (!q) return [];
  const inProject = (id: string) => !project || views.get(id)?.project === project;
  const hits: LedgerSearchHit[] = [];
  const add = (hit: LedgerSearchHit) => hits.length < limit && hits.push(hit);
  for (const s of views.values()) if (inProject(s.id) && foldText(`${s.id} ${s.title} ${s.links.branch ?? ""}`).includes(q)) add({ kind: "session", id: s.id, sessionId: s.id, title: `${s.id} · ${s.title}`, snippet: [s.kind, s.links.branch, s.baseCurrent].filter(Boolean).join(" · ") });
  for (const x of w.questions) if (inProject(x.sessionId) && foldText(`${x.text} ${x.answer ?? ""}`).includes(q)) add({ kind: "question", id: String(x.id), sessionId: x.sessionId, title: `${x.sessionId} · ${views.get(x.sessionId)?.title ?? ""}`, snippet: snippet(x.text, query) });
  for (const b of w.baselines) if ((!project || b.project === project) && foldText(b.version).includes(q)) add({ kind: "baseline", id: b.version, title: `${b.project} ${b.version}`, snippet: [b.source, b.note, b.bySession].filter(Boolean).join(" · ") });
  for (const e of w.events) {
    if (hits.length >= limit) break;
    if (!inProject(e.sessionId)) continue;
    const text = `${e.summary ?? ""}\n${e.body ?? ""}`;
    if (foldText(text).includes(q)) add({ kind: "event", id: String(e.id), sessionId: e.sessionId, title: `${e.sessionId} · ${e.type}`, snippet: snippet(text, query) });
  }
  return hits;
}
