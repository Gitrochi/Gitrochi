import { Archive, CircleCheck, Clock, GitMerge, MessageSquareReply, Sparkles, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { describeAnswer, type InboxItem, inboxGroups, inboxItems, inboxKeyAction, type LedgerPendingPrompt, type LedgerSession, type LedgerStore, matchesText, promptSummary, STALE_HOURS, stepIndex } from "@/entities/ledger";
import { LedgerAnswerField } from "@/features/answer-ledger-question";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty } from "@/shared/ui";
import { LedgerPromptStrip } from "./LedgerPromptStrip";
import { mergeMenu } from "./session-actions";
import { answerText, BaseLine, onScreen, SessionId, typing, VerdictBadge, When } from "./parts";

const PAGE = 50;
const HOUR = 3_600_000;

/**
 * The first screen: only what needs a person. Waiting prompts on top, then questions answered in place, automatic
 * replies to review, sessions to clean up and sessions to decide. Works from the keyboard alone (↑ ↓ Enter A C E S),
 * and confirming or archiving shows a toast with Undo. (macOS: Views/Ledger/LedgerInbox.swift)
 */
export function LedgerInbox({ store, onOpen, onOpenTerminal }: { store: LedgerStore; onOpen: (sessionId: string) => void; onOpenTerminal: (prompt: LedgerPendingPrompt) => void }) {
  useObserve(store);
  const state = store.state!;
  const project = store.project, text = store.filterText;
  const groups = useMemo(
    () => inboxGroups(state, project).map((g) => ({ ...g, items: g.items.filter((i) => !i.session || matchesText(i.session, text)) })).filter((g) => g.items.length),
    [state, project, text],
  );
  const items = useMemo(() => inboxItems(groups), [groups]);
  const [activeKey, setActiveKey] = useState<string | null>(null);
  const [correcting, setCorrecting] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const fields = useRef(new Map<string, HTMLTextAreaElement>());
  const rows = useRef(new Map<string, HTMLDivElement>());
  const self = useRef<HTMLDivElement>(null);
  const active = items.findIndex((i) => i.key === activeKey);

  const run = (item: InboxItem, action: ReturnType<typeof inboxKeyAction>) => {
    if (!action) return;
    if (action === "open" && item.session) onOpen(item.session.id);
    else if (action === "answer") {
      if (item.kind === "question") fields.current.get(item.key)?.focus();
      else setCorrecting(item.key);
    } else if (action === "confirm") {
      if (item.kind === "autoPrompt") void store.reviewAuto(item.prompt);
      else void store.human({ action: "ack", sessionId: item.session.id });
    } else if (action === "archive") void store.human({ action: "archive", sessionId: item.session!.id });
    else if (action === "snooze") void store.human({ action: "snooze", sessionId: item.session!.id, until: Date.now() + STALE_HOURS * HOUR });
    else if (action === "merge") {
      // the version picker opens under the row's own Mark merged… button
      const anchor = rows.current.get(item.key)?.querySelector<HTMLElement>("[data-merge]");
      if (anchor && item.session) mergeMenu(anchor, store, item.session);
    }
  };
  // A saved answer takes its row out of the Inbox; focus comes back to the Inbox so its keys keep working, unless
  // the person has moved it elsewhere meanwhile
  const answered = (key: string) => {
    const focused = document.activeElement;
    if (!focused || focused === document.body || rows.current.get(key)?.contains(focused)) self.current?.focus({ preventScroll: true });
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || typing(e) || !onScreen(self.current)) return;
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        const next = items[stepIndex(active, e.key === "ArrowDown" ? 1 : -1, items.length)];
        if (!next) return;
        e.preventDefault();
        setActiveKey(next.key);
        rows.current.get(next.key)?.scrollIntoView({ block: "nearest" });
        return;
      }
      const item = items[active];
      // a focused button takes its own Enter
      if (!item || (e.key === "Enter" && (e.target as HTMLElement).closest?.("button"))) return;
      const action = inboxKeyAction(item, e.key);
      if (!action) return;
      e.preventDefault();
      run(item, action);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const busy = store.busy > 0;
  return (
    <div className="ledger-inbox" role="region" aria-label={t("Inbox")} ref={self} tabIndex={-1}>
      <LedgerPromptStrip store={store} onOpen={onOpen} onOpenTerminal={onOpenTerminal} />
      {!groups.length ? (
        <div className="ledger-all-clear">
          <Empty icon={<CircleCheck size={30} strokeWidth={1.5} />} title={t("Nothing needs you")} detail={t("Questions, finished sessions to confirm and sessions to decide show up here.")} />
        </div>
      ) : (
        groups.map((g) => {
          const shown = expanded.has(g.id) ? g.items : g.items.slice(0, PAGE);
          return (
            <section key={g.id} className="ledger-section" aria-label={t(g.title)} data-group={g.id}>
              <header className="ledger-section-head">
                <span className="ellipsis">{t(g.title)}</span>
                <span className="counter">{g.items.length}</span>
              </header>
              <div role="list">
                {shown.map((item, i) => (
                  <div
                    key={item.key}
                    role="listitem"
                    ref={(el) => { if (el) rows.current.set(item.key, el); else rows.current.delete(item.key); }}
                    className={`ledger-row${item.key === activeKey ? " active" : ""}${item.session && item.session.id === store.selectedId ? " selected" : ""}`}
                    data-item={item.key}
                    onMouseDown={() => setActiveKey(item.key)}
                    onClick={(e) => { if (!(e.target as HTMLElement).closest("button, textarea, a, input") && item.session) onOpen(item.session.id); }}
                  >
                    {!(item.kind === "question" && i > 0 && shown[i - 1].kind === "question" && shown[i - 1].session?.id === item.session.id) && <RowHead session={item.session} />}
                    <RowBody item={item} store={store} busy={busy} correcting={correcting === item.key} setCorrecting={(on) => setCorrecting(on ? item.key : null)} fieldRef={(el) => { if (el) fields.current.set(item.key, el); else fields.current.delete(item.key); }} onAnswered={() => answered(item.key)} />
                  </div>
                ))}
              </div>
              {g.items.length > shown.length && (
                <Button size="small" className="ledger-more" onClick={() => setExpanded(new Set(expanded).add(g.id))}>{t("Show all {0}", g.items.length)}</Button>
              )}
            </section>
          );
        })
      )}
      <footer className="ledger-keys" aria-label={t("Keyboard")}>
        {[["↑ ↓", "Move"], ["Enter", "Open"], ["A", "Answer"], ["C", "Confirm"], ["E", "Clean up"], ["S", "Still active"], ["M", "Mark merged…"]].map(([key, label]) => (
          <span key={key}><span className="ledger-kbd">{key}</span>{t(label)}</span>
        ))}
      </footer>
    </div>
  );
}

