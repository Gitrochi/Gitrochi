import { MessageSquare, Trash2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { ReviewComment } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";

export function ReviewDraftPanel({ store, number }: { store: RepoStore; number: number }) {
  const drafts = store.reviewDraftsFor(number);
  const review = store.review?.number === number ? store.review : null;
  const editors = useRef(new Map<string, HTMLTextAreaElement>());
  const previousIDs = useRef(drafts.map((draft) => draft.id));
  const draftIDs = drafts.map((draft) => draft.id).join("\0");
  useEffect(() => {
    const current = draftIDs ? draftIDs.split("\0") : [];
    const added = current.find((id) => !previousIDs.current.includes(id));
    previousIDs.current = current;
    if (added) {
      const editor = editors.current.get(added);
      editor?.focus({ preventScroll: true });
      editor?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  }, [draftIDs]);
  return <div className="col" style={{ gap: 8 }}>
    {review?.warnings.map((warning) => <span key={warning} className="hint" role="status">{warning}</span>)}
    <span className="hint">{t("Use the comment button beside a diff line to add it to your review. Drafts stay on this device until submitted.")}</span>
    {drafts.length > 0 && <>
      <strong>{t("Pending line comments ({0})", drafts.length)}</strong>
      {store.target?.provider === "gitlab" && <span className="hint">{t("GitLab publishes threads one at a time; approval is a separate action.")}</span>}
      {drafts.map((draft) => {
        const stale = review && (draft.anchor.headSHA !== review.headSHA || draft.anchor.baseSHA !== review.baseSHA || draft.anchor.startSHA !== review.startSHA);
        return <div key={draft.id} className="review-comment col" style={{ gap: 6 }}>
          <div className="row" style={{ gap: 6 }}>
            <MessageSquare size={12} /><span className="mono ellipsis grow">{draft.anchor.path}:{draft.anchor.line} · {t(draft.anchor.side === "LEFT" ? "Old version" : "New version")}</span>
            <Button size="small" disabled={store.reviewBusy} onClick={() => store.removeReviewDraft(draft.id)} tip={t("Remove draft")}><Trash2 size={12} /></Button>
          </div>
          {stale && <span className="error-text">{t("This comment belongs to an older diff. Copy its text, remove it and select a line in the refreshed diff.")}</span>}
          <textarea ref={(element) => { if (element) editors.current.set(draft.id, element); else editors.current.delete(draft.id); }} className="textarea" rows={3} value={draft.body} disabled={store.reviewBusy} placeholder={t("Line comment")} aria-label={t("Line comment")} onChange={(e) => store.updateReviewDraft(draft.id, e.target.value)} />
        </div>;
      })}
    </>}
  </div>;
}

export function ReviewThreadActions({ store, number, comment }: { store: RepoStore; number: number; comment: ReviewComment }) {
  const [replying, setReplying] = useState(false);
  const [body, setBody] = useState("");
  if (!comment.threadID || comment.kind !== "comment") return null;
  return <div className="col" style={{ gap: 6 }}>
    <div className="row" style={{ gap: 6 }}>
      <Button size="small" disabled={store.reviewBusy} onClick={() => setReplying(!replying)}>{t("Reply")}</Button>
      {comment.resolvable && <Button size="small" disabled={store.reviewBusy} onClick={() => void store.resolveReviewThread(number, comment)}>{t(comment.resolved ? "Reopen thread" : "Resolve thread")}</Button>}
      {comment.resolved && <span className="hint">{t("Resolved")}</span>}
    </div>
    {replying && <>
      <textarea className="textarea" rows={3} aria-label={t("Reply")} value={body} disabled={store.reviewBusy} onChange={(e) => setBody(e.target.value)} />
      <Button size="small" disabled={store.reviewBusy || !body.trim()} onClick={() => void store.replyReviewComment(number, comment, body).then((ok) => { if (ok) { setBody(""); setReplying(false); } })}>{t("Send reply")}</Button>
    </>}
  </div>;
}
