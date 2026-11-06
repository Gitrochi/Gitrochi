import { CircleCheck, CircleDot, CircleX } from "@/shared/icons";
import { CircleAlert, Clock } from "@/shared/icons";
import { useEffect, useState } from "react";
import { CIStatusIcon } from "@/entities/ci";
import type { PullRequest } from "@/entities/git";
import { type MergeMethod, type PullRequestReview, workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, Spinner } from "@/shared/ui";
import { linkedIssues } from "../lib/pull-request-page";

const methodTitle = (method: MergeMethod) => t(method === "merge" ? "Create a merge commit" : method === "squash" ? "Squash and merge" : "Rebase and merge");

/**
 * The side cards of a request's conversation: Merge, Reviewers, Linked issue, and the request's own fields while they
 * are edited. The server's policy decides what Merge may do. macOS: RequestLifecyclePanel.swift.
 */
export function RequestLifecyclePanel({ store, number, pr, review, editing, onEditing }: { store: RepoStore; number: number; pr: PullRequest; review: PullRequestReview | null; editing: boolean; onEditing: (value: boolean) => void }) {
  useObserve(store);
  useObserve(store.ci);
  const [title, setTitle] = useState(""), [body, setBody] = useState(""), [base, setBase] = useState(""), [reviewers, setReviewers] = useState("");
  const [method, setMethod] = useState<MergeMethod>("merge"), [requesting, setRequesting] = useState(false);
  useEffect(() => { onEditing(false); setRequesting(false); void store.loadRequestLifecycle(number); }, [store, number]);
  const r = store.requestLifecycle?.number === number ? store.requestLifecycle : null;
  useEffect(() => { if (r) setMethod(r.methods[0] ?? "merge"); }, [r?.headSHA, r?.methods.join(",")]);
  // the fields start from the server's values each time the editor opens
  useEffect(() => { if (editing && r) { setTitle(r.title); setBody(r.body); setBase(r.base); } }, [editing]);
  const disabled = store.lifecycleBusy || store.lifecycleLoading;
  const state = review?.state;
  const run = pr.headSHA ? store.ci.bySha.get(pr.headSHA) : undefined;
  const approved = !!state && state.approvedBy.length > 0 && !state.changesRequestedBy.length && !(state.approvalsLeft && state.approvalsLeft > 0);
  const names = [...new Set([...(r?.reviewers ?? []), ...(state?.approvedBy ?? []), ...(state?.changesRequestedBy ?? [])])];
  const issues = linkedIssues(pr.body);
  const issueURL = (issue: number) => store.target ? `https://${store.target.host}/${store.target.path}/${store.target.provider === "gitlab" ? "-/issues" : "issues"}/${issue}` : "";
  return <>
    {store.lifecycleError && <p className="error-text selectable" role="alert" style={{ whiteSpace: "pre-wrap", margin: 0 }}>{store.lifecycleError}</p>}
    {editing && r && <section className="pr-card" aria-label={t("Edit request…")}>
      <label>{t("Title")}<input className="input" value={title} disabled={disabled} onChange={(e) => setTitle(e.target.value)} /></label>
      <label>{t("Description")}<textarea className="textarea" rows={5} value={body} disabled={disabled} onChange={(e) => setBody(e.target.value)} /></label>
      <label>{t("Target branch")}<input className="input" value={base} disabled={disabled} onChange={(e) => setBase(e.target.value)} /></label>
      <div className="pr-card-actions"><Button onClick={() => onEditing(false)}>{t("Cancel")}</Button><Button kind="primary" disabled={disabled || !title.trim() || !base.trim()} onClick={() => void store.saveRequestMetadata(number, title, body, base).then((ok) => { if (ok) onEditing(false); })}>{t("Save request")}</Button></div>
    </section>}
    <section className="pr-card" aria-label={t("Merge")}>
      <span className="pr-card-title">{t("Merge")}{disabled && <Spinner size={11} />}</span>
      {r ? <>
        <span className="pr-card-row">{run ? <CIStatusIcon status={run.status} size={14} /> : <CircleDot size={14} className="pr-neutral-icon" aria-hidden="true" />}<span>{r.checks}</span></span>
        {state && <span className="pr-card-row status-tone" data-tone={approved ? "passed" : "waiting"}>{approved ? <CircleCheck size={14} aria-hidden="true" /> : <CircleAlert size={14} aria-hidden="true" />}<span>{state.approvalsLeft && state.approvalsLeft > 0 ? t("{0} more approvals needed.", state.approvalsLeft) : t("Approvals")}</span></span>}
        {r.state === "open" ? <>
          <div className="pr-merge-row">
            <select className="select" aria-label={t("Merge method")} value={method} disabled={disabled || !r.methods.length} onChange={(e) => setMethod(e.target.value as MergeMethod)}>{r.methods.map((m) => <option value={m} key={m}>{methodTitle(m)}</option>)}</select>
            <Button kind={r.blockers.length ? "default" : "primary"} tip={r.policy} disabled={disabled || !!r.blockers.length} aria-describedby={r.blockers.length ? "request-merge-reason" : undefined} onClick={() => store.confirmMergeRequest(method)}>{t("Merge…")}</Button>
          </div>
          {r.blockers.length > 0 && <span id="request-merge-reason" className="pr-cap pr-merge-reason">{r.blockers.join("\n")}</span>}
        </> : <span className="pr-cap">{workStateTitle(r.state)}</span>}
      </> : !disabled && <span className="pr-cap">{t("No checks reported")}</span>}
    </section>
    {(names.length > 0 || r?.canEdit) && <section className="pr-card" aria-label={t("Reviewers")}>
      <span className="pr-card-title">{t("Reviewers")}</span>
      {names.map((name) => {
        const status = state?.changesRequestedBy.includes(name) ? "changes" : state?.approvedBy.includes(name) ? "approved" : "waiting";
        return <span className="pr-card-row" key={name}>
          <span aria-hidden="true"><Avatar name={name} email={name} size={20} /></span><span className="ellipsis grow">@{name}</span>
          <span className="pr-reviewer-status status-tone" data-tone={status === "approved" ? "passed" : status === "changes" ? "failed" : "waiting"}>
            {status === "approved" ? <CircleCheck size={12} aria-hidden="true" /> : status === "changes" ? <CircleX size={12} aria-hidden="true" /> : <Clock size={12} aria-hidden="true" />}
            {t(status === "approved" ? "Approved" : status === "changes" ? "Changes requested" : "Waiting")}
          </span>
        </span>;
      })}
      {r?.canEdit && <span><button type="button" className="pr-text-button" aria-expanded={requesting} disabled={disabled} onClick={() => { setReviewers(r.reviewers.join(", ")); setRequesting(!requesting); }}>{t("Request review…")}</button></span>}
      {requesting && r?.canEdit && <>
        <label>{t("Reviewers (comma-separated usernames)")}<input className="input" value={reviewers} disabled={disabled} onChange={(e) => setReviewers(e.target.value)} /></label>
        <div className="pr-card-actions"><Button disabled={disabled} onClick={() => void store.saveRequestReviewers(number, reviewers.split(",")).then(() => setRequesting(false))}>{t("Save reviewers")}</Button></div>
      </>}
    </section>}
    {issues.length > 0 && <section className="pr-card" aria-label={t("Linked issue")}>
      <span className="pr-card-title">{t("Linked issue")}</span>
      {issues.map((issue) => <button type="button" className="pr-card-row pr-issue-link" key={issue} onClick={() => store.openUrl(issueURL(issue))}><CircleDot size={14} aria-hidden="true" /><span className="mono">#{issue}</span></button>)}
    </section>}
  </>;
}
