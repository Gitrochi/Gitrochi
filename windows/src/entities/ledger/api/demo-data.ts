import type { LedgerBaseline, LedgerEvent, LedgerPendingPrompt, LedgerQuestion, LedgerSession, Ms } from "../model/types";

/** A session as the demo stores it; the verdict and the open-question count are computed on read, as in the core */
export type DemoSession = Omit<LedgerSession, "verdict" | "openQuestions">;
export type DemoQuestion = LedgerQuestion & { reviewed?: boolean };
export type DemoPrompt = LedgerPendingPrompt & { reviewed?: boolean };

export interface DemoWorld {
  rev: number;
  projects: { key: string; name: string }[];
  baselines: LedgerBaseline[];
  sessions: DemoSession[];
  events: LedgerEvent[];
  questions: DemoQuestion[];
  prompts: DemoPrompt[];
  /** File pairs that usually change together, the repository index's "likely overlap" */
  coupled: { a: string; b: string; paths: string[] }[];
  /** Settings › Ledger's stale hours; 72 when not set */
  staleHours?: number;
  nextEvent: number;
  nextQuestion: number;
  nextPrompt: number;
}

const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
const pad = (n: number) => String(n).padStart(2, "0");

/** Session IDs keep the core's shape, S<MMDD>-<nn>, numbered per day of creation */
function idMaker() {
  const perDay = new Map<string, number>();
  return (at: Ms) => {
    const d = new Date(at), day = `${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`;
    const n = (perDay.get(day) ?? 0) + 1;
    perDay.set(day, n);
    return `S${day}-${pad(n)}`;
  };
}

const retryMatrix = `## Retry matrix

| Answer | Retries | Delay |
| --- | --- | --- |
| 503 | 3 | 200 ms, doubling |
| 429 | 1 | \`Retry-After\` |
| Timeout | 2 | 500 ms |

- [x] Read the current client behaviour
- [ ] Agree on the number of retries

> The service team asks for no more than three attempts per minute.`;

const cacheDecision = `## Decision

Invalidate per key on write and keep a **five minute** ceiling for everything else.

### Why
- Writes are rare compared with reads.
- A global flush caused the spike in the last incident.

### Follow-up
1. Add key-level invalidation to the store.
2. Log every flush with its reason.`;

const longReport = `## Cycle report for v1.4.2

Applied the cache invalidation rules from v1.4.2 to the store and the API layer.

${Array.from({ length: 14 }, (_, i) => `- Step ${i + 1}: updated module ${["store", "keys", "api", "jobs", "tests", "docs", "metrics"][i % 7]} and checked it with the integration suite.`).join("\n")}

### Open points
- The metrics dashboard still reads the old key format.
- \`cache.flush()\` is kept for the admin tools only.

\`\`\`text
invalidated 1,204 keys in 38 ms
\`\`\``;

/**
 * The demo ledger: two projects with neutral names, a session in every verdict, a stream with three cycles, questions,
 * waiting prompts whose deadlines run out, an overlap, a likely overlap and example.com links. Times are relative to
 * `now`; `repoPath` binds the first project to the open repository. (macOS: DemoLedgerBackend.seed)
 */
