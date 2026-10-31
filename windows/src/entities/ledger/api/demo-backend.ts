import type { LedgerHumanRequest, LedgerImportResult, LedgerMethod, LedgerMethods, LedgerPromptAnswer, LedgerRange, LedgerRole, LedgerState, LedgerStatus, Ms } from "../model/types";
import { inboxGroups } from "../lib/inbox";
import { compareVersions } from "../lib/version";
import { LedgerError, type LedgerBackend } from "./backend";
import { type DemoPrompt, type DemoSession, type DemoWorld, demoWorld, emptyWorld, largeDemoWorld } from "./demo-data";
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
        this.promptAnswer(Number(args.id), args.answer as LedgerPromptAnswer);
        return { ok: true };
      case "backup":
        return { path: "ledger/backups/ledger-demo.sqlite3" };
      default:
        throw new LedgerError("UNKNOWN_METHOD", `Unknown method ${String(method)}`);
    }
  }

  private state(project: string | undefined, range: LedgerRange): LedgerState {
    const w = this.world, now = this.now(), from = rangeStart(range, now);
    const views = sessionViews(w, now);
    const all = [...views.values()].filter((s) => !project || s.project === project);
    // quiet sessions older than the period are hidden; anything that needs a person stays whatever its age
    const quiet = (s: (typeof all)[number]) => (s.verdict === "archived" || s.verdict === "shelved") && s.lastAt < from;
    const sessions = all.filter((s) => !quiet(s));
    const shown = new Set(sessions.map((s) => s.id));
    const questions = w.questions.filter((q) => shown.has(q.sessionId) && (q.state === "open" || (q.answeredBy === "auto" && !q.reviewed))).map(({ reviewed: _r, ...q }) => q);
    const pendingPrompts = w.prompts.filter((p) => (p.state === "waiting" || (p.state === "auto" && !p.reviewed)) && (p.sessionId ? shown.has(p.sessionId) : !project)).map(({ reviewed: _r, ...p }) => p);
    const streams = w.sessions.filter((s) => s.stream && shown.has(s.id)).flatMap((s) => streamCycles(s, w.events.filter((e) => e.sessionId === s.id).sort((a, b) => a.ts - b.ts || a.id - b.id), w.baselines));
    const groups = inboxGroups({ sessions, questions, pendingPrompts }, null);
    const count = (id: string) => groups.find((g) => g.id === id)?.items.length ?? 0;
    const attention = { questions: count("questions"), tidy: count("tidy"), decide: count("decide"), autoReview: count("auto"), total: 0 };
    attention.total = attention.questions + attention.tidy + attention.decide + attention.autoReview;
    return {
      schemaVersion: 1, rev: w.rev, now,
      projects: w.projects.map((p) => ({ ...p, open: [...views.values()].filter((s) => s.project === p.key && isLive(s) && !s.stream).length })),
      baselines: w.baselines.filter((b) => !project || b.project === project),
      sessions, questions, streams,
      overlaps: overlaps(views, w.coupled).filter((o) => shown.has(o.a) && shown.has(o.b)),
      pendingPrompts, attention, hiddenBefore: all.length - sessions.length,
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
    const prompt = r.promptId !== undefined ? w.prompts.find((p) => p.id === r.promptId) : undefined;
    const question = r.questionId !== undefined ? w.questions.find((q) => q.id === r.questionId) : undefined;
    if (r.promptId !== undefined && !prompt) throw new LedgerError("NOT_FOUND", `No prompt ${r.promptId}`);
    if (r.questionId !== undefined && !question) throw new LedgerError("NOT_FOUND", `No question ${r.questionId}`);
    // an automatic reply to a prompt may have no session
    const s = r.sessionId || !prompt ? this.session(r.sessionId) : undefined;
    const id = s?.id ?? "";
    const need = () => {
      if (!s) throw new LedgerError("INVALID", `"${r.action}" needs a session`);
      return s;
    };
    switch (r.action) {
      case "ack":
        if (question) question.reviewed = true;
        else if (prompt) prompt.reviewed = true;
        else need().ackAt = now;
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
        need().status = "shelved";
        break;
      case "set_status": {
        const status = r.status as LedgerStatus, x = need();
        if (!["active", "done", "merged", "closed", "dropped", "shelved"].includes(status)) throw new LedgerError("INVALID", `Unknown status ${String(status)}`);
        x.status = status;
        if (status === "merged") x.mergedInto = r.version ?? this.head(x.project);
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
        if (r.action === "answer") { question.answer = (r.text ?? "").trim(); question.answeredBy = "human"; }
        break;
      case "snooze":
        if (r.until) need().snoozeUntil = r.until;
        else delete need().snoozeUntil;
        break;
      case "message":
        if (question) question.reviewed = true;
        if (prompt) prompt.reviewed = true;
        break;
      case "link":
        break;
      default:
        throw new LedgerError("INVALID", `Unknown action ${String(r.action)}`);
    }
    if (id) this.record(id, r.action, { ...(r.status ? { status: r.status } : {}), ...(r.version ? { version: r.version } : {}), ...(r.questionId !== undefined ? { questionId: r.questionId } : {}), ...(r.promptId !== undefined ? { promptId: r.promptId } : {}), ...(r.until !== undefined ? { until: r.until } : {}) }, r.action === "answer" || r.action === "message" ? r.text : undefined);
    w.rev++;
  }

  private head(project: string) {
    return this.world.baselines.filter((b) => b.project === project).map((b) => b.version).sort(compareVersions).pop();
  }

  private promptAnswer(id: number, answer: LedgerPromptAnswer) {
    const w = this.world;
    const p = w.prompts.find((x) => x.id === id);
    if (!p) throw new LedgerError("NOT_FOUND", `No prompt ${id}`);
    if (p.state !== "waiting") throw new LedgerError("CONFLICT", "The prompt was already answered.");
    if (answer.action === "hold") p.deadline = 0;
    else if (answer.action === "release") p.state = "released";
    else Object.assign(p, { state: "answered", answer: { ...answer }, answeredBy: "human" });
    if (p.sessionId) this.record(p.sessionId, "prompt_answer", { promptId: id, answer: answer.action });
    w.rev++;
  }

  /** Answers waiting prompts whose deadline passed, and in a lively demo asks a new question now and then */
  private tick() {
    const w = this.world, now = this.now();
    for (const p of w.prompts) {
      if (p.state !== "waiting" || !p.deadline || p.deadline > now) continue;
      const options = Array.isArray(p.payload.options) ? (p.payload.options as string[]) : [];
      // plan approval is never automatic; the agent's own terminal asks the person
      const auto = p.kind !== "exit_plan_mode";
      if (!auto) p.state = "released";
      else Object.assign(p, { state: "auto", answeredBy: "auto", answer: p.kind === "permission" ? { action: "allow" } : { action: "reply", text: options[0] ?? "Continue with the safest option." } });
      if (p.sessionId && auto) w.events.push({ id: w.nextEvent++, sessionId: p.sessionId, ts: p.deadline, type: "auto_reply", actor: "auto", summary: p.kind === "permission" ? `Allowed ${String(p.payload.command ?? p.payload.tool ?? "")}` : `Answered: ${options[0] ?? "Continue with the safest option."}` });
      w.rev++;
    }
    if (!this.lively || now < this.nextSpawn || w.prompts.some((p) => p.state === "waiting" && p.deadline)) return;
    const live = w.sessions.filter((s) => isLive(s) && !s.archivedAt);
    if (!live.length) return;
    const s = live[this.spawned % live.length];
    const templates: Omit<DemoPrompt, "id" | "sessionId" | "createdAt" | "deadline" | "state">[] = [
      { kind: "stop_question", payload: { question: "Shall I keep going with the next step of the plan?" } },
      { kind: "permission", payload: { tool: "Bash", command: "npm run build" } },
      { kind: "ask_user_question", payload: { question: "Which report format do you prefer?", options: ["Short summary (recommended)", "Full log"] } },
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
      if (this.seen.has(hash)) return { index, ok: false, duplicate: true, ...(typeof report.session === "string" ? { sessionId: report.session } : {}) };
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
