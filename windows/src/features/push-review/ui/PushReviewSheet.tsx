import { useEffect } from "react";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Modal, Row, Spinner } from "@/shared/ui";
import "./push-review.css";

/** 실제 전송될 계정·목적지·커밋·파일을 사용자가 확인한다. */
export function PushReviewSheet({ store, close, branch, force, remoteOverride }: { store: RepoStore; close: () => void; branch: string; force: boolean; remoteOverride?: string }) {
  useObserve(store);
  useEffect(() => {
    void store.loadPushReview(branch, force, remoteOverride);
    return () => store.cancelPushReview();
  }, [store, branch, force, remoteOverride]);
  const plan = store.pushReview;
  const loading = store.pushReviewLoading;
  const pushing = store.busy != null;
  const cancel = () => { store.cancelPushReview(); close(); };
  return <Modal title={t("Review push")} width={720} onClose={() => { if (!pushing) cancel(); }} footer={<>
    <Button disabled={loading} onClick={() => void store.loadPushReview(branch, force, remoteOverride)}>{t("Refresh review")}</Button>
    <span className="grow" />
    <Button disabled={pushing} onClick={cancel}>{t("Cancel")}</Button>
    <Button kind="primary" disabled={!plan || loading || plan.preflight.result === "STOP"} onClick={() => void store.confirmPushReview()}>{t(force ? "Confirm force push" : "Confirm push")}</Button>
  </>}>
    <div className="push-review col">
      {loading && <div className="row"><Spinner /> {t("Checking push destination and preflight…")}</div>}
      {store.pushReviewError && <div className="error-text" role="alert">{store.pushReviewError}</div>}
      {force && <div className="push-review-warning">{t("Force push can replace remote history. The reviewed remote revision is protected by an explicit lease.")}</div>}
      {plan && <>
        <Row label={t("Push account")}><span>{plan.account}</span></Row>
        <Row label={t("Credential account")}><span>{plan.credentialAccount}</span></Row>
        <Row label={t("Commit identity")}><span>{plan.author}</span></Row>
        <p className="hint">{t("The account follows gitch policy. SSH and credential helpers choose the network login.")}</p>
        <Row label={t("Push URL")}><span className="mono break">{plan.displayURL}</span></Row>
        <Row label={t("Destination branch")}><span className="mono break">{plan.remote} / {plan.destination.replace(/^refs\/heads\//, "")}</span></Row>
        <Row label={t("Source revision")}><span className="mono">{plan.branch} · {plan.sourceOID.slice(0, 12)}</span></Row>
        <Row label={t("Remote revision")}><span className="mono">{plan.destinationOID?.slice(0, 12) ?? t("New branch")}</span></Row>
        <div className={`push-review-checks ${plan.preflight.result === "STOP" ? "error-text" : ""}`}>
          <strong>{t("Preflight")} · {plan.preflight.result}</strong>
          {plan.preflight.checks.map((check, i) => <div key={i}>[{check.level}] {check.message}</div>)}
        </div>
        <strong>{t("Outgoing commits ({0})", plan.commitCount)}</strong>
        <div className="push-review-list">{plan.commits.map((c) => <div key={c.sha}><span className="mono hint">{c.sha.slice(0, 8)}</span> {c.subject}<div className="hint">{c.author} &lt;{c.email}&gt;</div></div>)}{!plan.commitCount && <p className="hint">{t("No outgoing commits")}</p>}</div>
        {plan.commitCount > plan.commits.length && <span className="hint">{t("Showing the first {0} items", plan.commits.length)}</span>}
        {plan.comparisonBase && !plan.destinationOID && <Row label={t("File comparison base")}><span className="mono">{plan.comparisonBase.slice(0, 12)}</span></Row>}
        <strong>{t(plan.fileScope === "snapshot" ? "Files in new branch snapshot ({0})" : "Changed files ({0})", plan.fileCount)}</strong>
        <div className="push-review-list mono">{plan.files.map((file) => <div key={file}>{file}</div>)}</div>
        {plan.fileCount > plan.files.length && <span className="hint">{t("Showing the first {0} items", plan.files.length)}</span>}
      </>}
    </div>
  </Modal>;
}