export function demoWorld(now: Ms, repoPath = "C:/Projects/atlas"): DemoWorld {
  const nextId = idMaker();
  const w: DemoWorld = { rev: 1, projects: [{ key: "atlas", name: "atlas" }, { key: "harbor", name: "harbor" }], baselines: [], sessions: [], events: [], questions: [], prompts: [], coupled: [], nextEvent: 1, nextQuestion: 1, nextPrompt: 1 };
  const T = now;
  const base = (project: string, version: string, ts: Ms, source: LedgerBaseline["source"], bySession?: string, note?: string) =>
    w.baselines.push({ project, version, ts, source, ...(bySession ? { bySession } : {}), ...(note ? { note } : {}) });
  const colorOf = new Map<string, number>();
  const session = (s: Omit<DemoSession, "id" | "color" | "related" | "touches" | "links"> & Partial<Pick<DemoSession, "touches" | "related" | "links">>) => {
    const index = colorOf.get(s.project) ?? 0;
    colorOf.set(s.project, index + 1);
    const created: DemoSession = { touches: [], related: [], links: {}, ...s, id: nextId(s.createdAt), color: 1 + (index % 7) };
    w.sessions.push(created);
    return created;
  };
  const event = (sessionId: string, ts: Ms, type: string, extra: Partial<LedgerEvent> = {}) => {
    const e: LedgerEvent = { id: w.nextEvent++, sessionId, ts, type, actor: "agent", ...extra };
    w.events.push(e);
    return e;
  };
  const question = (sessionId: string, text: string, createdAt: Ms, extra: Partial<DemoQuestion> = {}) => {
    w.questions.push({ id: w.nextQuestion++, sessionId, text, state: "open", createdAt, ...extra });
    event(sessionId, createdAt, "question", { summary: text });
  };
  const repo = repoPath.replace(/\\/g, "/").replace(/\/+$/, "");
  const atlas = (branch: string) => ({ repoPath: repo, branch, worktree: `${repo}/.worktrees/${branch.replace(/\//g, "-")}` });

  base("atlas", "1.0.0", T - 60 * DAY, "tag");
  base("atlas", "1.1.0", T - 45 * DAY, "tag");
  base("atlas", "1.2.0", T - 30 * DAY, "tag");
  base("atlas", "1.3.0", T - 20 * DAY, "tag");
  base("atlas", "1.4.0", T - 12 * DAY, "tag");
  base("harbor", "0.8.0", T - 25 * DAY, "tag");
  base("harbor", "0.9.0", T - 9 * DAY, "tag");
  base("harbor", "1.0.0", T - 2 * DAY, "folder", undefined, "docs/releases/1.0.0");

  const stream = session({ project: "atlas", title: "Core implementation", kind: "implementation", role: "implementation", status: "active", baseVersion: "1.3.0", baseCurrent: "1.4.2", createdAt: T - 40 * DAY, lastAt: T - 3 * HOUR, lastAgentAt: T - 3 * HOUR, stream: { line: "Implementation" }, autoContinue: { enabled: true, delaySec: 30 }, touches: ["src/cache/store.ts", "src/api/client.ts"], links: { ...atlas("main"), agentId: "agent-demo-3" } });
  const notes = session({ project: "atlas", title: "Release notes for 1.4.0", kind: "document", role: "document", status: "merged", mergedInto: "1.4.0", baseVersion: "1.3.0", baseCurrent: "1.4.0", createdAt: T - 14 * DAY, lastAt: T - 12 * DAY, ackAt: T - 12 * DAY, archivedAt: T - 11 * DAY, touches: ["docs/releases/1.4.0.md"], links: atlas("docs/release-notes") });
  const timeout = session({ project: "atlas", title: "Session timeout policy", kind: "decision", role: "decision", status: "merged", mergedInto: "1.4.1", baseVersion: "1.4.0", baseCurrent: "1.4.1", createdAt: T - 8 * DAY, lastAt: T - 6 * DAY, ackAt: T - 5 * DAY, touches: ["docs/decisions/session-timeout.md"], links: atlas("decision/session-timeout") });
  const charts = session({ project: "atlas", title: "Compare chart libraries", kind: "research", role: "research", status: "shelved", baseVersion: "1.4.0", baseCurrent: "1.4.0", createdAt: T - 15 * DAY, lastAt: T - 10 * DAY, touches: ["docs/research/charts.md"], links: atlas("research/charts") });
  const flags = session({ project: "atlas", title: "Clean up old feature flags", kind: "chore", role: "other", status: "active", baseVersion: "1.4.0", baseCurrent: "1.4.1", createdAt: T - 9 * DAY, lastAt: T - 4 * DAY, touches: ["src/flags.ts"], links: atlas("chore/feature-flags") });
  const cache = session({ project: "atlas", title: "Cache invalidation design", kind: "decision", role: "decision", status: "merged", mergedInto: "1.4.2", baseVersion: "1.4.1", baseCurrent: "1.4.2", createdAt: T - 5 * DAY, lastAt: T - 22 * HOUR, touches: ["docs/decisions/cache.md", "src/cache/store.ts"], links: atlas("decision/cache") });
  const warmup = session({ project: "atlas", title: "Spike: warm the cache on deploy", kind: "research", role: "research", status: "done", baseVersion: "1.4.1", baseCurrent: "1.4.1", createdAt: T - 4 * DAY, lastAt: T - 30 * HOUR, touches: ["scripts/warmup.ts"], links: atlas("spike/cache-warmup") });
  const apiRef = session({ project: "atlas", title: "Export the API reference", kind: "document", role: "document", status: "merged", mergedInto: "1.4.2", baseVersion: "1.4.1", baseCurrent: "1.4.2", createdAt: T - 3 * DAY, lastAt: T - 20 * HOUR, touches: ["docs/api/reference.md"], links: { ...atlas("docs/api-reference"), pr: { host: "example.com", number: 139, url: "https://example.com/atlas/pull/139" } } });
  const retry = session({ project: "atlas", title: "Retry policy for the sign-in service", kind: "decision", role: "decision", status: "active", baseVersion: "1.4.1", baseCurrent: "1.4.2", createdAt: T - 26 * HOUR, lastAt: T - 2 * HOUR, lastAgentAt: T - 2 * HOUR, chatUrl: "https://example.com/chat/retry-policy", touches: ["src/auth/retry.ts", "docs/auth/retries.md"], related: [], links: { ...atlas("fix/sign-in-retry"), pr: { host: "example.com", number: 142, url: "https://example.com/atlas/pull/142" }, agentId: "agent-demo-1" } });
  const limits = session({ project: "atlas", title: "Rate limit for sign-in attempts", kind: "feature", role: "other", status: "active", baseVersion: "1.4.2", baseCurrent: "1.4.2", createdAt: T - 9 * HOUR, lastAt: T - 40 * MIN, lastAgentAt: T - 40 * MIN, autoContinue: { enabled: true, delaySec: 30 }, touches: ["src/auth/retry.ts", "src/auth/limits.ts"], links: { ...atlas("feature/sign-in-limits"), agentId: "agent-demo-2" } });
  retry.related.push(limits.id);
  base("atlas", "1.4.1", T - 6 * DAY, "release", timeout.id);
  base("atlas", "1.4.2", T - DAY, "release", cache.id);

  const translate = session({ project: "harbor", title: "Translate the setup guide", kind: "document", role: "document", status: "dropped", baseVersion: "0.9.0", baseCurrent: "0.9.0", createdAt: T - 6 * DAY, lastAt: T - 3 * DAY, ackAt: T - 3 * DAY, touches: ["guide/setup.md"] });
  const glossary = session({ project: "harbor", title: "Glossary for the user guide", kind: "document", role: "document", status: "done", baseVersion: "0.9.0", baseCurrent: "1.0.0", createdAt: T - 3 * DAY, lastAt: T - 20 * HOUR, touches: ["guide/glossary.md"] });
  const navigation = session({ project: "harbor", title: "Docs site navigation", kind: "document", role: "document", status: "active", baseVersion: "1.0.0", baseCurrent: "1.0.0", createdAt: T - 2 * DAY, lastAt: T - 5 * HOUR, chatUrl: "https://example.com/chat/docs-navigation", touches: ["site/nav.yml"] });
  const ranking = session({ project: "harbor", title: "Search results ranking", kind: "research", role: "research", status: "active", baseVersion: "1.0.0", baseCurrent: "1.0.0", createdAt: T - 30 * HOUR, lastAt: T - HOUR, touches: ["site/search.ts"], links: { agentId: "agent-demo-4" } });

  // Events, oldest first per session
  event(stream.id, stream.createdAt, "start", { summary: "Implementation stream from 1.3.0", version: "1.3.0" });
  event(stream.id, T - 12 * DAY + 2 * HOUR, "sync", { summary: "Read baseline 1.4.0", version: "1.4.0" });
  event(stream.id, T - 11 * DAY, "artifact", { summary: "Session store refactor", artifacts: [{ name: "src/session/store.ts", ssot: "1.4.0" }] });
  event(stream.id, T - 6 * DAY + HOUR, "sync", { summary: "Read baseline 1.4.1", version: "1.4.1" });
  event(stream.id, T - 5 * DAY - 3 * HOUR, "artifact", { summary: "Timeout settings in the client", artifacts: [{ name: "src/api/timeouts.ts", ssot: "1.4.1" }] });
  event(stream.id, T - 5 * DAY, "applied", { summary: "Applied 1.4.1 as asked", version: "1.4.1", data: { targets: [timeout.id] } });
  event(timeout.id, T - 5 * DAY, "applied", { actor: "agent", summary: `Applied by ${stream.id}`, version: "1.4.1", data: { by: stream.id } });
  event(stream.id, T - 22 * HOUR, "sync", { summary: "Read baseline 1.4.2", version: "1.4.2" });
  event(cache.id, T - 22 * HOUR, "merged", { summary: `Merged into 1.4.2 when ${stream.id} read it`, version: "1.4.2", data: { by: stream.id, via: "sync" } });
  event(stream.id, T - 10 * HOUR, "artifact", { summary: "Key-level invalidation", artifacts: [{ name: "src/cache/store.ts", ssot: "1.4.2" }] });
  event(stream.id, T - 3 * HOUR, "progress", { summary: "Cycle report for 1.4.2", body: longReport });
  event(notes.id, notes.createdAt, "start", { summary: "Draft the release notes", version: "1.3.0" });
  event(notes.id, T - 13 * DAY, "artifact", { summary: "Release notes", artifacts: [{ name: "docs/releases/1.4.0.md", ssot: "1.4.0" }] });
  event(notes.id, T - 12 * DAY, "merged", { summary: "Published with 1.4.0", version: "1.4.0" });
  event(notes.id, T - 11 * DAY, "archive", { actor: "human" });

  event(timeout.id, timeout.createdAt, "start", { summary: "Decide the session timeout", version: "1.4.0" });
  event(timeout.id, T - 7 * DAY, "decision", { summary: "Thirty minutes of inactivity, renewed on every request" });
  event(timeout.id, T - 6 * DAY, "release", { summary: "Released 1.4.1", version: "1.4.1" });

  event(charts.id, charts.createdAt, "start", { summary: "Compare three chart libraries", version: "1.4.0" });
  event(charts.id, T - 12 * DAY, "artifact", { summary: "Comparison table", artifacts: [{ name: "docs/research/charts.md" }] });
  event(charts.id, T - 10 * DAY, "shelved", { summary: "Paused until the dashboard work is planned" });

  event(flags.id, flags.createdAt, "start", { summary: "Remove flags that shipped", version: "1.4.0" });
  event(flags.id, T - 6 * DAY, "sync", { summary: "Read baseline 1.4.1", version: "1.4.1" });
  event(flags.id, T - 4 * DAY, "progress", { summary: "Removed four of nine flags" });

  event(cache.id, cache.createdAt, "start", { summary: "Design cache invalidation", version: "1.4.1" });
  event(cache.id, T - 3 * DAY, "decision", { summary: "Per-key invalidation with a five minute ceiling", body: cacheDecision });
  event(cache.id, T - DAY, "release", { summary: "Released 1.4.2", version: "1.4.2" });

  event(warmup.id, warmup.createdAt, "start", { summary: "Measure a warm-up job", version: "1.4.1" });
  event(warmup.id, T - 3 * DAY, "artifact", { summary: "Warm-up script and timings", artifacts: [{ name: "scripts/warmup.ts" }] });
  event(warmup.id, T - 30 * HOUR, "done", { summary: "Warm-up saves 40% of cold requests; merge undecided" });

  event(apiRef.id, apiRef.createdAt, "start", { summary: "Generate the API reference", version: "1.4.1" });
  event(apiRef.id, T - 2 * DAY, "artifact", { summary: "API reference", artifacts: [{ name: "docs/api/reference.md", ssot: "1.4.1" }] });
  event(apiRef.id, T - 20 * HOUR, "merged", { summary: "Merged into 1.4.2", version: "1.4.2" });

  event(retry.id, retry.createdAt, "start", { summary: "Decide the sign-in retry policy", version: "1.4.1" });
  event(retry.id, T - 22 * HOUR, "sync", { summary: "Read baseline 1.4.2", version: "1.4.2" });
  event(retry.id, T - 20 * HOUR, "artifact", { summary: "Retry matrix", body: retryMatrix, artifacts: [{ name: "docs/auth/retries.md", ssot: "1.4.2" }] });
  question(retry.id, "Retry three or five times when the service answers 503?", T - 2 * HOUR);
  question(retry.id, "Should the delay between retries grow, or stay fixed?", T - 2 * HOUR + MIN);

  event(limits.id, limits.createdAt, "start", { summary: "Limit sign-in attempts per account", version: "1.4.2" });
  event(limits.id, T - 2 * HOUR, "artifact", { summary: "Limiter middleware", artifacts: [{ name: "src/auth/limits.ts", ssot: "1.4.2" }] });
  event(limits.id, T - 40 * MIN, "progress", { summary: "Tests for the limiter" });

  event(translate.id, translate.createdAt, "start", { summary: "Translate the setup guide", version: "0.9.0" });
  event(translate.id, T - 3 * DAY, "dropped", { summary: "The guide is being rewritten first" });
  event(glossary.id, glossary.createdAt, "start", { summary: "Collect terms for the glossary", version: "0.9.0" });
  event(glossary.id, T - 2 * DAY, "sync", { summary: "Read baseline 1.0.0", version: "1.0.0" });
  event(glossary.id, T - 20 * HOUR, "done", { summary: "Glossary with 64 terms" });
  event(navigation.id, navigation.createdAt, "start", { summary: "Restructure the docs navigation", version: "1.0.0" });
  question(navigation.id, "Keep the old page addresses as redirects?", T - 5 * HOUR);
  event(ranking.id, ranking.createdAt, "start", { summary: "Try title boosts for search", version: "1.0.0" });
  event(ranking.id, T - HOUR, "progress", { summary: "Compared three ranking rules" });

  // payloads in auto-continue's PromptPayload shape (crates/gitrochi-autocontinue record.rs)
  const prompt = (p: Omit<DemoPrompt, "id">) => w.prompts.push({ id: w.nextPrompt++, ...p });
  const migration = "Which index should the migration build first?";
  prompt({ sessionId: retry.id, agentId: "agent-demo-1", kind: "stop_question", payload: promptPayload("stop_question", "Should I also update the retry section of the docs?", 45, { type: "reply", text: "Yes, go ahead with the safest option." }, { text: "The retry matrix is done. Should I also update the retry section of the docs?" }), createdAt: T - 20_000, deadline: T + 45_000, state: "waiting" });
  prompt({ sessionId: limits.id, agentId: "agent-demo-2", kind: "permission", payload: promptPayload("permission", "npm test -- auth", 95, { type: "allow" }, { tool: { name: "Bash", summary: "npm test -- auth" } }), createdAt: T - 10_000, deadline: T + 95_000, state: "waiting" });
  prompt({ sessionId: stream.id, agentId: "agent-demo-3", kind: "ask_user_question", payload: promptPayload("ask_user_question", "Which cache keys should the migration rebuild first?", 240, { type: "answers", answers: { "Which cache keys should the migration rebuild first?": "Session keys" }, note: "Chosen because it was marked as recommended." }, { questions: [{ question: "Which cache keys should the migration rebuild first?", header: "Migration", multiSelect: false, options: [{ label: "Session keys", description: "Only the keys sessions read", recommended: true }, { label: "All keys", recommended: false }] }] }), createdAt: T - 5_000, deadline: T + 4 * MIN, state: "waiting" });
  prompt({ sessionId: ranking.id, agentId: "agent-demo-4", kind: "exit_plan_mode", payload: promptPayload("exit_plan_mode", "Boost exact title matches", 540, null, { text: "1. Index titles separately\n2. Add a ranking test", tool: { name: "ExitPlanMode", summary: "Boost exact title matches" } }), createdAt: T - 2 * MIN, deadline: T + 9 * MIN, state: "waiting" });
  prompt({ sessionId: navigation.id, kind: "permission", payload: promptPayload("permission", "npm run lint", 30, { type: "allow" }, { tool: { name: "Bash", summary: "npm run lint" } }), createdAt: T - 26 * MIN, deadline: T - 25 * MIN, state: "auto", answer: { type: "allow" }, answeredBy: "auto" });
  event(navigation.id, T - 25 * MIN, "auto_reply", { actor: "auto", summary: "Allowed npm run lint", data: { promptId: w.nextPrompt - 1, kind: "permission", answer: { type: "allow" } } });
  prompt({ sessionId: stream.id, agentId: "agent-demo-3", kind: "ask_user_question", payload: promptPayload("ask_user_question", migration, 30, { type: "answers", answers: { [migration]: "Sessions by project" }, note: "Chosen because it was marked as recommended." }, { questions: [{ question: migration, header: "Migration", multiSelect: false, options: [{ label: "Sessions by project", recommended: true }, { label: "Events by time", recommended: false }] }] }), createdAt: T - 40 * MIN, deadline: T - 39 * MIN, state: "auto", answer: { type: "answers", answers: { [migration]: "Sessions by project" }, note: "Chosen because it was marked as recommended." }, answeredBy: "auto" });
  event(stream.id, T - 39 * MIN, "auto_reply", { actor: "auto", summary: "Chose the recommended option: Sessions by project", data: { promptId: w.nextPrompt - 1, kind: "ask_user_question" } });

  w.coupled.push({ a: flags.id, b: limits.id, paths: ["src/flags.ts", "src/auth/limits.ts"] });
  return w;
}