function RowHead({ session }: { session: LedgerSession | null }) {
  if (!session) return <div className="ledger-row-head"><span className="ledger-row-title muted">{t("An agent outside the Ledger")}</span></div>;
  return (
    <div className="ledger-row-head">
      <SessionId session={session} />
      <span className="ledger-row-title grow">{session.title}</span>
      <VerdictBadge verdict={session.verdict} />
      <When at={session.lastAt} />
    </div>
  );
}

function RowBody({ item, store, busy, correcting, setCorrecting, fieldRef, onAnswered }: { item: InboxItem; store: LedgerStore; busy: boolean; correcting: boolean; setCorrecting: (on: boolean) => void; fieldRef: (el: HTMLTextAreaElement | null) => void; onAnswered: () => void }) {
  const saved = (ok: boolean) => {
    if (ok) onAnswered();
    return ok;
  };
  if (item.kind === "question") {
    const q = item.question;
    return (
      <>
        <div className="ledger-row-text selectable">{q.text}</div>
        <LedgerAnswerField fieldRef={fieldRef} label={t("Answer to {0}", q.text)} placeholder={t("Answer… the session reads it with its next report")} onSubmit={(text) => store.answer(q, text).then(saved)} />
        <div className="ledger-row-actions">
          <Button size="small" disabled={busy} onClick={() => void store.dismiss(q)} tip={`${t("Dismiss")}|${t("Closes the question without an answer; the session is told.")}`}><X size={13} />{t("Dismiss")}</Button>
        </div>
      </>
    );
  }
  if (item.kind === "autoPrompt") {
    const prompt = item.prompt;
    return (
      <>
        <div className="ledger-row-text quiet selectable">{promptSummary(prompt)}</div>
        <div className="ledger-row-text selectable"><Sparkles size={12} className="muted" /> {t("Answered automatically: {0}", answerText(describeAnswer(prompt.answer)))}</div>
        {prompt.answer?.outcome === "unconfirmed" && <div className="hint">{t("Not seen to apply yet: you may have answered in the terminal first.")}</div>}
        {prompt.answer?.outcome === "unknown" && <div className="hint">{t("Gitrochi could not tell whether this answer applied.")}</div>}
        {correcting ? (
          <LedgerAnswerField autoFocus label={t("Correction")} placeholder={t("What should the session do instead?")} submitLabel="Send correction" onSubmit={(text) => store.reviewAuto(prompt, text).then(saved)} onCancel={() => setCorrecting(false)} />
        ) : (
          <div className="ledger-row-actions">
            <Button size="small" kind="primary" disabled={busy} onClick={() => void store.reviewAuto(prompt)} tip={`${t("Confirm")}|${t("The automatic answer was fine; it leaves the Inbox.")}|C`}><CircleCheck size={13} />{t("Confirm")}</Button>
            {prompt.sessionId && <Button size="small" disabled={busy} onClick={() => setCorrecting(true)} tip={`${t("Send correction")}|${t("The session reads it with its next report.")}|A`}><MessageSquareReply size={13} />{t("Send correction")}</Button>}
          </div>
        )}
      </>
    );
  }
  const s = item.session;
  return (
    <>
      <div className="ledger-meta">
        <span>{s.kind}</span>
        <BaseLine session={s} />
        {s.mergedInto && <span className="mono">{t("merged into {0}", s.mergedInto)}</span>}
      </div>
      <div className="ledger-row-actions">
        {s.verdict === "confirm" && <Button size="small" kind="primary" disabled={busy} onClick={() => void store.human({ action: "ack", sessionId: s.id })} tip={`${t("Confirm")}|${t("The outcome is right; the conversation can be cleaned up next.")}|C`}><CircleCheck size={13} />{t("Confirm")}</Button>}
        {s.verdict === "expirable" && <Button size="small" kind="primary" disabled={busy} onClick={() => void store.human({ action: "archive", sessionId: s.id })} tip={`${t("Clean up")}|${t("The conversation is finished and may be closed.")}|E`}><Archive size={13} />{t("Clean up")}</Button>}
        {s.verdict === "pending_merge" && <Button size="small" kind="primary" data-merge disabled={busy} onClick={(e) => mergeMenu(e.currentTarget, store, s)} tip={`${t("Mark merged…")}||M`}><GitMerge size={13} />{t("Mark merged…")}</Button>}
        {s.verdict === "stale" && <Button size="small" kind="primary" disabled={busy} onClick={() => void store.human({ action: "snooze", sessionId: s.id, until: Date.now() + STALE_HOURS * HOUR })} tip={`${t("Still active")}|${t("Keeps it off the stale list for another 72 hours.")}|S`}><Clock size={13} />{t("Still active")}</Button>}
        {(s.verdict === "pending_merge" || s.verdict === "stale") && <Button size="small" disabled={busy} onClick={() => void store.human({ action: "set_status", sessionId: s.id, status: "closed" })} tip={`${t("Mark closed")}|${t("Finished without a merge.")}`}>{t("Mark closed")}</Button>}
      </div>
    </>
  );
}
