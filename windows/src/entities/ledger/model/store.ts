import { env, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import type { LedgerBackend } from "../api/backend";
import { DemoLedgerBackend } from "../api/demo-backend";
import { projectForRepository } from "../lib/filter";
import { summarizeImport, type ImportSummary } from "../lib/imports";
import { inverseOperation, operationTitle } from "../lib/undo";
import type { LedgerGraph, LedgerHumanRequest, LedgerPendingPrompt, LedgerPromptAnswer, LedgerQuestion, LedgerRange, LedgerSearchHit, LedgerSession, LedgerSessionDetail, LedgerState, LedgerVerdict } from "./types";
import { ledgerRanges } from "./types";

export const ledgerViews = ["inbox", "board", "graph", "streams"] as const;
export type LedgerView = (typeof ledgerViews)[number];

/** "repository" follows the open repository, "all" shows every project, anything else is a project key */
export type LedgerProjectChoice = string;

export interface LedgerToast {
  id: number;
  message: string;
  /** The calls that take the operation back; the toast offers Undo while it shows */
  undo: LedgerHumanRequest[] | null;
  error: boolean;
}

/** Seconds between `rev` reads; the state is read again only when it moved */
export const LEDGER_POLL_MS = 2000;
const TOAST_MS = 7000;

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/**
 * The Ledger page's state, one per app: the contract `State` read when `rev` moves, the selected session's detail, the
 * graph, filters and a person's operations with undo. (macOS: Store/LedgerStore.swift)
 */
export class LedgerStore extends Observable {
  state: LedgerState | null = null;
  /** Client time the state was read at, to run countdowns on the backend's clock */
  stateReadAt = 0;
  error: string | null = null;
  view: LedgerView;
  range: LedgerRange;
  projectChoice: LedgerProjectChoice;
  repoPath: string | null = null;
  /** Board filters */
  filterText = "";
  verdicts = new Set<LedgerVerdict>();
  showArchived = false;
  /** Board multi-selection */
  checked = new Set<string>();
  selectedId: string | null = null;
  detail: LedgerSessionDetail | null = null;
  detailError: string | null = null;
  /** An event to scroll to in the inspector (from search) */
  focusEventId: number | null = null;
  graph: LedgerGraph | null = null;
  graphError: string | null = null;
  toast: LedgerToast | null = null;
  /** Operations in flight; buttons wait while one runs */
  busy = 0;

  private rev = -1;
  private sessions = new Map<string, LedgerSession>();
  private graphKey = "";
  private timer: ReturnType<typeof setInterval> | null = null;
  private users = 0;
  private refreshing: Promise<void> | null = null;
  private again = false;
  private toastTimer: ReturnType<typeof setTimeout> | null = null;
  private toastId = 0;

  constructor(readonly backend: LedgerBackend) {
    super();
    const view = settings.get<string>("ledgerView", "inbox");
    this.view = (ledgerViews as readonly string[]).includes(view) ? (view as LedgerView) : "inbox";
    const range = settings.get<string>("ledgerGraphRange", "7d");
    this.range = (ledgerRanges as readonly string[]).includes(range) ? (range as LedgerRange) : "7d";
    this.projectChoice = settings.get<string>("ledgerProject", "repository");
  }

  /** Called to tell observers about a change made from outside (filters typed into the page) */
  changed() {
    this.emit();
  }

  // MARK: Reading

  /** Polls while a page shows the Ledger; the last one to leave stops it */
  start() {
    if (this.users++ === 0) {
      void this.refresh(true);
      this.timer = setInterval(() => void this.refresh(), LEDGER_POLL_MS);
    }
    return () => this.stop();
  }

  stop() {
    if (--this.users > 0) return;
    this.users = 0;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** Reads `rev`, and the state (with the open detail and graph) only when it moved or `force` asks for it */
  refresh(force = false): Promise<void> {
    if (this.refreshing) {
      this.again ||= force;
      return this.refreshing;
    }
    this.refreshing = (async () => {
      try {
        const { rev } = await this.backend.call("rev", {});
        if (!force && rev === this.rev && this.state) return;
        const state = await this.backend.call("state", { range: this.range });
        this.applyState(state);
        await Promise.all([this.selectedId ? this.loadDetail() : null, this.view === "graph" ? this.loadGraph() : null]);
      } catch (e) {
        this.error = message(e);
        this.emit();
      } finally {
        this.refreshing = null;
      }
      if (this.again) {
        this.again = false;
        await this.refresh(true);
      }
    })();
    return this.refreshing;
  }

  private applyState(state: LedgerState) {
    this.state = state;
    this.rev = state.rev;
    this.stateReadAt = Date.now();
    this.error = null;
    this.sessions = new Map(state.sessions.map((s) => [s.id, s]));
    for (const id of this.checked) if (!this.sessions.has(id)) this.checked.delete(id);
    this.emit();
  }

  session(id: string | null | undefined): LedgerSession | undefined {
    return id ? this.sessions.get(id) : undefined;
  }

  /** The project the open repository belongs to, inferred from its sessions */
  get repositoryProject(): string | null {
    return this.state ? projectForRepository(this.state, this.repoPath) : null;
  }

  /** The project every view filters to; null = all projects */
  get project(): string | null {
    if (this.projectChoice === "all") return null;
    if (this.projectChoice === "repository") return this.repositoryProject;
    return this.state?.projects.some((p) => p.key === this.projectChoice) ? this.projectChoice : null;
  }

  /** "This repository" is chosen but no session belongs to it */
  get repositoryWithoutSessions(): boolean {
    return this.projectChoice === "repository" && !!this.repoPath && !!this.state && !this.repositoryProject;
  }

  /** The Graph needs one project: the chosen one, else the first */
  get graphProject(): string | null {
    return this.project ?? this.state?.projects[0]?.key ?? null;
  }

  async loadDetail() {
    const id = this.selectedId;
    if (!id) return;
    try {
      const detail = await this.backend.call("session", { id });
      if (this.selectedId !== id) return;
      this.detail = detail;
      this.detailError = null;
    } catch (e) {
      if (this.selectedId !== id) return;
      this.detailError = message(e);
    }
    this.emit();
  }

  /** A session's detail without selecting it (stream cards) */
  readSession(id: string) {
    return this.backend.call("session", { id });
  }

  /** The last `rev` read; views cache what they load against it */
  get revision() {
    return this.rev;
  }

  async loadGraph(force = false) {
    const project = this.graphProject;
    if (!project) return;
    const key = `${project}|${this.range}|${this.rev}`;
    if (!force && key === this.graphKey) return;
    this.graphKey = key;
    try {
      const graph = await this.backend.call("graph", { project, range: this.range });
      if (this.graphKey !== key) return;
      this.graph = graph;
      this.graphError = null;
    } catch (e) {
      this.graphError = message(e);
      this.graphKey = "";
    }
    this.emit();
  }

  // MARK: Navigation and filters

  setView(view: LedgerView) {
    if (this.view === view) return;
    this.view = view;
    settings.set("ledgerView", view);
    this.emit();
    if (view === "graph") void this.loadGraph();
  }

  /** The period, remembered; "Show more" widens it one step */
  setRange(range: LedgerRange) {
    if (this.range === range) return;
    this.range = range;
    settings.set("ledgerGraphRange", range);
    this.emit();
    void this.refresh(true);
  }

  setProjectChoice(choice: LedgerProjectChoice) {
    if (this.projectChoice === choice) return;
    this.projectChoice = choice;
    settings.set("ledgerProject", choice);
    this.checked.clear();
    this.emit();
    if (this.view === "graph") void this.loadGraph();
  }

  /** The repository of the tab showing the page */
  setRepository(path: string | null) {
    if (this.repoPath === path) return;
    this.repoPath = path;
    this.emit();
    if (this.view === "graph") void this.loadGraph();
  }

  toggleVerdict(verdict: LedgerVerdict, only = false) {
    if (only) this.verdicts = this.verdicts.size === 1 && this.verdicts.has(verdict) ? new Set() : new Set([verdict]);
    else if (this.verdicts.has(verdict)) this.verdicts.delete(verdict);
    else this.verdicts.add(verdict);
    this.emit();
  }

  /** The Board on one verdict, from the verdict list */
  showVerdict(verdict: LedgerVerdict) {
    this.verdicts = new Set([verdict]);
    if (verdict === "archived") this.showArchived = true;
    this.setView("board");
    this.emit();
  }

  /** Opens a session in the inspector; `eventId` scrolls its timeline there */
  select(id: string | null, eventId: number | null = null) {
    const changed = this.selectedId !== id;
    this.selectedId = id;
    this.focusEventId = eventId;
    if (changed) {
      this.detail = null;
      this.detailError = null;
    }
    this.emit();
    if (id) void this.loadDetail();
  }

  toggleChecked(id: string, on = !this.checked.has(id)) {
    if (on) this.checked.add(id);
    else this.checked.delete(id);
    this.emit();
  }

  setChecked(ids: Iterable<string>) {
    this.checked = new Set(ids);
    this.emit();
  }

  // MARK: A person's operations

  /** One operation; confirm, archive, status changes and snoozes show a toast with Undo */
  human(request: LedgerHumanRequest): Promise<boolean> {
    return this.humanAll([request], t(operationTitle(request), request.sessionId));
  }

  /** The same operation on several sessions, undone as one */
  bulk(action: LedgerHumanRequest["action"], ids: readonly string[], extra: Omit<LedgerHumanRequest, "action" | "sessionId"> = {}): Promise<boolean> {
    const requests = ids.map((sessionId) => ({ ...extra, action, sessionId }));
    const title = requests.length === 1 ? t(operationTitle(requests[0]), requests[0].sessionId) : t("{0} sessions updated", requests.length);
    return this.humanAll(requests, title);
  }

  private async humanAll(requests: LedgerHumanRequest[], title: string): Promise<boolean> {
    const undo: LedgerHumanRequest[] = [];
    let undoable = true;
    for (const r of requests) {
      const before = this.session(r.sessionId);
      const inverse = before ? inverseOperation(before, r) : null;
      if (inverse) undo.push(...inverse);
      else undoable = false;
    }
    this.busy++;
    this.emit();
    try {
      for (const r of requests) await this.backend.call("human", r);
      this.showToast(title, undoable && undo.length ? undo : null);
      return true;
    } catch (e) {
      this.showToast(message(e), null, true);
      return false;
    } finally {
      this.busy--;
      await this.refresh(true);
    }
  }

  /** Takes back the operation the toast shows */
  async undo() {
    const undo = this.toast?.undo;
    if (!undo) return;
    this.hideToast();
    this.busy++;
    this.emit();
    try {
      for (const r of undo) await this.backend.call("human", r);
      this.showToast(t("Undone"), null);
    } catch (e) {
      this.showToast(message(e), null, true);
    } finally {
      this.busy--;
      await this.refresh(true);
    }
  }

  answer(question: LedgerQuestion, text: string) {
    return this.human({ action: "answer", sessionId: question.sessionId, questionId: question.id, text: text.trim() });
  }

  dismiss(question: LedgerQuestion) {
    return this.human({ action: "dismiss", sessionId: question.sessionId, questionId: question.id });
  }

  /** Accepts an automatic reply (it leaves the Inbox) or sends the session a correction for it */
  reviewAuto(target: { question: LedgerQuestion } | { prompt: LedgerPendingPrompt }, correction?: string) {
    const sessionId = "question" in target ? target.question.sessionId : target.prompt.sessionId ?? "";
    const ref = "question" in target ? { questionId: target.question.id } : { promptId: target.prompt.id };
    return correction === undefined ? this.human({ action: "ack", sessionId, ...ref }) : this.human({ action: "message", sessionId, text: correction.trim(), ...ref });
  }

  async answerPrompt(prompt: LedgerPendingPrompt, answer: LedgerPromptAnswer): Promise<boolean> {
    this.busy++;
    this.emit();
    try {
      await this.backend.call("prompt_answer", { id: prompt.id, answer });
      const titles: Record<LedgerPromptAnswer["action"], string> = { reply: "Answer sent", allow: "Allowed", deny: "Denied", release: "Left to the terminal", hold: "No automatic answer for this prompt" };
      this.showToast(t(titles[answer.action]), null);
      return true;
    } catch (e) {
      this.showToast(message(e), null, true);
      return false;
    } finally {
      this.busy--;
      await this.refresh(true);
    }
  }

  async importReports(text: string): Promise<ImportSummary> {
    const { results } = await this.backend.call("import", { text, ...(this.project ? { project: this.project } : {}) });
    await this.refresh(true);
    return summarizeImport(results);
  }

  async search(query: string): Promise<LedgerSearchHit[]> {
    if (!query.trim()) return [];
    const { hits } = await this.backend.call("search", { query, limit: 40, ...(this.project ? { project: this.project } : {}) });
    return hits;
  }

  info() {
    return this.backend.call("info", {});
  }

  // MARK: Toast

  showToast(text: string, undo: LedgerHumanRequest[] | null, error = false) {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toast = { id: ++this.toastId, message: text, undo, error };
    this.toastTimer = setTimeout(() => this.hideToast(), TOAST_MS);
    this.emit();
  }

  hideToast() {
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toastTimer = null;
    if (!this.toast) return;
    this.toast = null;
    this.emit();
  }

  /** Stops polling and timers (tests and the self-test) */
  dispose() {
    this.users = 1;
    this.stop();
    this.hideToast();
  }
}

let shared: LedgerStore | null = null;

/**
 * The app's Ledger. It runs on the demo backend until the core is connected through `ledger_call`;
 * GITROCHI_LEDGER_PREVIEW=large loads the large demo. The first repository to open the page is bound to the demo's
 * first project.
 */
export function ledgerStore(repoPath: string | null): LedgerStore {
  shared ??= new LedgerStore(new DemoLedgerBackend({ ...(repoPath ? { repoPath } : {}), large: env.ledgerPreview === "large", lively: true }));
  return shared;
}