/** A prompt payload as auto-continue writes it; `proposed` is what it sends when nobody answers in time */
export function promptPayload(kind: string, question: string, delaySec: number, proposed: Record<string, unknown> | null, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { schemaVersion: 1, kind, question, language: "en", delaySec, ...(proposed ? { proposed } : {}), ...extra };
}

/** A ledger nothing has reported to yet */
export const emptyWorld = (): DemoWorld => ({ rev: 1, projects: [], baselines: [], sessions: [], events: [], questions: [], prompts: [], coupled: [], nextEvent: 1, nextQuestion: 1, nextPrompt: 1 });

/** A fixed pseudo-random sequence (mulberry32), so the large demo is the same every time */
function random(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** The large demo: 1,000 sessions and 50,000 events over half a year, to check that every view stays fast */
export function largeDemoWorld(now: Ms, repoPath = "C:/Projects/atlas", sessions = 1000, eventsPerSession = 50): DemoWorld {
  const w: DemoWorld = { rev: 1, projects: [{ key: "atlas", name: "atlas" }, { key: "harbor", name: "harbor" }], baselines: [], sessions: [], events: [], questions: [], prompts: [], coupled: [], nextEvent: 1, nextQuestion: 1, nextPrompt: 1 };
  const rnd = random(20261031);
  const pick = <T,>(list: readonly T[]) => list[Math.floor(rnd() * list.length)];
  const span = 180 * DAY, start = now - span;
  const trunks: Record<string, LedgerBaseline[]> = { atlas: [], harbor: [] };
  for (const project of ["atlas", "harbor"]) for (let i = 0; i < 30; i++) {
    const baseline: LedgerBaseline = { project, version: `${project === "atlas" ? 2 : 1}.${Math.floor(i / 10)}.${i % 10}`, ts: start + i * 6 * DAY + (project === "harbor" ? DAY : 0), source: "tag" };
    trunks[project].push(baseline);
    w.baselines.push(baseline);
  }
  const nextId = idMaker();
  const kinds = [["decision", "decision"], ["research", "research"], ["document", "document"], ["feature", "other"], ["chore", "other"]] as const;
  const types = ["progress", "progress", "progress", "note", "artifact", "decision", "progress", "note"];
  const paths = Array.from({ length: 40 }, (_, i) => `src/module-${i % 8}/file-${i}.ts`);
  const repo = repoPath.replace(/\\/g, "/").replace(/\/+$/, "");
  const created = Array.from({ length: sessions }, () => start + rnd() * (span - DAY)).sort((a, b) => a - b);
  const colors = new Map<string, number>();
  for (let i = 0; i < sessions; i++) {
    const project = i % 5 < 3 ? "atlas" : "harbor";
    const createdAt = created[i];
    const length = Math.min(now - createdAt, (0.2 + rnd() * 5) * DAY);
    const lastAt = createdAt + length;
    const [kind, role] = pick(kinds);
    const age = (now - lastAt) / DAY;
    const roll = rnd();
    const status = age < 6 ? (roll < 0.45 ? "active" : roll < 0.6 ? "done" : roll < 0.85 ? "merged" : "closed") : roll < 0.05 ? "shelved" : roll < 0.8 ? "merged" : roll < 0.93 ? "closed" : "dropped";
    const trunk = trunks[project];
    let baseIndex = 0;
    while (baseIndex + 1 < trunk.length && trunk[baseIndex + 1].ts <= createdAt) baseIndex++;
    const baseVersion = trunk[baseIndex].version;
    const finished = status === "merged" || status === "closed" || status === "dropped";
    const index = colors.get(project) ?? 0;
    colors.set(project, index + 1);
    const s: DemoSession = {
      id: nextId(createdAt), project, title: `${pick(["Tune", "Fix", "Document", "Measure", "Design", "Clean up"])} ${pick(["the cache", "sign-in", "search", "the importer", "exports", "the scheduler", "logging", "settings"])} #${i + 1}`,
      kind, role, status, baseVersion, baseCurrent: baseVersion, touches: [pick(paths), pick(paths)], related: [], color: 1 + (index % 7), createdAt, lastAt,
      links: project === "atlas" ? { repoPath: repo, branch: `work/session-${i + 1}` } : {},
      ...(status === "merged" ? { mergedInto: trunk[Math.min(trunk.length - 1, baseIndex + 1)].version } : {}),
      ...(finished && (age > 2 || rnd() < 0.5) ? { ackAt: lastAt + HOUR } : {}),
      ...(finished && age > 14 && rnd() < 0.9 ? { archivedAt: lastAt + DAY } : {}),
    };
    w.sessions.push(s);
    for (let k = 0; k < eventsPerSession; k++) {
      const ts = createdAt + (length * k) / Math.max(1, eventsPerSession - 1);
      const type = k === 0 ? "start" : k === eventsPerSession - 1 && status !== "active" ? (status === "merged" ? "merged" : status) : types[k % types.length];
      w.events.push({ id: w.nextEvent++, sessionId: s.id, ts, type, actor: "agent", summary: `${type} ${k + 1} of ${s.title}`, ...(type === "start" || type === "merged" ? { version: type === "merged" ? s.mergedInto : baseVersion } : {}) });
    }
    if (status === "active" && rnd() < 0.08) w.questions.push({ id: w.nextQuestion++, sessionId: s.id, text: `Which option should ${s.title} take?`, state: "open", createdAt: lastAt });
  }
  return w;
}
