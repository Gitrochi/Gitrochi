import { env } from "@/shared/config";
import { t } from "@/shared/i18n";
import { nativeLedgerBackend } from "../api/backend";
import { DemoLedgerBackend } from "../api/demo-backend";
import { type AnswerKind, describeAnswer, serverNow } from "../lib/countdown";
import { summarizeImport, type ImportSummary } from "../lib/imports";
import { inverseOperation, operationTitle } from "../lib/undo";
import { LedgerReader, message } from "./reader";
import type { LedgerHumanRequest, LedgerPendingPrompt, LedgerPromptAnswer, LedgerQuestion, LedgerSearchHit } from "./types";

/**
 * The Ledger page's state, one per app: the contract `State` read when `rev` moves, the selected session's detail, the
 * graph and filters (LedgerReader), and a person's operations with undo. (macOS: Store/LedgerStore.swift)
 */
export class LedgerStore extends LedgerReader {
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
    const now = this.state ? serverNow(this.state.now, this.stateReadAt, Date.now()) : Date.now();
    for (const r of requests) {
      const before = this.session(r.sessionId);
      const inverse = before ? inverseOperation(before, r) : null;
      if (inverse && inverse.every((x) => this.backend.canRun?.(x, now) ?? true)) undo.push(...inverse);
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
    return this.human({ action: "answer", sessionId: question.sessionId, questionId: question.id, answer: text.trim() });
  }

  dismiss(question: LedgerQuestion) {
    return this.human({ action: "dismiss", sessionId: question.sessionId, questionId: question.id });
  }

  /** Accepts an automatic answer (it leaves the Inbox), or first sends the session a correction for it */
  async reviewAuto(prompt: LedgerPendingPrompt, correction?: string): Promise<boolean> {
    this.busy++;
    this.emit();
    try {
      if (correction !== undefined && prompt.sessionId) await this.backend.call("human", { action: "message", sessionId: prompt.sessionId, text: correction.trim() });
      await this.backend.call("prompt_review", { id: prompt.id });
      this.showToast(correction === undefined ? t("Automatic answer confirmed") : t("Correction sent to {0}", prompt.sessionId ?? ""), null);
      return true;
    } catch (e) {
      this.showToast(message(e), null, true);
      return false;
    } finally {
      this.busy--;
      await this.refresh(true);
    }
  }

  /** Answers a waiting prompt; when auto-continue was faster the answer is not taken, and the toast says so */
  async answerPrompt(prompt: LedgerPendingPrompt, answer: LedgerPromptAnswer): Promise<boolean> {
    this.busy++;
    this.emit();
    try {
      const { ok } = await this.backend.call("prompt_answer", { id: prompt.id, answer });
      const titles: Record<AnswerKind, string> = { text: "Answer sent to the agent", allow: "Allowed", deny: "Denied", approve: "Allowed", release: "Left to the terminal", hold: "Auto-continue is off for this prompt", unknown: "Answer sent to the agent" };
      this.showToast(ok ? t(titles[describeAnswer(answer).kind]) : t("The prompt was already answered."), null);
      return ok;
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

}

let shared: LedgerStore | null = null;

/**
 * The app's Ledger: the ledger database through `ledger_call`, or with GITROCHI_LEDGER_DEMO the demo ("large" for
 * 1,000 sessions, "empty" for the onboarding), whose first project is bound to the first repository to open the page.
 */
export function ledgerStore(repoPath: string | null): LedgerStore {
  const demo = env.ledgerDemo;
  shared ??= new LedgerStore(demo ? new DemoLedgerBackend({ ...(repoPath ? { repoPath } : {}), large: demo === "large", empty: demo === "empty", lively: true }) : nativeLedgerBackend);
  return shared;
}
