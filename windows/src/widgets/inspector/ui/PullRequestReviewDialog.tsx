import { useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Modal, Segmented, Spinner } from "@/shared/ui";

type Verdict = "comment" | "approve" | "changes";

/**
 * Review…: the review type, the comment (the same draft as the composer) and one Submit review. It holds what the
 * composer's Approve and Request changes buttons did. macOS: PullRequestReviewSheet.swift.
 */
export function PullRequestReviewDialog({ store, number, draft, onDraft, onSent, onClose }: { store: RepoStore; number: number; draft: string; onDraft: (value: string) => void; /** the review went out with this text */ onSent: (text: string) => void; onClose: () => void }) {
  useObserve(store);
  const [verdict, setVerdict] = useState<Verdict>("comment");
  const gitlab = store.target?.provider === "gitlab";
  const state = store.review?.number === number ? store.review.state : null;
  const text = draft.trim(), pending = store.reviewDraftsFor(number).length;
  // GitLab has no "request changes", and an approval there is revoked instead of repeated
  const revoke = gitlab && !!state?.approvedByMe;
  const options: { value: Verdict; label: string }[] = [
    { value: "comment", label: t("Comment") },
    ...(revoke ? [] : [{ value: "approve" as const, label: t("Approve") }]),
    ...(gitlab ? [] : [{ value: "changes" as const, label: t("Request changes") }]),
  ];
  const reason = verdict === "comment" && !text && !pending ? t("A comment needs text")
    : verdict === "changes" && !text && !pending ? t("Request changes with a comment (comment required)")
    : verdict === "approve" && state?.approvedByMe ? t("Approved") : "";
  const submit = () => {
    if (reason || store.reviewBusy) return;
    const work = verdict === "approve" ? store.approvePullRequest(number, text) : verdict === "changes" ? store.requestChanges(number, text) : store.postReviewComment(number, text);
    void work.then((ok) => { if (ok) { onSent(text); onClose(); } });
  };
  return <Modal title={t("Review")} width={520} onClose={onClose} footer={<>
    {store.reviewBusy && <Spinner size={12}/>}
    {revoke && <Button disabled={store.reviewBusy} onClick={() => void store.unapprovePullRequest(number).then(onClose)}>{t("Revoke approval")}</Button>}
    <span className="spacer"/>
    <span className="pr-cap">{reason}</span>
    <Button onClick={onClose}>{t("Cancel")}</Button>
    <Button kind="primary" className="pr-neutral-disabled" disabled={!!reason || store.reviewBusy} tip={keyLabel(t("Comment (Ctrl+Enter)"))} onClick={submit}>{t("Submit review")}</Button>
  </>}>
    <div className="pr-review-dialog">
      <div role="group" aria-label={t("Review type")}><Segmented value={verdict} options={options} onChange={setVerdict}/></div>
      <textarea className="textarea" rows={6} autoFocus aria-label={t("Comment")} placeholder={t("Write a comment…")} value={draft} disabled={store.reviewBusy} onChange={(event) => onDraft(event.target.value)}
        onKeyDown={(event) => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); submit(); } }}/>
      {pending > 0 && <span className="pr-cap">{t("Pending line comments ({0})", pending)}</span>}
    </div>
  </Modal>;
}
