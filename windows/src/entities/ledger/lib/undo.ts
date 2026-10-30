import type { LedgerHumanRequest, LedgerSession } from "../model/types";

/**
 * The calls that undo a person's operation on a session, from the session as it was before; null when the operation
 * has no undo (answers, dismissals and messages are delivered to the agent). The contract has no `undo` method yet, so
 * this sends the inverse operations. (macOS: LedgerUndo.inverse)
 */
export function inverseOperation(before: LedgerSession, done: LedgerHumanRequest): LedgerHumanRequest[] | null {
  const sessionId = before.id;
  switch (done.action) {
    case "ack":
      // confirming an automatic reply marks it reviewed; there is nothing to take back
      if (done.questionId !== undefined || done.promptId !== undefined) return null;
      return before.ackAt ? null : [{ action: "unack", sessionId }];
    case "unack":
      return before.ackAt ? [{ action: "ack", sessionId }] : null;
    case "archive":
      return before.archivedAt ? null : [{ action: "unarchive", sessionId }];
    case "unarchive":
      return before.archivedAt ? [{ action: "archive", sessionId }] : null;
    case "set_status":
    case "shelve": {
      const status: LedgerHumanRequest[] = [{ action: "set_status", sessionId, status: before.status, ...(before.mergedInto ? { version: before.mergedInto } : {}) }];
      // a status a person chooses counts as confirmed; going back must not keep a confirmation that was not there
      if (!before.ackAt && before.status !== "active") status.push({ action: "unack", sessionId });
      if (before.archivedAt) status.push({ action: "archive", sessionId });
      return status;
    }
    case "snooze":
      return [{ action: "snooze", sessionId, until: before.snoozeUntil ?? 0 }];
    default:
      return null;
  }
}

/** The toast's message for an operation, in English for t() */
export function operationTitle(request: LedgerHumanRequest): string {
  switch (request.action) {
    case "ack":
      return request.questionId !== undefined || request.promptId !== undefined ? "Automatic reply confirmed" : "Confirmed {0}";
    case "unack":
      return "Confirmation of {0} taken back";
    case "archive":
      return "Archived {0}";
    case "unarchive":
      return "Restored {0}";
    case "snooze":
      return request.until ? "{0} marked still active" : "{0} snooze cleared";
    case "shelve":
      return "Shelved {0}";
    case "set_status":
      return request.status === "merged" ? "{0} marked merged" : request.status === "closed" ? "Closed {0}" : request.status === "dropped" ? "Dropped {0}" : request.status === "active" ? "{0} is active again" : request.status === "shelved" ? "Shelved {0}" : "{0} marked done";
    case "answer":
      return "Answer saved for {0}";
    case "dismiss":
      return "Question dismissed";
    case "message":
      return "Correction sent to {0}";
    default:
      return "Updated {0}";
  }
}
