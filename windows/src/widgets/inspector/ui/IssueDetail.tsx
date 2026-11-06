import { RotateCcw } from "lucide-react";
import { CircleCheck, CircleDot } from "@/shared/icons";
import { Ellipsis, ExternalLink, Pencil } from "@/shared/icons";
import { useEffect, useMemo, useRef, useState } from "react";
import { markdownLinks } from "@/entities/git";
import { quoteIssueComment, type InboxDetail, workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { listDay, listWhen, longDate, useObserve } from "@/shared/lib";
import { Avatar, Button, HostedListIconButton, HostedListTextButton, Markdown, showMenuBelow, Spinner, StatusPill } from "@/shared/ui";
import { IssueDevelopment } from "./IssueDevelopment";
import "./inspector.css";
import "./issue-detail.css";

/**
 * The open issue, as the Issues board draws it: number and state, the title with its actions, who opened it and when;
 * then the description and the activity beside the Development and Details cards, and the comment field at the bottom.
 * Drafts stay while the list reloads. (macOS: IssueDetailView)
 */
export function IssueDetail({ store, detail }: { store: RepoStore; detail: InboxDetail }) {
  useObserve(store);
  const item = detail.item, context = JSON.stringify([store.path, store.target?.provider, store.target?.host, store.target?.path, store.hostingAccount?.id, item.id]);
  const [draft, setDraft] = useState(""), [preview, setPreview] = useState(false), [editing, setEditing] = useState<string | null>(null), [editText, setEditText] = useState(""), [focused, setFocused] = useState(false);
  const composer = useRef<HTMLTextAreaElement>(null);
  useEffect(() => { setDraft(""); setPreview(false); setEditing(null); setEditText(""); }, [context]);
  const md = useMemo(() => markdownLinks(store.target), [store.target]);
  const open = ["open", "opened"].includes(item.state), busy = store.inboxBusy || store.inboxLoading;
  // the comment field is one line until it is used
  const composing = focused || preview || !!draft;
  const send = () => {
    if (!draft.trim() || busy) return;
    const sent = draft, id = item.id;
    void store.inboxAction(item, "comment", sent).then(ok => { if (ok && store.inboxDetail?.item.id === id) { setDraft(current => current === sent ? "" : current); setPreview(false); } });
  };
  const more = t("More issue actions");
  return <div className="col grow issue-detail">
    <header className="issue-head">
      <div className="issue-head-top"><span className="issue-number mono">#{item.number}</span><StatusPill tone={open ? "passed" : "neutral"} icon={open ? <CircleDot/> : <CircleCheck/>}>{workStateTitle(item.state)}</StatusPill>{store.inboxLoading && <Spinner size={12}/>}</div>
      <div className="issue-head-title">
        <h2 className="selectable">{item.title}</h2>
        <div className="issue-head-actions">
          <Button disabled={busy} onClick={() => store.openSheet({ kind: "issueEditor", number: item.number, title: item.title, body: item.body })}><Pencil size={14}/>{t("Edit")}</Button>
          <Button onClick={() => store.openUrl(item.url)}><ExternalLink size={14}/>{t("Open in browser")}</Button>
          <HostedListIconButton label={more} aria-haspopup="menu" onClick={event => showMenuBelow(event.currentTarget, [
            { label: t("Refresh conversation"), onClick: () => void store.openInboxItem(item) },
            { label: t("Copy link"), onClick: () => store.copy(item.url) },
          ])}><Ellipsis size={14}/></HostedListIconButton>
        </div>
      </div>
      {/* the list row owns the updated date; the detail says when the issue was opened */}
      <div className="issue-head-meta"><span className="issue-author"><Avatar name={item.author} email={item.author} size={20}/><strong>@{item.author}</strong></span>{item.created != null && <span title={longDate(item.created)}>{t("Opened {0}", listDay(item.created))}</span>}</div>
    </header>
    <div className="issue-body" key={context} tabIndex={0}>
      <div className="issue-main">
        <div className="issue-description">{item.body.trim() ? <Markdown text={item.body} {...md}/> : <span className="hosted-caption">{t("No description")}</span>}</div>
        {store.inboxError && <p className="error-text selectable" role="alert">{store.inboxError}</p>}
        <h3 className="issue-activity-title">{t("Activity")}</h3>
        <section className="issue-activity" aria-label={t("Activity")}>
          {!detail.comments.length && !store.inboxLoading && <span className="hosted-caption">{t("No comments yet. Start the conversation.")}</span>}
          {detail.comments.map(comment => <article key={comment.id} className="issue-comment">
            <Avatar name={comment.author} email={comment.author} size={24}/>
            <div className="issue-comment-body">
              <span className="issue-comment-head"><strong>@{comment.author}</strong>{comment.date !== null && <span className="hosted-caption" title={longDate(comment.date)}>{listWhen(comment.date)}</span>}{comment.author.toLowerCase() === item.author.toLowerCase() && <StatusPill tone="neutral">{t("Author")}</StatusPill>}</span>
              {editing === comment.id ? <div className="col" style={{ gap: 8 }}><textarea className="textarea" aria-label={t("Edit comment")} rows={5} value={editText} disabled={busy} onChange={event => setEditText(event.target.value)}/><div className="row"><Button kind="primary" disabled={busy || !editText.trim()} onClick={() => void store.changeIssueComment(item, comment, editText).then(ok => { if (ok) setEditing(null); })}>{t("Save comment")}</Button><Button disabled={busy} onClick={() => setEditing(null)}>{t("Cancel")}</Button></div></div> : <Markdown text={comment.body} {...md}/>}
              <span className="issue-comment-actions">
                <HostedListTextButton disabled={busy} onClick={() => { setDraft(value => `${value ? value + "\n\n" : ""}${quoteIssueComment(comment.author, comment.body)}`); setPreview(false); requestAnimationFrame(() => composer.current?.focus()); }}>{t("Quote reply")}</HostedListTextButton>
                {comment.editable && <><HostedListTextButton disabled={busy || !!editing} onClick={() => { setEditing(comment.id); setEditText(comment.body); }}>{t("Edit")}</HostedListTextButton><HostedListTextButton destructive disabled={busy} onClick={() => store.confirmDeleteIssueComment(item, comment)}>{t("Delete")}</HostedListTextButton></>}
              </span>
            </div>
          </article>)}
          {detail.more && <HostedListTextButton disabled={busy} onClick={() => void store.openInboxItem(item, true)}>{t("Load more comments")}</HostedListTextButton>}
        </section>
      </div>
      <div className="issue-side">
        <IssueDevelopment store={store} item={item}/>
        <section className="issue-card" aria-label={t("Details")}>
          <span className="issue-card-title">{t("Details")}</span>
          <div className="issue-facts">
            <span className="hosted-caption">{t("Assignees")}</span>
            {item.assignees?.length ? <span className="issue-assignees">{item.assignees.map(name => <span key={name}><Avatar name={name} email={name} size={20}/><span className="ellipsis">@{name}</span></span>)}</span> : <span className="hosted-caption">{t("None")}</span>}
            <span className="hosted-caption">{t("Labels")}</span>
            {/* a label is neutral; its colour is a dot beside the name, never the only sign */}
            {item.labels?.length ? <span className="issue-labels">{item.labels.map(label => <StatusPill key={label.name} tone="neutral">{label.color && /^#?[0-9a-f]{6}$/i.test(label.color) && <i style={{ background: `#${label.color.replace("#", "")}` }}/>}{label.name}</StatusPill>)}</span> : <span className="hosted-caption">{t("None")}</span>}
          </div>
        </section>
      </div>
    </div>
    <div className={`issue-composer${composing ? " composing" : ""}`} onFocus={() => setFocused(true)} onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setFocused(false); }}>
      {composing && <div className="issue-composer-tabs" role="group" aria-label={t("Comment")}><Button size="small" aria-pressed={!preview} onClick={() => setPreview(false)}>{t("Write")}</Button><Button size="small" aria-pressed={preview} onClick={() => setPreview(true)}>{t("Preview")}</Button><span className="hint">{keyLabel(t("Comment (Ctrl+Enter)"))}</span></div>}
      <div className="issue-composer-row">
        <textarea ref={composer} hidden={preview} aria-label={t("Comment")} placeholder={t("Write a comment…")} value={draft} disabled={store.inboxBusy} onChange={event => setDraft(event.target.value)} onKeyDown={event => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); send(); } }}/>
        {preview && <div className="issue-comment-preview">{draft.trim() ? <Markdown text={draft} {...md}/> : <span className="hint">{t("Nothing to preview")}</span>}</div>}
        {store.inboxBusy && <Spinner size={12}/>}
        <Button disabled={busy} onClick={() => store.confirmIssueState(item)}>{open ? <CircleCheck size={14}/> : <RotateCcw size={14}/>}{open ? t("Close issue…") : t("Reopen…")}</Button>
        {/* a disabled button shows no tip of its own, so the reason sits on its wrapper */}
        <span data-tip={draft.trim() ? undefined : t("A comment needs text")}><Button kind="primary" disabled={!draft.trim() || busy} onClick={send}>{t("Comment")}</Button></span>
      </div>
    </div>
  </div>;
}
