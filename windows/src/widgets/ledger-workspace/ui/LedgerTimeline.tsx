import { Activity, Archive, ArchiveRestore, Ban, Bot, CheckCheck, CircleCheck, CirclePlay, Clock, FileText, Gavel, GitMerge, type LucideIcon, Library, MessageCircleQuestion, MessageSquareReply, RefreshCw, SquareCheck, StickyNote, Tag, UserRound } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { LedgerEvent } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { Button, Markdown } from "@/shared/ui";
import { When } from "./parts";

const icons: Record<string, LucideIcon> = {
  start: CirclePlay, progress: Activity, artifact: FileText, question: MessageCircleQuestion, decision: Gavel, sync: RefreshCw, applied: CheckCheck, release: Tag,
  done: SquareCheck, merged: GitMerge, closed: SquareCheck, dropped: Ban, shelved: Library, note: StickyNote, auto_reply: Bot,
  ack: CircleCheck, unack: CircleCheck, archive: Archive, unarchive: ArchiveRestore, snooze: Clock, message: MessageSquareReply,
};

/** A person's operations in words; the agent's own summary is shown as it wrote it */
const humanLabels: Record<string, string> = {
  ack: "Confirmed", unack: "Took back the confirmation", archive: "Cleaned up", unarchive: "Restored", snooze: "Marked still active", shelve: "Shelved",
  answer: "Answered a question", dismiss: "Dismissed a question", message: "Sent a message", link: "Linked", prompt_answer: "Answered a waiting prompt",
};
const statusLabels: Record<string, string> = { active: "Made active again", done: "Marked done", merged: "Marked merged into {0}", closed: "Marked closed", dropped: "Marked dropped", shelved: "Shelved" };

function describe(e: LedgerEvent): string {
  if (e.actor !== "human") return e.summary ?? e.type;
  if (e.type === "set_status") return t(statusLabels[String(e.data?.status)] ?? "Changed the status", String(e.data?.version ?? ""));
  return t(humanLabels[e.type] ?? "Changed");
}

/** A report body in Markdown; a long one starts folded with "Show more" (macOS: LedgerReportBody) */
export function ReportBody({ text, open = false }: { text: string; open?: boolean }) {
  const long = text.length > 600 || text.split("\n").length > 12;
  const [unfolded, setUnfolded] = useState(open);
  const folded = long && !unfolded;
  return (
    <>
      <div className={`ledger-body${folded ? " folded" : ""}`}><Markdown text={text} /></div>
      {long && <Button size="small" style={{ alignSelf: "flex-start" }} aria-expanded={!folded} onClick={() => setUnfolded(!unfolded)}>{folded ? t("Show more") : t("Show less")}</Button>}
    </>
  );
}

/**
 * Reports newest first. Bodies are Markdown and long ones start folded; a person's operations are quieter, automatic
 * replies are marked. (macOS: Views/Ledger/LedgerInspector.swift, timeline)
 */
export function LedgerTimeline({ events, focus }: { events: LedgerEvent[]; focus: number | null }) {
  const list = [...events].sort((a, b) => b.ts - a.ts || b.id - a.id);
  const focused = useRef<HTMLDivElement>(null);
  useEffect(() => {
    focused.current?.scrollIntoView({ block: "center" });
  }, [focus]);
  if (!list.length) return <span className="hint">{t("No reports yet.")}</span>;
  return (
    <div className="ledger-timeline">
      {list.map((e) => {
        const Icon = icons[e.type] ?? (e.actor === "human" ? UserRound : Activity);
        return (
          <div key={e.id} ref={e.id === focus ? focused : undefined} className={`ledger-event ${e.actor}${e.id === focus ? " focus" : ""}`} data-event={e.id}>
            <span className="ledger-event-icon" aria-hidden><Icon size={14} /></span>
            <div className="ledger-event-text">
              <div className="ledger-event-line">
                <span className="grow selectable">
                  {e.actor === "auto" && <span className="chip-warn" style={{ marginRight: 6 }}>{t("Automatic")}</span>}
                  {e.actor === "agent" && <span className="mono faint" style={{ marginRight: 6 }}>{e.type}</span>}
                  {describe(e)}
                  {e.version && e.actor !== "human" && <span className="ledger-version" style={{ marginLeft: 6 }}>{e.version}</span>}
                </span>
                <When at={e.ts} />
              </div>
              {e.artifacts && e.artifacts.length > 0 && (
                <div className="ledger-artifacts">
                  {e.artifacts.map((a, i) => <span key={i} className="ledger-link mono"><FileText size={11} /><span>{a.name}{a.ssot ? ` · ${a.ssot}` : ""}</span></span>)}
                </div>
              )}
              {e.body && <ReportBody text={e.body} open={e.id === focus} />}
            </div>
          </div>
        );
      })}
    </div>
  );
}
