import type { LedgerHumanRequest, LedgerImportResult, LedgerKindRule, LedgerMethod, LedgerMethods, LedgerProjectSettings, LedgerPromptAnswer, LedgerRange, LedgerRole, LedgerSettings, LedgerState, LedgerStatus, Ms } from "../model/types";
import { ledgerBaselineSources, ledgerRoles } from "../model/types";
import { inboxGroups } from "../lib/inbox";
import { STALE_HOURS } from "../lib/verdict";
import { compareVersions } from "../lib/version";
import { LedgerError, type LedgerBackend } from "./backend";
import { type DemoPrompt, type DemoSession, type DemoWorld, demoWorld, emptyWorld, largeDemoWorld, promptPayload } from "./demo-data";
import { buildGraph, isLive, overlaps, rangeStart, searchWorld, sessionViews, streamCycles } from "./demo-views";

export interface DemoOptions {
  /** The clock; tests move it by hand */
  now?: () => Ms;
  /** The open repository, bound to the first project */
  repoPath?: string;
  /** 1,000 sessions and 50,000 events */
  large?: boolean;
  /** Keeps a waiting prompt coming so the countdown can be watched; off in tests */
  lively?: boolean;
  /** Nothing reported yet: the onboarding state */
  empty?: boolean;
}

const EVENTS = new Set(["start", "progress", "artifact", "question", "decision", "sync", "done", "merged", "closed", "dropped", "shelved", "release", "applied", "note", "heartbeat"]);
const SESSION_ID = /^[\p{L}\p{N}._-]{3,48}$/u;
const roleOf = (kind: string): LedgerRole => (["decision", "implementation", "research", "document"].includes(kind) ? (kind as LedgerRole) : "other");
const DEFAULT_PATTERN = "^v?(\\d+(?:\\.\\d+)+)$";
const isRecord = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const invalid = (message: string) => new LedgerError("INVALID_ARGUMENT", message);

/** The core's default settings (crates/gitrochi-ledger/src/settings.rs) */
function defaultSettings(): LedgerSettings {
  const implementation = (line: string, handoff: boolean): LedgerKindRule => ({ role: "implementation", line, handoff });
  return {
    staleHours: STALE_HOURS,
    kinds: { baseline: { role: "other" }, decision: { role: "decision" }, document: { role: "document" }, implementation: implementation("core", true), "llm-implementation": implementation("llm", false), other: { role: "other" }, research: { role: "research" }, review: { role: "other" } },
    autoContinue: { enabled: false, delaySec: 30 },
    backupKeep: 14,
  };
}

/** Kinds as the core keeps them: a role, and a line and hand-off only for implementation kinds */
function parseKinds(value: unknown): Record<string, LedgerKindRule> {
  if (!isRecord(value)) throw invalid("kinds must be an object of kind → {role, line?, handoff?}");
  const kinds: Record<string, LedgerKindRule> = {};
  for (const [name, entry] of Object.entries(value)) {
    const kind = name.trim();
    if (!kind) throw invalid("A kind needs a name");
    const rule = isRecord(entry) ? entry : {};
    if (!(ledgerRoles as readonly unknown[]).includes(rule.role)) throw invalid(`kinds.${name}.role must be decision, implementation, research, document or other`);
    if (rule.line !== undefined && rule.line !== null && (typeof rule.line !== "string" || !rule.line.trim())) throw invalid(`kinds.${name}.line must be a name`);
    if (rule.handoff !== undefined && rule.handoff !== null && typeof rule.handoff !== "boolean") throw invalid(`kinds.${name}.handoff must be true or false`);
    const role = rule.role as LedgerRole;
    kinds[kind] = role === "implementation" ? { role, line: typeof rule.line === "string" ? rule.line.trim() : "core", handoff: rule.handoff !== false } : { role };
  }
  return kinds;
}

/** Canonical JSON (sorted keys), so the same report pasted twice is recognised */
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical((value as Record<string, unknown>)[k])}`).join(",")}}`;
  return JSON.stringify(value);
}

