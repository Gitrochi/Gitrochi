import { useEffect, useState } from "react";
import type { RepoStore } from "@/entities/repo";
import type { MergeMethod } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import { useObserve } from "@/shared/lib";

/** 서버 정책을 확인한 뒤 PR·MR 수명주기를 마무리한다. */
export function RequestLifecyclePanel({ store, number }: { store: RepoStore; number: number }) {
  useObserve(store);
  const [editing, setEditing] = useState(false), [title, setTitle] = useState(""), [body, setBody] = useState(""), [base, setBase] = useState(""), [reviewers, setReviewers] = useState("");
  const [method, setMethod] = useState<MergeMethod>("merge");
  useEffect(() => { setEditing(false); void store.loadRequestLifecycle(number); }, [store, number]);
  const r = store.requestLifecycle?.number === number ? store.requestLifecycle : null;
  useEffect(() => { if (r) setMethod(r.methods[0] ?? "merge"); }, [r?.headSHA, r?.methods.join(",")]);
  const disabled = store.lifecycleBusy || store.lifecycleLoading;
  return <div className="col" style={{ gap: 7, border: "1px solid var(--border)", borderRadius: 7, padding: 9 }}>
    <div className="row"><strong>{t("Request management")}</strong><span className="spacer" />{disabled && <Spinner size={12} />}<Button size="small" disabled={disabled} onClick={() => void store.loadRequestLifecycle(number)}>{t("Refresh")}</Button></div>
    {store.lifecycleError && <span className="error-text" style={{ whiteSpace: "pre-wrap" }}>{store.lifecycleError}</span>}
    {r && <>
      <span>{t("State: {0}", t(r.state))} · <code>{r.headSHA.slice(0, 12)}</code></span>
      <span className="muted">{r.checks}</span><span className="muted" style={{ fontSize: 11 }}>{r.policy}</span>
      {r.blockers.map((b) => <span className="muted" key={b}>• {b}</span>)}
      <div className="row" style={{ flexWrap: "wrap" }}>
        {r.state === "open" && <><select aria-label={t("Merge method")} value={method} disabled={disabled || !r.methods.length} onChange={(e) => setMethod(e.target.value as MergeMethod)}>{r.methods.map((m) => <option value={m} key={m}>{t(m === "merge" ? "Merge" : m === "squash" ? "Squash" : "Rebase")}</option>)}</select><Button size="small" kind="primary" disabled={disabled || !!r.blockers.length} onClick={() => store.confirmMergeRequest(method)}>{t("Merge…")}</Button></>}
        {r.canRebase && <Button size="small" disabled={disabled} onClick={() => store.confirmRequestRebase()}>{t("Rebase on server…")}</Button>}
        {r.state !== "merged" && r.canEdit && <Button size="small" disabled={disabled} onClick={() => store.confirmRequestState(r.state !== "open")}>{r.state === "open" ? t("Close request…") : t("Reopen…")}</Button>}
        {r.canEdit && <Button size="small" disabled={disabled} onClick={() => { setTitle(r.title); setBody(r.body); setBase(r.base); setReviewers(r.reviewers.join(", ")); setEditing(!editing); }}>{t("Edit request…")}</Button>}
      </div>
      {editing && <div className="col" style={{ gap: 6 }}>
        <label>{t("Title")}<input value={title} disabled={disabled} onChange={(e) => setTitle(e.target.value)} /></label>
        <label>{t("Description")}<textarea rows={5} value={body} disabled={disabled} onChange={(e) => setBody(e.target.value)} /></label>
        <label>{t("Target branch")}<input value={base} disabled={disabled} onChange={(e) => setBase(e.target.value)} /></label>
        <Button size="small" disabled={disabled || !title.trim() || !base.trim()} onClick={() => void store.saveRequestMetadata(number, title, body, base).then((ok) => { if (ok) setEditing(false); })}>{t("Save request")}</Button>
        <label>{t("Reviewers (comma-separated usernames)")}<input value={reviewers} disabled={disabled} onChange={(e) => setReviewers(e.target.value)} /></label>
        <Button size="small" disabled={disabled} onClick={() => void store.saveRequestReviewers(number, reviewers.split(","))}>{t("Save reviewers")}</Button>
      </div>}
    </>}
  </div>;
}
