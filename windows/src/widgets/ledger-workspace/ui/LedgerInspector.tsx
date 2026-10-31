import { Bot, ChevronDown, Copy, FolderTree, GitBranch, GitMerge, GitPullRequest, MessageSquare, X } from "lucide-react";
import { useState } from "react";
import { agents, agentStatusTitle } from "@/entities/agent";
import { compareVersions, type LedgerQuestion, type LedgerSession, type LedgerStore } from "@/entities/ledger";
import { LedgerAnswerField } from "@/features/answer-ledger-question";
import { ipc } from "@/shared/api";
import { displayPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Modal, showMenuBelow, Spinner } from "@/shared/ui";
import { LedgerTimeline } from "./LedgerTimeline";
import { mergeMenu, moreMenu } from "./session-actions";
import { BaseLine, SessionId, Section, VerdictBadge, When } from "./parts";

const HOUR = 3_600_000;

/**
 * One session: what it is and where it stands, its links, the operations a person may take, its questions, its
 * timeline and what it touches. Dropping asks once; the rest is undone from the toast. (macOS: Views/Ledger/LedgerInspector.swift)
 */
export function LedgerInspector({ store, onClose }: { store: LedgerStore; onClose?: () => void }) {
  useObserve(store);
  useObserve(agents);
  const [dropping, setDropping] = useState(false);
  const live = store.session(store.selectedId);
  const detail = store.detail?.session.id === store.selectedId ? store.detail : null;
  const s = live ?? detail?.session;
  if (!s) {
    return (
      <div className="ledger-inspector ledger-placeholder" aria-busy={!store.detailError}>
        {store.detailError ? <span className="error-text" style={{ padding: 16 }}>{store.detailError}</span> : <Spinner />}
      </div>
    );
  }
  const busy = store.busy > 0;
  const newer = (store.state?.baselines ?? []).filter((b) => b.project === s.project && s.baseCurrent && compareVersions(b.version, s.baseCurrent) > 0).length;
  const agent = s.links.agentId ? agents.sessions.find((a) => a.id === s.links.agentId) : undefined;
  const questions = detail?.questions ?? [];
  const open = questions.filter((q) => q.state === "open");
  const answered = questions.filter((q) => q.state !== "open");
  const human = (action: Parameters<LedgerStore["human"]>[0]["action"], extra: Omit<Parameters<LedgerStore["human"]>[0], "action" | "sessionId"> = {}) => () => void store.human({ action, sessionId: s.id, ...extra });
  // an implementation session applied the version this one released: the core records `applied` with `by` here
  const confirmedBy = detail?.events.slice().reverse().find((e) => (e.type === "applied" || e.type === "merged") && typeof e.data?.by === "string" && (e.type === "applied" || e.data?.via === "applied"));
  return (
    <div className="ledger-inspector" aria-label={t("Session {0}", s.id)}>
      <div className="ledger-inspector-head">
        <div className="row">
          <SessionId session={s} />
          <IconButton small icon={<Copy size={13} />} tip={t("Copy the session ID")} aria-label={t("Copy the session ID")} onClick={() => void navigator.clipboard.writeText(s.id).then(() => store.showToast(t("Copied"), null), () => {})} />
          <span className="spacer" />
          <VerdictBadge verdict={s.verdict} />
          {onClose && <IconButton small icon={<X size={15} />} tip={t("Close")} aria-label={t("Close")} onClick={onClose} />}
        </div>
        <h2 className="selectable">{s.title}</h2>
        <div className="ledger-meta">
          <span>{s.kind}{s.role !== s.kind ? ` · ${s.role}` : ""}</span>
          <BaseLine session={s} behind={newer} />
          {s.mergedInto && <span className="mono">{t("merged into {0}", s.mergedInto)}</span>}
          <span>{t("Last report")} <When at={s.lastAt} /></span>
        </div>
        {confirmedBy && <span className="hint">{t("Confirmed by {0} (applied)", String(confirmedBy.data?.by ?? ""))}</span>}
        <div className="ledger-links">
          {s.links.branch && <span className="ledger-link mono" data-tip={t("Branch")}><GitBranch size={12} /><span>{s.links.branch}</span></span>}
          {s.links.worktree && <span className="ledger-link" data-tip={`${t("Worktree")}|${displayPath(s.links.worktree)}`}><FolderTree size={12} /><span>{t("Worktree")}</span></span>}
          {s.links.pr && <button type="button" className="ledger-link" data-tip={s.links.pr.url} onClick={() => void ipc.openUrl(s.links.pr!.url)}><GitPullRequest size={12} /><span>#{s.links.pr.number}</span></button>}
          {s.links.agentId && (agent && agents.canFocus(agent)
            ? <button type="button" className="ledger-link" data-tip={t("Open the agent's terminal")} onClick={() => agents.focus(agent)}><Bot size={12} /><span>{agentStatusTitle[agent.status]}</span></button>
            : <span className="ledger-link" data-tip={t("The agent is not running in Gitrochi.")}><Bot size={12} /><span>{t("Agent")}</span></span>)}
          {s.chatUrl && <button type="button" className="ledger-link" data-tip={s.chatUrl} onClick={() => void ipc.openUrl(s.chatUrl!)}><MessageSquare size={12} /><span>{t("Open chat")}</span></button>}
        </div>
      </div>
      <div className="ledger-actions" role="toolbar" aria-label={t("Session actions")}>
        <PrimaryActions store={store} s={s} busy={busy} human={human} />
        <Button size="small" disabled={busy} onClick={(e) => showMenuBelow(e.currentTarget, moreMenu(store, s, () => setDropping(true)))}>
          {t("More")}
          <ChevronDown size={13} />
        </Button>
      </div>
      <div className="ledger-inspector-body">
        {(open.length > 0 || answered.length > 0) && (
          <Section title={t("Questions")} count={open.length || undefined}>
            {open.map((q) => <OpenQuestion key={q.id} store={store} q={q} busy={busy} />)}
            {answered.map((q) => (
              <div key={q.id} className="ledger-question">
                <span className="ledger-row-text quiet selectable">{q.text}</span>
                <span className="ledger-row-text selectable">{q.state === "dismissed" ? t("Dismissed") : q.answeredBy === "auto" ? t("Answered automatically: {0}", q.answer ?? "") : t("Answered: {0}", q.answer ?? "")}</span>
              </div>
            ))}
          </Section>
        )}
        <Section title={t("Timeline")} count={detail?.events.length}>
          {detail ? <LedgerTimeline key={s.id} events={detail.events} focus={store.focusEventId} /> : <Spinner />}
        </Section>
        <Section title={t("Touches")} count={s.touches.length}>
          {!s.touches.length && <span className="hint">{t("The session has not said what it works on.")}</span>}
          {s.touches.map((path) => {
            const overlaps = (detail?.overlaps ?? []).filter((o) => o.paths.includes(path));
            return (
              <div key={path} className="ledger-touch">
                <span className="mono grow" data-tip={path}>{path}</span>
                {overlaps.map((o) => {
                  const other = store.session(o.a === s.id ? o.b : o.a);
                  return other && (
                    <button key={`${o.a}-${o.b}`} type="button" className="ledger-link" data-tip={o.kind === "same" ? t("Both sessions work on this.") : t("Files that usually change together")} onClick={() => store.select(other.id)}>
                      <span className={o.kind === "same" ? "chip-warn" : "hint"}>{o.kind === "same" ? t("Overlap") : t("Likely overlap")}</span>
                      <SessionId session={other} />
                    </button>
                  );
                })}
              </div>
            );
          })}
          {(detail?.overlaps ?? []).filter((o) => o.kind === "coupled" && !o.paths.some((p) => s.touches.includes(p))).map((o) => {
            const other = store.session(o.a === s.id ? o.b : o.a);
            return other && (
              <div key={`${o.a}-${o.b}`} className="ledger-touch">
                <span className="hint grow">{t("Likely overlap with {0}: {1}", other.id, o.paths.join(", "))}</span>
                <button type="button" className="link" onClick={() => store.select(other.id)}>{t("Open")}</button>
              </div>
            );
          })}
        </Section>
      </div>
      {dropping && (
        <Modal title={t("Drop {0}?", s.id)} width={420} onClose={() => setDropping(false)} footer={<><Button onClick={() => setDropping(false)}>{t("Cancel")}</Button><Button kind="danger" onClick={() => { setDropping(false); void store.human({ action: "set_status", sessionId: s.id, status: "dropped" }); }}>{t("Drop session")}</Button></>}>
          <span className="modal-message">{t("Its result is discarded and the session counts as finished. The agent reads this with its next report.")}</span>
        </Modal>
      )}
    </div>
  );
}

/** The one or two operations that fit the verdict; the rest are under More */
function PrimaryActions({ store, s, busy, human }: { store: LedgerStore; s: LedgerSession; busy: boolean; human: (action: Parameters<LedgerStore["human"]>[0]["action"], extra?: Omit<Parameters<LedgerStore["human"]>[0], "action" | "sessionId">) => () => void }) {
  switch (s.verdict) {
    case "confirm":
      return <><Button size="small" kind="primary" disabled={busy} onClick={human("ack")}>{t("Confirm")}</Button><Button size="small" disabled={busy} onClick={human("set_status", { status: "active" })}>{t("Make active again")}</Button></>;
    case "expirable":
      return <><Button size="small" kind="primary" disabled={busy} onClick={human("archive")}>{t("Clean up")}</Button><Button size="small" disabled={busy} onClick={human("unack")}>{t("Take back confirmation")}</Button></>;
    case "archived":
      return <Button size="small" kind="primary" disabled={busy} onClick={human("unarchive")}>{t("Restore")}</Button>;
    case "pending_merge":
      return <><Button size="small" kind="primary" disabled={busy} onClick={(e) => mergeMenu(e.currentTarget, store, s)}><GitMerge size={13} />{t("Mark merged…")}</Button><Button size="small" disabled={busy} onClick={human("set_status", { status: "closed" })}>{t("Mark closed")}</Button></>;
    case "stale":
      return <><Button size="small" kind="primary" disabled={busy} onClick={human("snooze", { until: Date.now() + 72 * HOUR })}>{t("Still active")}</Button><Button size="small" disabled={busy} onClick={human("set_status", { status: "closed" })}>{t("Mark closed")}</Button></>;
    case "shelved":
      return <Button size="small" disabled={busy} onClick={human("set_status", { status: "active" })}>{t("Make active again")}</Button>;
    default:
      return <Button size="small" disabled={busy} onClick={human("set_status", { status: "done" })} tip={`${t("Mark done")}|${t("The work is finished; whether it is merged is decided next.")}`}>{t("Mark done")}</Button>;
  }
}

function OpenQuestion({ store, q, busy }: { store: LedgerStore; q: LedgerQuestion; busy: boolean }) {
  return (
    <div className="ledger-question">
      <span className="ledger-row-text selectable" style={{ fontWeight: 600 }}>{q.text}</span>
      <LedgerAnswerField label={t("Answer to {0}", q.text)} placeholder={t("Answer… the session reads it with its next report")} onSubmit={(text) => store.answer(q, text)} />
      <div className="ledger-row-actions"><Button size="small" disabled={busy} onClick={() => void store.dismiss(q)}>{t("Dismiss")}</Button></div>
    </div>
  );
}
