import { GitGraph, GitPullRequestClosed, GitPullRequestDraft, MessageSquareText } from "lucide-react";
import { ArrowDownToLine, GitMerge } from "@/shared/icons";
import { Ellipsis, ExternalLink, GitPullRequest } from "@/shared/icons";
import { type ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { markdownLinks, providerInfo } from "@/entities/git";
import { workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, Empty, Markdown, type MenuItem, showMenuBelow, Spinner, StatusPill } from "@/shared/ui";
import { branchLabel, type checksBadge, headerInOneRow, isCompact, isThisBranch } from "../lib/pull-request-page";
import { PullRequestFilesView } from "./PullRequestFilesView";
import { PullRequestReviewDialog } from "./PullRequestReviewDialog";
import { RequestActivity } from "./RequestActivity";
import { RequestChecksPanel } from "./RequestChecksPanel";
import { ownAvatarURL } from "../lib/own-avatar";
import { RequestLifecyclePanel } from "./RequestLifecyclePanel";
import { ReviewDraftPanel } from "./ReviewPanels";
import "./pull-request-detail.css";

type Tab = "conversation" | "files" | "checks";

/** What the Pull requests page adds to the detail: its list's state, and the diff view it can draw beside the file tree */
export interface PullRequestPageContext { listShown: boolean; diff: (split: boolean) => ReactNode }

/**
 * A request: its header, the Conversation, Changed files and Checks tabs and the comment composer. On the Pull
 * requests page (`page`) Changed files gets a one-row header and the diff beside the tree; in the repository
 * inspector the same view stays in one narrow column. macOS: PullRequestDetailView.swift.
 */
export function PullRequestDetailView({ store, number, page }: { store: RepoStore; number: number; page?: PullRequestPageContext }) {
  useObserve(store);
  useObserve(store.ci);
  // a file opened from the inspector lands on the page, which then starts on that file
  const startTab = (): Tab => (page && store.diffSource?.kind === "review" && store.diffSource.number === number ? "files" : "conversation");
  const [draft, setDraft] = useState("");
  const [tab, setTab] = useState<Tab>(startTab);
  const [editing, setEditing] = useState(false), [reviewing, setReviewing] = useState(false), [focused, setFocused] = useState(false);
  const [badge, setBadge] = useState<ReturnType<typeof checksBadge>>(null);
  const [width, setWidth] = useState(0);
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => { setDraft(""); setTab(startTab()); setReviewing(false); setBadge(null); void store.loadReview(number); }, [store, number]);
  const pr = store.pullRequests.find((p) => p.number === number);
  const target = store.target;
  useLayoutEffect(() => {
    const element = root.current;
    if (!element) return;
    const observer = new ResizeObserver(() => setWidth(element.clientWidth));
    observer.observe(element); setWidth(element.clientWidth);
    return () => observer.disconnect();
  }, [!!pr && !!target]);
  const md = useMemo(() => markdownLinks(target, pr?.headSHA ?? pr?.source ?? "HEAD"), [target, pr?.headSHA, pr?.source]);
  if (!pr || !target) return <Empty icon={<GitPullRequest size={30} />} title={t("{0} not in the list", target ? providerInfo[target.provider].requestShort : "PR")} detail={t("It was closed or hasn't been loaded yet.")} />;
  const gitlab = target.provider === "gitlab";
  const r = store.review?.number === number ? store.review : null;
  const lifecycle = store.requestLifecycle?.number === number ? store.requestLifecycle : null;
  const text = draft.trim(), pending = store.reviewDraftsFor(number).length;
  const sent = (value: string) => { if (store.selection?.kind === "pullRequest" && store.selection.number === number) setDraft((current) => (current.trim() === value ? "" : current)); };
  const send = () => { if ((text || pending) && !store.reviewBusy) void store.postReviewComment(number, text).then((ok) => { if (ok) sent(text); }); };
  const compact = isCompact(page?.listShown ?? true, width);
  // Changed files on the page keeps one 44px row; everywhere else the title is the protagonist
  const oneRow = headerInOneRow(!!page, tab, width);
  const thisBranch = isThisBranch(pr, store.headBranch), inGraph = !!pr.headSHA && store.commitIndex.has(pr.headSHA);
  const scope = store.requestQuery.scope;
  const state = lifecycle?.state ?? (scope === "closed" || scope === "merged" ? scope : "open");
  const refresh = () => { void store.loadReview(number); void store.loadRequestLifecycle(number); };
  const openFile = (path: string) => { const file = r?.files.find((item) => item.path === path); if (file) { store.openReviewFile(number, file); setTab("files"); } };
  const more: MenuItem[] = [
    ...(inGraph ? [{ label: t("Show in graph"), onClick: () => store.reveal(pr.headSHA!) }] : []),
    { label: t("Open in browser"), onClick: () => store.openUrl(pr.url) },
    "divider",
    { label: t("Copy link"), onClick: () => store.copy(pr.url) },
    // the reason sits where a shortcut would, as the design's menus draw it
    { label: t("Check out branch"), disabled: thisBranch, shortcut: thisBranch ? t("Already checked out") : undefined, onClick: () => void store.checkoutPullRequest(pr) },
    ...(lifecycle?.canEdit ? [{ label: t("Edit request…"), onClick: () => { setTab("conversation"); setEditing(!editing); } }] : []),
    ...(lifecycle?.canRebase ? [{ label: t("Rebase on server…"), onClick: () => store.confirmRequestRebase() }] : []),
    { label: t("Refresh conversation and approvals"), onClick: refresh },
    "divider",
    ...(lifecycle && lifecycle.state !== "merged" && lifecycle.canEdit ? [{ label: lifecycle.state === "open" ? t(gitlab ? "Close merge request…" : "Close pull request…") : t("Reopen…"), danger: lifecycle.state === "open", onClick: () => store.confirmRequestState(lifecycle.state !== "open") }] : []),
  ];
  const tabs: { id: Tab; title: string; badge?: ReactNode }[] = [
    { id: "conversation", title: t("Conversation") },
    { id: "files", title: t("Changed files"), badge: r && <StatusPill tone="neutral">{r.files.length}</StatusPill> },
    { id: "checks", title: t("Checks"), badge: badge && <StatusPill tone={badge.kind === "failed" ? "failed" : "waiting"} data-tip={t(badge.kind === "failed" ? "{0} failed" : "{0} running", badge.count)}>{badge.kind === "failed" ? "✗ " : ""}{badge.count}</StatusPill> },
  ];
  const added = r?.files.reduce((sum, file) => sum + file.additions, 0) ?? 0, deleted = r?.files.reduce((sum, file) => sum + file.deletions, 0) ?? 0;
  const moreLabel = t(gitlab ? "More merge request actions" : "More pull request actions");
  // on the compact Changed files row these two give their place to the title and sit at the top of the More menu
  const inline = !(oneRow && compact);
  return <div className="pr-detail" ref={root} data-row={oneRow} data-page={!!page}>
    <header className="pr-head" data-row={oneRow}>
      <div className="pr-head-id">
        <span className="mono">#{pr.number}</span>
        {state === "merged" ? <StatusPill tone="neutral" icon={<GitMerge />}>{workStateTitle("merged")}</StatusPill>
          : state === "closed" ? <StatusPill tone="neutral" icon={<GitPullRequestClosed />}>{workStateTitle("closed")}</StatusPill>
          : pr.isDraft ? <StatusPill tone="waiting" icon={<GitPullRequestDraft />}>{t("Draft")}</StatusPill>
          : <StatusPill tone="passed" icon={<GitPullRequest />}>{workStateTitle("open")}</StatusPill>}
        {store.reviewLoading && <Spinner size={12} />}
      </div>
      <h2 className="pr-head-title selectable" title={pr.title}>{pr.title}</h2>
      <div className="pr-head-actions">
        {inline && (!thisBranch ? <Button onClick={() => void store.checkoutPullRequest(pr)}><ArrowDownToLine size={14} />{t("Check out")}</Button>
          : inGraph && <Button onClick={() => store.reveal(pr.headSHA!)}><GitGraph size={14} />{t("Show in graph")}</Button>)}
        <Button aria-haspopup="dialog" onClick={() => setReviewing(true)}><MessageSquareText size={14} />{t("Review…")}</Button>
        {inline && <Button onClick={() => store.openUrl(pr.url)}><ExternalLink size={14} />{t("Open in browser")}</Button>}
        <Button className="pr-button-icon" aria-label={moreLabel} aria-haspopup="menu" tip={moreLabel} onClick={(event) => showMenuBelow(event.currentTarget, more)}><Ellipsis size={14} /></Button>
      </div>
      <div className="pr-head-meta">
        <span className="pr-author"><span aria-hidden="true"><Avatar name={pr.author} email={pr.author} size={20} url={ownAvatarURL(store, pr.author)} /></span><strong>@{pr.author}</strong></span>
        <span className="pr-chip selectable">{thisBranch && <span className="pr-dot" aria-hidden="true" />}{branchLabel(pr, store.headBranch)}</span>
        {added + deleted > 0 && <span className="pr-stat mono"><span className="a">+{added}</span> <span className="d">−{deleted}</span></span>}
      </div>
      <div className="pr-tabs request-tabs" role="tablist" aria-label={t(gitlab ? "Merge requests" : "Pull requests")}>
        {tabs.map((item, index) => <button key={item.id} type="button" id={`request-tab-${item.id}`} role="tab" aria-selected={tab === item.id} aria-controls={`request-panel-${item.id}`} tabIndex={tab === item.id ? 0 : -1} onClick={() => setTab(item.id)} onKeyDown={(event) => {
          const next = event.key === "ArrowRight" ? (index + 1) % tabs.length : event.key === "ArrowLeft" ? (index + tabs.length - 1) % tabs.length : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null;
          if (next !== null) { event.preventDefault(); setTab(tabs[next].id); event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>("button")[next].focus(); }
        }}>{item.title}{item.badge}</button>)}
      </div>
    </header>
    {store.reviewError && <p className="error-text selectable pr-error" role="alert">{store.reviewError}</p>}
    {/* The panels stay mounted so a tab switch keeps the unsent comment, the request's edited fields and the loaded checks. */}
    <section id="request-panel-conversation" role="tabpanel" aria-labelledby="request-tab-conversation" hidden={tab !== "conversation"} className="pr-panel pr-conversation">
      <div className="pr-conversation-scroll" key={number}>
        <div className="pr-thread-column">
          <div className="request-description selectable">{pr.body.trim() ? <Markdown text={pr.body} {...md} /> : <span className="pr-cap">{t("No description")}</span>}</div>
          <h3 className="pr-activity-title">{t("Activity")}</h3>
          {r && pending > 0 && <ReviewDraftPanel store={store} number={number} />}
          {r ? <RequestActivity store={store} review={r} author={pr.author} onOpenFile={openFile} {...md} /> : store.reviewLoading && <Spinner size={14} />}
        </div>
        <aside className="pr-side"><RequestLifecyclePanel badge={badge} store={store} number={number} pr={pr} review={r} editing={editing} onEditing={setEditing} /></aside>
      </div>
      <div className={`pr-composer ${focused || draft ? "expanded" : ""}`}>
        <textarea className="pr-composer-field" rows={1} aria-label={t("Comment")} placeholder={t("Write a comment…")} value={draft} disabled={store.reviewBusy || store.reviewLoading}
          onFocus={() => setFocused(true)} onBlur={() => setFocused(false)} onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); send(); } }} />
        {store.reviewBusy && <Spinner size={12} />}
        {/* a disabled button shows no tip of its own, so the reason sits on its wrapper */}
        <span className="pr-composer-send" data-tip={text || pending ? keyLabel(t("Comment (Ctrl+Enter)")) : t("A comment needs text")}>
          <Button disabled={(!text && !pending) || store.reviewBusy} onClick={send}>{pending ? t("Submit review") : t("Comment")}</Button>
        </span>
      </div>
    </section>
    <section id="request-panel-files" role="tabpanel" aria-labelledby="request-tab-files" hidden={tab !== "files"} className="pr-panel">
      <PullRequestFilesView store={store} number={number} review={r} compact={compact} active={tab === "files"} diff={page?.diff} />
    </section>
    <section id="request-panel-checks" role="tabpanel" aria-labelledby="request-tab-checks" hidden={tab !== "checks"} className="pr-panel pr-checks-scroll">
      <RequestChecksPanel store={store} number={number} sha={pr.headSHA} url={pr.url} draft={pr.isDraft} active={tab === "checks"} onBadge={setBadge} />
    </section>
    {/* outside this view's query container, which would otherwise hold the dialog's backdrop inside the pane */}
    {reviewing && createPortal(<PullRequestReviewDialog store={store} number={number} draft={draft} onDraft={setDraft} onSent={sent} onClose={() => setReviewing(false)} />, document.body)}
  </div>;
}
