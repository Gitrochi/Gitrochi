import { ArrowDownToLine, CheckCheck, ExternalLink, FileDiff, GitBranch, GitPullRequest, MessageSquare, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { CIStatusIcon, statusInfo } from "@/entities/ci";
import { markdownLinks, providerInfo, StatusBadge } from "@/entities/git";
import { workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { longDate, useObserve } from "@/shared/lib";
import { Avatar, Button, Empty, IconButton, LineStatText, Markdown, Spinner } from "@/shared/ui";
import { RequestActivity } from "./RequestActivity";
import { RequestChecksPanel } from "./RequestChecksPanel";
import { RequestLifecyclePanel } from "./RequestLifecyclePanel";
import { ReviewDraftPanel } from "./ReviewPanels";

/** Request summary, activity and review tabs. macOS: PullRequestDetailView.swift. */
export function PullRequestDetailView({ store, number }: { store: RepoStore; number: number }) {
  useObserve(store);
  useObserve(store.ci);
  const [draft, setDraft] = useState("");
  const [tab, setTab] = useState("conversation");
  useEffect(() => { setDraft(""); setTab("conversation"); void store.loadReview(number); }, [store, number]);
  const pr = store.pullRequests.find((p) => p.number === number);
  const target = store.target;
  const md = useMemo(() => markdownLinks(target, pr?.headSHA ?? pr?.source ?? "HEAD"), [target, pr?.headSHA, pr?.source]);
  if (!pr || !target) return <Empty icon={<GitPullRequest size={30} />} title={t("{0} not in the list", target ? providerInfo[target.provider].requestShort : "PR")} detail={t("It was closed or hasn't been loaded yet.")} />;
  const r = store.review?.number === number ? store.review : null;
  const s = r?.state;
  const lifecycle = store.requestLifecycle?.number === number ? store.requestLifecycle : null;
  const run = pr.headSHA ? store.ci.bySha.get(pr.headSHA) : undefined;
  const text = draft.trim(), pending = store.reviewDraftsFor(number).length;
  const after = (ok: boolean) => {
    if (ok && store.selection?.kind === "pullRequest" && store.selection.number === number)
      setDraft((current) => current.trim() === text ? "" : current);
  };
  const tabs = [
    { id: "conversation", title: t("Conversation"), icon: <MessageSquare size={14}/>, count: r?.comments.filter(c => c.kind !== "system").length },
    { id: "files", title: t("Changed files"), icon: <FileDiff size={14}/>, count: r?.files.length },
    { id: "checks", title: t("Checks"), icon: <CheckCheck size={14}/> },
  ];
  return <div className="request-detail col grow">
    <div className="panel-head request-head">
      <GitPullRequest size={16}/><strong>{providerInfo[target.provider].requestShort} #{pr.number}</strong>
      {lifecycle && <span className={`request-state state-${lifecycle.state}`}>{workStateTitle(lifecycle.state)}</span>}
      {pr.isDraft && <span className="request-state">{t("Draft")}</span>}
      <span className="spacer"/>{store.reviewLoading && <Spinner size={12}/>}
      <IconButton small icon={<RefreshCw size={13}/>} tip={t("Refresh conversation and approvals")} aria-label={t("Refresh conversation and approvals")} onClick={() => { void store.loadReview(number); void store.loadRequestLifecycle(number); }}/>
    </div>
    <div className="request-tabs" role="tablist" aria-label={t("Review")}>
      {tabs.map(item => <button key={item.id} id={`request-tab-${item.id}`} role="tab" aria-selected={tab === item.id} aria-controls={`request-panel-${item.id}`} tabIndex={tab === item.id ? 0 : -1} onClick={() => setTab(item.id)} onKeyDown={event => {
        const index = tabs.findIndex(value => value.id === item.id);
        const next = event.key === "ArrowRight" ? (index + 1) % tabs.length : event.key === "ArrowLeft" ? (index + tabs.length - 1) % tabs.length : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null;
        if (next !== null) { event.preventDefault(); setTab(tabs[next].id); event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>("button")[next].focus(); }
      }}>{item.icon}{item.title}{item.count != null && <span className="request-count">{item.count}</span>}</button>)}
    </div>
    <div className="panel-scroll request-detail-scroll" key={number}>
      <header className="request-summary">
        <h1 className="selectable">{pr.title}</h1>
        <div className="request-meta"><span aria-hidden="true"><Avatar name={pr.author} email={pr.author} size={24}/></span><strong>@{pr.author}</strong>{pr.updated && <span>{t("Update")} {longDate(pr.updated)}</span>}</div>
        <div className="request-branches selectable"><GitBranch size={13}/><code>{pr.source}</code><span>→</span><code>{pr.target}</code>{pr.fromFork && <span className="muted">{t("fork")}</span>}</div>
        <div className="request-actions"><Button kind="primary" onClick={() => void store.checkoutPullRequest(pr)}><ArrowDownToLine size={14}/>{t("Check out branch")}</Button><Button onClick={() => store.openUrl(pr.url)}><ExternalLink size={14}/>{t("Browser")}</Button>{pr.headSHA && store.commitIndex.has(pr.headSHA) && <Button onClick={() => store.reveal(pr.headSHA!)}>{t("Show in graph")}</Button>}</div>
        {run && <button className="request-ci-summary" onClick={() => setTab("checks")}><CIStatusIcon status={run.status} size={14}/><span>{t("Checks")}</span><strong>{statusInfo[run.status].title}</strong><span className="muted">#{run.number}</span></button>}
      </header>
      {store.reviewError && <p className="error-text selectable" role="alert">{store.reviewError}</p>}
      {/* Keep panels mounted so tab switches preserve metadata edits and check/log state. */}
      <section id="request-panel-conversation" role="tabpanel" aria-labelledby="request-tab-conversation" hidden={tab !== "conversation"} className="request-tab-content">
        <section className="request-description"><strong className="request-section-label">{t("Description")}</strong>{pr.body.trim() ? <Markdown text={pr.body} {...md}/> : <span className="muted">{t("No description")}</span>}</section>
        {s && <section className="request-review-summary"><strong>{t("Review")}</strong>
          {!s.approvedBy.length && !s.changesRequestedBy.length && <span className="muted">{t("No one has approved yet.")}</span>}
          {s.approvedBy.length > 0 && <span className="request-approved">{t("✓ Approved: {0}", s.approvedBy.map(x => "@" + x).join(", "))}</span>}
          {s.changesRequestedBy.length > 0 && <span className="request-changes">{t("Changes requested: {0}", s.changesRequestedBy.map(x => "@" + x).join(", "))}</span>}
          {s.approvalsLeft != null && s.approvalsLeft > 0 && <span className="muted">{t("{0} more approvals needed.", s.approvalsLeft)}</span>}
        </section>}
        {r && <>{pending > 0 && <ReviewDraftPanel store={store} number={number}/>}<RequestActivity store={store} review={r} {...md}/></>}
        <RequestLifecyclePanel store={store} number={number}/>
      </section>
      <section id="request-panel-files" role="tabpanel" aria-labelledby="request-tab-files" hidden={tab !== "files"} className="request-tab-content">
        {r ? <><strong>{t("Changed files {0}", r.files.length)}</strong>{!r.files.length && <p className="muted">{t("No changed files")}</p>}{r.files.map(f => {
          const selected = store.diffSource?.kind === "review" && store.diffSource.number === number && store.diffSource.change.path === f.path;
          return <button key={f.path} className={`side-row review-file ${selected ? "selected" : ""}`} data-tip={f.patch ? t("Click to see the diff in the center") : t("Binary or too large — view it in the browser")} onClick={() => store.openReviewFile(number, f)}><StatusBadge kind={f.kind}/><span className="request-file-path">{f.path}</span><LineStatText added={f.additions} deleted={f.deletions}/></button>;
        })}<ReviewDraftPanel store={store} number={number}/></> : store.reviewLoading && <Spinner size={14}/>}
      </section>
      <section id="request-panel-checks" role="tabpanel" aria-labelledby="request-tab-checks" hidden={tab !== "checks"} className="request-tab-content"><RequestChecksPanel store={store} number={number} sha={pr.headSHA} url={pr.url}/></section>
    </div>
      <div className="composer request-composer">
        <textarea
          className="textarea"
          style={{ height: 58 }}
          aria-label={t("Comment · review feedback")}
          placeholder={t("Comment · review feedback")}
          value={draft}
          disabled={store.reviewBusy || store.reviewLoading}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && (text || pending) && !store.reviewBusy) {
              e.preventDefault();
              void store.postReviewComment(number, text).then(after);
            }
          }}
        />
        <div className="row request-composer-actions">
          {store.reviewBusy && <Spinner size={12} />}
          <span className="spacer" />
          {target.provider === "github" && (
            <Button size="small" disabled={(!text && !pending) || store.reviewBusy} tip={t("Request changes with a comment (comment required)")} onClick={() => void store.requestChanges(number, text).then(after)}>
              {t("Request changes")}</Button>
          )}
          {target.provider === "gitlab" && s?.approvedByMe ? (
            <Button size="small" disabled={store.reviewBusy} onClick={() => void store.unapprovePullRequest(number)}>
              {t("Revoke approval")}</Button>
          ) : (
            <Button size="small" disabled={store.reviewBusy || !!s?.approvedByMe} tip={text ? t("Approve with a comment") : t("Approves this request")} onClick={() => void store.approvePullRequest(number, text).then(after)}>
              {t("✓ Approve")}</Button>
          )}
          <Button size="small" kind="primary" disabled={(!text && !pending) || store.reviewBusy} tip={keyLabel(t("Comment (Ctrl+Enter)"))} onClick={() => void store.postReviewComment(number, text).then(after)}>
            {pending ? t("Submit review") : t("Comment")}</Button>
        </div>
      </div>
  </div>;
}
