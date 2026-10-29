import { CircleCheck, CircleDot, ExternalLink, MessageSquare, Pencil, Quote, RefreshCw, RotateCcw, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { markdownLinks } from "@/entities/git";
import { quoteIssueComment, type InboxDetail, workStateTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, HostingDate, IconButton, Markdown, Spinner } from "@/shared/ui";
import { IssueDevelopment } from "./IssueDevelopment";
import "./inspector.css";
import "./issue-detail.css";

/** An issue conversation keeps Markdown drafts and development handoffs together. */
export function IssueDetail({ store, detail }: { store: RepoStore; detail: InboxDetail }) {
  useObserve(store);
  const item = detail.item, context = JSON.stringify([store.path, store.target?.provider, store.target?.host, store.target?.path, store.hostingAccount?.id, item.id]);
  const [draft, setDraft] = useState(""), [preview, setPreview] = useState(false), [editing, setEditing] = useState<string | null>(null), [editText, setEditText] = useState("");
  const composer = useRef<HTMLTextAreaElement>(null);
  useEffect(() => { setDraft(""); setPreview(false); setEditing(null); setEditText(""); }, [context]);
  const md = useMemo(() => markdownLinks(store.target), [store.target]);
  const open = ["open", "opened"].includes(item.state), busy = store.inboxBusy || store.inboxLoading;
  const send = () => {
    if (!draft.trim() || busy) return;
    const sent = draft, id = item.id;
    void store.inboxAction(item, "comment", sent).then(ok => { if (ok && store.inboxDetail?.item.id === id) { setDraft(current => current === sent ? "" : current); setPreview(false); } });
  };
  return <div className="col grow issue-detail" style={{ height: "100%" }}>
    <div className="panel-head">{open ? <CircleDot size={15} style={{ color: "var(--green)" }}/> : <CircleCheck size={15} className="muted"/>}<strong>{t("Issue #{0}", item.number)}</strong><span className="spacer"/>{store.inboxLoading && <Spinner size={12}/>}<IconButton small icon={<RefreshCw size={12}/>} tip={t("Refresh conversation")} aria-label={t("Refresh conversation")} onClick={() => void store.openInboxItem(item)}/></div>
    <div className="panel-scroll" key={context} tabIndex={0}>
      <div className="issue-title-block"><span className={`issue-state ${open ? "issue-open" : ""}`}>{workStateTitle(item.state)}</span><h2 className="selectable">{item.title}</h2><div className="issue-author"><Avatar name={item.author} email={item.author} size={24}/><strong>@{item.author}</strong>{item.created != null || item.updated != null ? <HostingDate value={item.created ?? item.updated} label={item.created != null ? "Opened {0}" : "Updated {0}"}/> : <span className="hint">{t("Author")}</span>}</div></div>
      <div className="issue-workflow-actions"><Button disabled={busy} onClick={() => store.openSheet({ kind: "issueEditor", number: item.number, title: item.title, body: item.body })}><Pencil size={13}/>{t("Edit issue")}</Button><Button disabled={busy} onClick={() => store.confirmIssueState(item)}>{open ? <CircleCheck size={13}/> : <RotateCcw size={13}/>} {open ? t("Close issue…") : t("Reopen…")}</Button><Button onClick={() => store.openUrl(item.url)}><ExternalLink size={13}/>{t("Browser")}</Button></div>
      <div className="issue-description">{item.body.trim() ? <Markdown text={item.body} {...md}/> : <span className="muted">{t("No description")}</span>}</div>
      <IssueDevelopment store={store} item={item}/>
      {store.inboxError && <p className="error-text selectable" role="alert">{store.inboxError}</p>}
      <section className="issue-conversation" aria-label={t("Conversation")}><div className="issue-section-heading"><span><MessageSquare size={14}/>{t("Conversation")}</span><span className="issue-count">{detail.comments.length}</span></div>
        {!detail.comments.length && !store.inboxLoading && <p className="hint">{t("No comments yet. Start the conversation.")}</p>}
        {detail.comments.map(comment => <article key={comment.id} className="issue-comment"><div className="issue-comment-header"><Avatar name={comment.author} email={comment.author} size={26}/><strong>@{comment.author}</strong>{comment.date !== null && <HostingDate value={comment.date}/>}</div>
          {editing === comment.id ? <div className="col" style={{ gap: 8 }}><textarea className="textarea" aria-label={t("Edit comment")} rows={5} value={editText} disabled={busy} onChange={event => setEditText(event.target.value)}/><div className="issue-workflow-actions"><Button size="small" kind="primary" disabled={busy || !editText.trim()} onClick={() => void store.changeIssueComment(item, comment, editText).then(ok => { if (ok) setEditing(null); })}>{t("Save comment")}</Button><Button size="small" disabled={busy} onClick={() => setEditing(null)}>{t("Cancel")}</Button></div></div> : <Markdown text={comment.body} {...md}/>}
          <div className="issue-comment-actions"><Button size="small" disabled={busy} onClick={() => { setDraft(value => `${value ? value + "\n\n" : ""}${quoteIssueComment(comment.author, comment.body)}`); setPreview(false); requestAnimationFrame(() => composer.current?.focus()); }}><Quote size={12}/>{t("Quote reply")}</Button>{comment.editable && <><Button size="small" disabled={busy || !!editing} onClick={() => { setEditing(comment.id); setEditText(comment.body); }}><Pencil size={12}/>{t("Edit")}</Button><Button size="small" disabled={busy} onClick={() => store.confirmDeleteIssueComment(item, comment)}><Trash2 size={12}/>{t("Delete")}</Button></>}</div>
        </article>)}
        {detail.more && <Button size="small" disabled={busy} onClick={() => void store.openInboxItem(item, true)}>{t("Load more comments")}</Button>}
      </section>
    </div>
    <div className="issue-composer"><div className="issue-composer-tabs" role="group" aria-label={t("Comment")}><Button size="small" aria-pressed={!preview} onClick={() => setPreview(false)}>{t("Write")}</Button><Button size="small" aria-pressed={preview} onClick={() => setPreview(true)}>{t("Preview")}</Button></div>
      <textarea ref={composer} hidden={preview} className="textarea" rows={4} aria-label={t("Comment")} placeholder={t("Write a comment (Markdown)")} value={draft} disabled={store.inboxBusy} onChange={event => setDraft(event.target.value)} onKeyDown={event => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); send(); } }}/>
      {preview && <div className="issue-comment-preview">{draft.trim() ? <Markdown text={draft} {...md}/> : <span className="hint">{t("Nothing to preview")}</span>}</div>}
      <div className="row">{store.inboxBusy && <Spinner size={12}/>}<span className="hint">{keyLabel(t("Comment (Ctrl+Enter)"))}</span><span className="spacer"/><Button size="small" kind="primary" disabled={!draft.trim() || busy} onClick={send}>{t("Comment")}</Button></div>
    </div>
  </div>;
}