/** Reports in a paste: fenced ```ledger blocks, else JSON lines with an "event", else the whole text */
function reportBlocks(text: string): string[] {
  const fenced = [...text.matchAll(/```ledger[^\n]*\n([\s\S]*?)```/g)].map((m) => m[1]);
  if (fenced.length) return fenced;
  const lines = text.split(/\r?\n/).filter((line) => /^\s*\{/.test(line) && /"event"\s*:/.test(line));
  return lines.length ? lines : text.trim() ? [text] : [];
}

/**
 * A backend that answers the contract from memory, for the screens before the core is connected, the self-test and
 * the unit tests. A person's operations change it and bump `rev`; waiting prompts are answered automatically once
 * their deadline passes, as auto-continue will. (macOS: DemoLedgerBackend in Services/LedgerBackend.swift)
 */
export class DemoLedgerBackend implements LedgerBackend {
  readonly kind = "demo" as const;
  readonly world: DemoWorld;
  private readonly now: () => Ms;
  private readonly lively: boolean;
  private readonly seen = new Set<string>();
  private nextSpawn: Ms;
  private spawned = 0;
  private settings = defaultSettings();
  private readonly projectSettings = new Map<string, LedgerProjectSettings>();

  constructor(options: DemoOptions = {}) {
    this.now = options.now ?? Date.now;
    this.lively = options.lively ?? false;
    const now = this.now();
    this.world = options.empty ? emptyWorld() : options.large ? largeDemoWorld(now, options.repoPath) : demoWorld(now, options.repoPath);
    this.nextSpawn = now + 60_000;
  }

  async call<M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]): Promise<LedgerMethods[M]["result"]> {
    this.tick();
    return this.answer(method, args) as LedgerMethods[M]["result"];
  }

  private answer(method: LedgerMethod, raw: unknown): unknown {
    const args = (raw ?? {}) as Record<string, unknown>;
    const w = this.world;
    switch (method) {
      case "info":
        return { schemaVersion: 1, dbPath: "demo", rev: w.rev, enabled: true };
      case "rev":
        return { rev: w.rev };
      case "state":
        return this.state(args.project as string | undefined, (args.range as LedgerRange | undefined) ?? "7d");
      case "session": {
        const id = String(args.id ?? "");
        const views = sessionViews(w, this.now());
        const session = views.get(id);
        if (!session) throw new LedgerError("NOT_FOUND", `No session ${id}`);
        const events = w.events.filter((e) => e.sessionId === id).sort((a, b) => a.ts - b.ts || a.id - b.id);
        const raw = w.sessions.find((s) => s.id === id)!;
        return { session, events, questions: w.questions.filter((q) => q.sessionId === id).map(({ reviewed: _r, ...q }) => q), overlaps: overlaps(views, w.coupled).filter((o) => o.a === id || o.b === id), cycles: raw.stream ? streamCycles(raw, events, w.baselines) : [] };
      }
      case "graph": {
        const project = String(args.project ?? "");
        if (!w.projects.some((p) => p.key === project)) throw new LedgerError("NOT_FOUND", `No project ${project}`);
        const now = this.now();
        return buildGraph(w, sessionViews(w, now), project, (args.range as LedgerRange | undefined) ?? "7d", now);
      }
      case "search":
        return { hits: searchWorld(w, sessionViews(w, this.now()), String(args.query ?? ""), args.project as string | undefined, Number(args.limit ?? 30)) };
      case "import":
        return { results: this.importText(String(args.text ?? ""), args.project as string | undefined) };
      case "human":
        this.human(args as unknown as LedgerHumanRequest);
        return { ok: true, rev: w.rev };
      case "prompt_answer":
        return this.promptAnswer(Number(args.id), args.answer as LedgerPromptAnswer);
      case "prompt_review":
        return this.promptReview(args);
      case "backup": {
        const d = new Date(this.now()), pad = (n: number) => String(n).padStart(2, "0");
        return { path: `ledger/backups/ledger-${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}-${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}.sqlite3`, created: true, size: 4096 * (8 + w.sessions.length), removed: [] };
      }
      case "settings":
        return structuredClone(this.settings);
      case "settings_set":
        return this.settingsSet(args.values);
      case "projects":
        return { projects: w.projects.map((p) => this.project(p.key)).sort((a, b) => a.key.localeCompare(b.key)) };
      case "project_set":
        return this.projectSet(args);
      case "scan": {
        const keys = typeof args.project === "string" ? [args.project] : w.projects.map((p) => p.key);
        return { results: keys.map((key) => this.scan(key)) };
      }
      case "import_legacy":
        return this.importLegacy(args);
      case "track":
        return this.track(args);
      default:
        throw new LedgerError("UNKNOWN_METHOD", `Unknown method ${String(method)}`);
    }
  }

  /** As the core: each value is checked, null restores the default, kinds are replaced as a whole */
  private settingsSet(values: unknown) {
    if (!isRecord(values)) throw invalid("Give values: {staleHours?, kinds?, autoContinue?, backupKeep?}");
    const next = structuredClone(this.settings), defaults = defaultSettings();
    for (const [key, value] of Object.entries(values)) {
      if (key === "staleHours") {
        if (value !== null && !(typeof value === "number" && value > 0 && value <= 10_000)) throw invalid("staleHours must be a number of hours (0–10000)");
        next.staleHours = (value as number | null) ?? defaults.staleHours;
      } else if (key === "backupKeep") {
        if (value !== null && !(Number.isInteger(value) && (value as number) >= 1 && (value as number) <= 365)) throw invalid("backupKeep must be a whole number (1–365)");
        next.backupKeep = (value as number | null) ?? defaults.backupKeep;
      } else if (key === "kinds") {
        next.kinds = value === null ? defaults.kinds : parseKinds(value);
      } else if (key === "autoContinue") {
        if (value !== null && !isRecord(value)) throw invalid("autoContinue must be an object");
        next.autoContinue = (value as Record<string, unknown> | null) ?? defaults.autoContinue;
      } else throw invalid(`Unknown setting ${key} (known: staleHours, kinds, autoContinue, backupKeep)`);
    }
    this.settings = next;
    this.world.staleHours = next.staleHours;
    this.world.rev++;
    return { ok: true, rev: this.world.rev, settings: structuredClone(next) };
  }

  /** A project's settings; the first project is bound to the open repository through its sessions */
  private project(key: string): LedgerProjectSettings {
    const stored = this.projectSettings.get(key);
    if (stored) return structuredClone(stored);
    const name = this.world.projects.find((p) => p.key === key)?.name ?? key;
    const repoPath = this.world.sessions.find((s) => s.project === key && s.links.repoPath)?.links.repoPath;
    return { key, name, ...(repoPath ? { repoPath } : {}), baselineSource: "tags", baselinePattern: DEFAULT_PATTERN, scanFiles: false, scanSubdirs: [] };
  }

  /** As the core: unset fields stay, null clears one, a new key adds the project */
  private projectSet(args: Record<string, unknown>) {
    const w = this.world;
    const key = typeof args.project === "string" ? args.project.trim() : "";
    if (!key) throw invalid("Missing project");
    if (!w.projects.some((p) => p.key === key)) w.projects.push({ key, name: key });
    const p = this.project(key);
    const text = (name: string): string | null | undefined => {
      const value = args[name];
      if (value === undefined || value === null) return value;
      if (typeof value !== "string") throw invalid(`${name} must be text`);
      return value.trim() || null;
    };
    const name = text("name"), repoPath = text("repoPath"), source = text("baselineSource"), pattern = text("baselinePattern"), dir = text("baselineDir");
    if (name !== undefined) p.name = name ?? key;
    if (repoPath !== undefined) { if (repoPath) p.repoPath = repoPath; else delete p.repoPath; }
    if (source !== undefined) {
      if (source && !(ledgerBaselineSources as readonly string[]).includes(source)) throw invalid("baselineSource must be tags, folder or manual");
      p.baselineSource = (source ?? "tags") as LedgerProjectSettings["baselineSource"];
    }
    if (pattern !== undefined) {
      try { new RegExp(pattern ?? DEFAULT_PATTERN, "i"); } catch (e) { throw invalid(`Invalid baseline pattern ${JSON.stringify(pattern)}: ${e instanceof Error ? e.message : String(e)}`); }
      p.baselinePattern = pattern ?? DEFAULT_PATTERN;
    }
    if (dir !== undefined) { if (dir) p.baselineDir = dir; else delete p.baselineDir; }
    if (typeof args.scanFiles === "boolean") p.scanFiles = args.scanFiles;
    if (Array.isArray(args.scanSubdirs)) p.scanSubdirs = args.scanSubdirs.map(String).map((s) => s.trim()).filter(Boolean);
    this.projectSettings.set(key, p);
    const entry = w.projects.find((x) => x.key === key)!;
    entry.name = p.name;
    w.rev++;
    return { ok: true, rev: w.rev, project: structuredClone(p) };
  }

  /** The demo's trunks are fixed; a folder source without its folder fails the way the core reports it */
  private scan(key: string) {
    const p = this.project(key);
    const found = this.world.baselines.filter((b) => b.project === key && b.source !== "inferred").length;
    if (p.baselineSource === "folder" && !p.baselineDir) return { project: key, source: p.baselineSource, found: 0, added: 0, error: "No baseline folder is set" };
    return { project: key, source: p.baselineSource, found: p.baselineSource === "manual" ? 0 : found, added: 0 };
  }

  /**
   * A claude-ledger database, as far as a demo has one: the file is never read and always holds the same two sessions
   * of a project "ledger", so a dry run counts them, an import adds them and a second import skips them.
   */
  private importLegacy(args: Record<string, unknown>) {
    const w = this.world, now = this.now();
    if (typeof args.path !== "string" || !args.path.trim()) throw invalid("Missing path (the claude-ledger database file)");
    const dryRun = args.dryRun === true;
    const ids = ["S1020-01", "S1021-01"];
    const skipped = ids.filter((id) => w.sessions.some((s) => s.id === id));
    const fresh = ids.filter((id) => !skipped.includes(id));
    const newProject = fresh.length > 0 && !w.projects.some((p) => p.key === "ledger");
    const versions = fresh.length ? ["0.9.0", "1.0.0"].filter((v) => !w.baselines.some((b) => b.project === "ledger" && b.version === v)) : [];
    const counts = { projects: newProject ? 1 : 0, baselines: versions.length, baselinesUpdated: 0, sessions: fresh.length, events: fresh.length * 3, questions: fresh.includes("S1021-01") ? 1 : 0, imports: fresh.length ? 2 : 0 };
    if (!dryRun && fresh.length) {
      const day = 24 * 60 * 60_000;
      if (newProject) w.projects.push({ key: "ledger", name: "ledger" });
      versions.forEach((version, i) => w.baselines.push({ project: "ledger", version, ts: now - (12 - i) * day, source: "tag" }));
      for (const [i, id] of fresh.entries()) {
        const merged = id === "S1020-01", at = now - (10 - i) * day;
        w.sessions.push({ id, project: "ledger", title: merged ? "Release checklist" : "API naming", kind: merged ? "document" : "decision", role: merged ? "document" : "decision", status: merged ? "merged" : "active", ...(merged ? { mergedInto: "1.0.0", ackAt: at + 2 * 3_600_000 } : {}), baseVersion: "0.9.0", baseCurrent: "0.9.0", touches: [], related: [], links: {}, color: (w.sessions.filter((s) => s.project === "ledger").length % 8), createdAt: at, lastAt: at + 3_600_000, lastAgentAt: at + 3_600_000 });
        const event = (type: string, ts: Ms, summary: string) => w.events.push({ id: w.nextEvent++, sessionId: id, ts, type, actor: "agent", summary });
        event("start", at, merged ? "Started the release checklist" : "Started on the API names");
        event("progress", at + 1_800_000, merged ? "Checked the release notes" : "Listed the endpoints");
        if (merged) event("merged", at + 3_600_000, "Merged into 1.0.0");
        else {
          event("question", at + 3_600_000, "Asked about the naming rule");
          w.questions.push({ id: w.nextQuestion++, sessionId: id, text: "Plural or singular resource names?", state: "open", createdAt: at + 3_600_000 });
        }
      }
      w.rev++;
    }
    return { ok: true, dryRun, rev: w.rev, counts, skipped, errors: [] };
  }

  private state(project: string | undefined, range: LedgerRange): LedgerState {
    const w = this.world, now = this.now(), from = rangeStart(range, now);
    const views = sessionViews(w, now);
    const all = [...views.values()].filter((s) => !project || s.project === project);
    // as the core: archived sessions older than the period are hidden and counted; everything else shows
    const sessions = all.filter((s) => s.verdict !== "archived" || s.lastAt >= from);
    const shown = new Set(sessions.map((s) => s.id));
    const live = (p: DemoPrompt) => (p.sessionId ? shown.has(p.sessionId) : !project);
    const questions = w.questions.filter((q) => q.state === "open" && shown.has(q.sessionId) && views.get(q.sessionId)?.verdict !== "archived").map(({ reviewed: _r, ...q }) => q);
    const pendingPrompts = w.prompts.filter((p) => p.state === "waiting" && live(p)).map(({ reviewed: _r, ...p }) => p);
    const autoReview = w.prompts.filter((p) => p.state === "auto" && !p.reviewed && live(p)).map(({ reviewed: _r, ...p }) => p);
    const streams = w.sessions.filter((s) => s.stream && shown.has(s.id)).flatMap((s) => streamCycles(s, w.events.filter((e) => e.sessionId === s.id).sort((a, b) => a.ts - b.ts || a.id - b.id), w.baselines));
    const groups = inboxGroups({ sessions, questions, pendingPrompts, autoReview }, null);
    const count = (id: string) => groups.find((g) => g.id === id)?.items.length ?? 0;
    const attention = { questions: count("questions"), tidy: count("tidy"), decide: count("decide"), autoReview: count("auto"), total: 0 };
    attention.total = attention.questions + attention.tidy + attention.decide + attention.autoReview;
    return {
      schemaVersion: 1, rev: w.rev, now,
      projects: w.projects.map((p) => ({ ...p, open: [...views.values()].filter((s) => s.project === p.key && isLive(s) && !s.stream).length })),
      baselines: w.baselines.filter((b) => !project || b.project === project),
      sessions, questions, streams,
      overlaps: overlaps(views, w.coupled).filter((o) => shown.has(o.a) && shown.has(o.b)),
      pendingPrompts, autoReview, attention, hiddenBefore: all.length - sessions.length,
    };
  }

  private session(id: string): DemoSession {
    const s = this.world.sessions.find((x) => x.id === id);
    if (!s) throw new LedgerError("NOT_FOUND", `No session ${id}`);
    return s;
  }

  private record(sessionId: string, type: string, data: Record<string, unknown> = {}, body?: string) {
    const w = this.world;
    w.events.push({ id: w.nextEvent++, sessionId, ts: this.now(), type, actor: "human", data, ...(body ? { body } : {}) });
  }

  private human(r: LedgerHumanRequest) {
    const w = this.world, now = this.now();
    const question = r.questionId !== undefined ? w.questions.find((q) => q.id === r.questionId) : undefined;
    if (r.questionId !== undefined && !question) throw new LedgerError("NOT_FOUND", `No question ${r.questionId}`);
    const s = this.session(r.sessionId);
    const id = s.id;
    const need = () => s;
    switch (r.action) {
      case "ack":
        need().ackAt = now;
        break;
      case "unack":
        delete need().ackAt;
        break;
      case "archive":
        need().archivedAt = now;
        break;
      case "unarchive":
        delete need().archivedAt;
        break;
      case "shelve":
        need().status = this.shelvable(need());
        break;
      case "set_status": {
        const status = r.status as LedgerStatus, x = need();
        if (!["active", "done", "merged", "closed", "dropped", "shelved"].includes(status)) throw new LedgerError("INVALID_ARGUMENT", `Unknown status ${String(status)}`);
        x.status = status === "shelved" ? this.shelvable(x) : status;
        if (status === "merged") x.mergedInto = r.into ?? this.head(x.project);
        else delete x.mergedInto;
        // a status a person chooses counts as confirmed; making it active again starts over
        if (status === "merged" || status === "closed" || status === "dropped") x.ackAt = now;
        if (status === "active") { delete x.ackAt; delete x.archivedAt; }
        break;
      }
      case "answer":
      case "dismiss":
        if (!question || question.state !== "open") throw new LedgerError("CONFLICT", "The question is no longer open.");
        question.state = r.action === "answer" ? "answered" : "dismissed";
        question.answeredAt = now;
        if (r.action === "answer") { question.answer = (r.answer ?? r.text ?? "").trim(); question.answeredBy = "human"; }
        break;
      case "snooze":
        if (r.until) need().snoozeUntil = r.until;
        else delete need().snoozeUntil;
        break;
      case "message":
      case "link":
        break;
      default:
        throw new LedgerError("INVALID_ARGUMENT", `Unknown action ${String(r.action)}`);
    }
    this.record(id, r.action, { ...(r.status ? { status: r.status } : {}), ...(r.into ? { version: r.into } : {}), ...(r.questionId !== undefined ? { questionId: r.questionId } : {}), ...(r.until !== undefined ? { until: r.until } : {}) }, r.action === "answer" ? r.answer ?? r.text : r.action === "message" ? r.text : undefined);
    w.rev++;
  }

  /**
   * As the core's `track`: the session of an agent about to be launched, active with no agent report yet. What is left
   * out comes from the given paths, since the demo reads no checkout: the project bound to `repoPath`, else its folder's
   * name; the branch, else the folder's name, as the title; the repository's policy from `autoContinue.repositories`.
   */
  private track(args: Record<string, unknown>) {
    const w = this.world, now = this.now();
    const links: DemoSession["links"] = {};
    for (const key of ["repoPath", "branch", "worktree", "cwd", "agentId"] as const) {
      const value = args[key];
      if (value === undefined || value === null) continue;
      if (typeof value !== "string") throw invalid(`${key} must be text`);
      if (value.trim()) links[key] = value.trim();
    }
    const folder = links.cwd ?? links.worktree ?? links.repoPath;
    const repo = links.repoPath ?? links.worktree;
    const name = (path: string | undefined) => path?.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || undefined;
    const trim = (path: string) => path.replace(/[\\/]+$/, "");
    const bound = repo ? w.projects.find((p) => this.project(p.key).repoPath && trim(this.project(p.key).repoPath!) === trim(repo)) : undefined;
    const project = typeof args.project === "string" && args.project.trim() ? args.project.trim() : bound?.key ?? name(repo);
    if (!project) throw invalid("Give project or repoPath");
    if (!w.projects.some((p) => p.key === project)) {
      w.projects.push({ key: project, name: project });
      if (repo) this.projectSettings.set(project, { ...this.project(project), repoPath: repo });
    }
    let policy: DemoSession["autoContinue"] | null | undefined = args.autoContinue as DemoSession["autoContinue"] | null | undefined;
    if (policy === undefined && links.repoPath) {
      const stored = this.settings.autoContinue.repositories;
      const own = stored && typeof stored === "object" ? Object.entries(stored as Record<string, DemoSession["autoContinue"]>).find(([path]) => trim(path) === trim(links.repoPath!)) : undefined;
      policy = own?.[1];
    }
    if (policy && (typeof policy.enabled !== "boolean" || !Number.isInteger(policy.delaySec))) throw invalid("autoContinue needs enabled and delaySec");
    const base = typeof args.base === "string" ? /^v?(\d+(?:\.\d+)+)$/i.exec(args.base.trim())?.[1] : undefined;
    const kind = typeof args.kind === "string" ? args.kind.trim() : "";
    const d = new Date(now), day = `S${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}-`;
    let n = w.sessions.filter((x) => x.id.startsWith(day)).length + 1;
    while (w.sessions.some((x) => x.id === `${day}${String(n).padStart(2, "0")}`)) n++;
    const id = `${day}${String(n).padStart(2, "0")}`;
    const title = typeof args.title === "string" && args.title.trim() ? args.title.trim() : links.branch ?? name(folder) ?? "(untitled)";
    w.sessions.push({ id, project, title, kind, role: roleOf(kind), status: "active", ...(base ? { baseVersion: base, baseCurrent: base } : {}), touches: [], related: [], links, color: w.sessions.filter((x) => x.project === project).length % 8, createdAt: now, lastAt: now, ...(policy ? { autoContinue: { enabled: policy.enabled, delaySec: policy.delaySec } } : {}) });
    w.events.push({ id: w.nextEvent++, sessionId: id, ts: now, type: "hook", actor: "hook", summary: "Started from Gitrochi", ...(base ? { version: base } : {}), data: { hook: "launch", ...(links.agentId ? { agentId: links.agentId } : {}), ...(policy ? { autoContinue: policy } : {}) } });
    w.rev++;
    return { ok: true, rev: w.rev, session: sessionViews(w, now).get(id)! };
  }

  /** As the core: only research and documents are shelved */
  private shelvable(s: DemoSession): "shelved" {
    if (s.role !== "research" && s.role !== "document") throw new LedgerError("INVALID_ARGUMENT", "Only research and document sessions can be shelved.");
    return "shelved";
  }

  private head(project: string) {
    return this.world.baselines.filter((b) => b.project === project).map((b) => b.version).sort(compareVersions).pop();
  }

  /** As the core: any answer closes a waiting prompt (the hook handler reads it); a prompt that no longer waits is left alone */
  private promptAnswer(id: number, answer: LedgerPromptAnswer) {
    const w = this.world;
    const p = w.prompts.find((x) => x.id === id);
    if (!p) throw new LedgerError("NOT_FOUND", `No prompt ${id}`);
    if (!answer || typeof answer !== "object") throw new LedgerError("INVALID_ARGUMENT", "answer must be an object");
    if (p.state !== "waiting") return { ok: false, rev: w.rev, state: p.state };
    Object.assign(p, { state: "answered", answer: { ...answer }, answeredBy: "human", reviewed: true });
    if (p.sessionId) this.record(p.sessionId, "prompt_answer", { promptId: id });
    w.rev++;
    return { ok: true, rev: w.rev, state: p.state };
  }

  /** Marks automatic answers as seen: one prompt, or all of them */
  private promptReview(args: Record<string, unknown>) {
    const w = this.world;
    const all = args.all === true, id = Number(args.id);
    if (!all && !w.prompts.some((p) => p.id === id)) throw new LedgerError("NOT_FOUND", `No prompt ${String(args.id)}`);
    let reviewed = 0;
    for (const p of w.prompts) if (p.state === "auto" && !p.reviewed && (all || p.id === id)) { p.reviewed = true; reviewed++; }
    if (reviewed) w.rev++;
    return { ok: true, rev: w.rev, reviewed };
  }

  /** Answers waiting prompts whose deadline passed, and in a lively demo asks a new question now and then */
  private tick() {
    const w = this.world, now = this.now();
    for (const p of w.prompts) {
      if (p.state !== "waiting" || !p.deadline || p.deadline > now) continue;
      // what auto-continue proposed; plan approval is off by default, so a plan goes back to the agent's terminal
      const proposed = p.payload.proposed && typeof p.payload.proposed === "object" ? (p.payload.proposed as Record<string, unknown>) : null;
      const auto = p.kind !== "exit_plan_mode" && !!proposed;
      if (!auto) p.state = "released";
      else Object.assign(p, { state: "auto", answeredBy: "auto", answer: proposed });
      if (p.sessionId && auto) w.events.push({ id: w.nextEvent++, sessionId: p.sessionId, ts: p.deadline, type: "auto_reply", actor: "auto", summary: `Answered automatically: ${String(p.payload.question ?? p.kind)}`, data: { promptId: p.id, kind: p.kind, answer: proposed } });
      w.rev++;
    }
    if (!this.lively || now < this.nextSpawn || w.prompts.some((p) => p.state === "waiting" && p.deadline)) return;
    const live = w.sessions.filter((s) => isLive(s) && !s.archivedAt);
    if (!live.length) return;
    const s = live[this.spawned % live.length];
    const format = "Which report format do you prefer?";
    const templates: Omit<DemoPrompt, "id" | "sessionId" | "createdAt" | "deadline" | "state">[] = [
      { kind: "stop_question", payload: promptPayload("stop_question", "Shall I keep going with the next step of the plan?", 90, { type: "reply", text: "Yes, continue with the next step." }) },
      { kind: "permission", payload: promptPayload("permission", "npm run build", 90, { type: "allow" }, { tool: { name: "Bash", summary: "npm run build" } }) },
      { kind: "ask_user_question", payload: promptPayload("ask_user_question", format, 90, { type: "answers", answers: { [format]: "Short summary" }, note: "Chosen because it was marked as recommended." }, { questions: [{ question: format, multiSelect: false, options: [{ label: "Short summary", recommended: true }, { label: "Full log", recommended: false }] }] }) },
    ];
    w.prompts.push({ id: w.nextPrompt++, sessionId: s.id, ...(s.links.agentId ? { agentId: s.links.agentId } : {}), ...templates[this.spawned % templates.length], createdAt: now, deadline: now + 90_000, state: "waiting" });
    this.spawned++;
    this.nextSpawn = now + 150_000;
    w.rev++;
  }

  private importText(text: string, project: string | undefined): LedgerImportResult[] {
    const w = this.world, now = this.now();
    const results = reportBlocks(text).map((block, index): LedgerImportResult => {
      let report: Record<string, unknown>;
      try {
        const parsed: unknown = JSON.parse(block);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
        report = parsed as Record<string, unknown>;
      } catch {
        return { index, ok: false, duplicate: false, error: "Not a JSON report" };
      }
      const hash = canonical(report);
      // as the core, a report already imported is fine: ok and marked duplicate
      if (this.seen.has(hash)) return { index, ok: true, duplicate: true, ...(typeof report.session === "string" ? { sessionId: report.session } : {}) };
      const type = String(report.event ?? "");
      if (!EVENTS.has(type)) return { index, ok: false, duplicate: false, error: `Unknown event "${type}"` };
      const given = typeof report.session === "string" ? report.session.trim() : "";
      if (given && !SESSION_ID.test(given)) return { index, ok: false, duplicate: false, error: `Invalid session ID "${given}"` };
      if ((type === "sync" || type === "release" || type === "applied") && typeof report.version !== "string") return { index, ok: false, duplicate: false, error: `"${type}" needs a version` };
      if (type === "question" && typeof report.question !== "string") return { index, ok: false, duplicate: false, error: "A question needs its text" };
      let s = given ? w.sessions.find((x) => x.id === given) : undefined;
      if (!s) {
        const key = typeof report.project === "string" ? report.project : project;
        if (!key) return { index, ok: false, duplicate: false, error: "A new session needs a project" };
        if (!w.projects.some((p) => p.key === key)) w.projects.push({ key, name: key });
        const kind = typeof report.kind === "string" ? report.kind : "other";
        s = { id: given || `S-import-${w.sessions.length + 1}`, project: key, title: typeof report.title === "string" ? report.title : "Imported session", kind, role: roleOf(kind), status: "active", touches: [], related: [], links: {}, color: 1 + (w.sessions.filter((x) => x.project === key).length % 7), createdAt: now + index, lastAt: now + index, ...(typeof report.base === "string" ? { baseVersion: report.base, baseCurrent: report.base } : {}) };
        w.sessions.push(s);
      }
      const ts = now + index;
      s.lastAt = s.lastAgentAt = ts;
      if (["done", "merged", "closed", "dropped", "shelved"].includes(type)) s.status = type as LedgerStatus;
      else if (type !== "note" && type !== "heartbeat" && s.status !== "active") { s.status = "active"; delete s.ackAt; delete s.archivedAt; delete s.mergedInto; }
      if (type === "merged" && typeof report.into === "string") s.mergedInto = report.into;
      if (type === "sync" && typeof report.version === "string") s.baseCurrent = report.version;
      if (type !== "note" && type !== "heartbeat") delete s.ackAt;
      if (type === "question") w.questions.push({ id: w.nextQuestion++, sessionId: s.id, text: String(report.question), state: "open", createdAt: ts });
      w.events.push({ id: w.nextEvent++, sessionId: s.id, ts, type, actor: "agent", ...(typeof report.summary === "string" ? { summary: report.summary } : {}), ...(typeof report.body === "string" ? { body: report.body } : {}), ...(typeof report.version === "string" ? { version: report.version } : {}) });
      this.seen.add(hash);
      return { index, ok: true, duplicate: false, sessionId: s.id };
    });
    if (results.some((r) => r.ok)) w.rev++;
    return results;
  }
}
