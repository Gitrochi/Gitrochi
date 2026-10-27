import { useEffect, useRef, useState } from "react";
import { ExternalLink, MessageSquareText, RefreshCw } from "lucide-react";
import { ensureHubCurrent, HostingError, HubUncertainWriteError, hubError, inboxDetail, postInboxComment, type HubAccess, type HubProjectRow, type InboxDetail } from "@/entities/hosting";
import { language, t } from "@/shared/i18n";
import { Button, Markdown, Spinner } from "@/shared/ui";
import { projectKind, type ProjectAsk } from "../lib/project-workspace";
import { projectConversationContext } from "../lib/project-conversation";
import { useProjectEdit } from "../model/use-project-edit";

/** Remote discussions use actual issue comments; local notes never imitate remote comments. */
export function ProjectTaskConversation({ row, localProject, locked, open, safe, readAccess, ask }: {
  row: HubProjectRow;
  localProject: boolean;
  locked: boolean;
  open: (url: string) => void;
  safe: (url: string) => boolean;
  readAccess?: () => Promise<HubAccess>;
  ask: ProjectAsk;
}) {
  const discussion = !localProject && ["issue", "pullRequest"].includes(projectKind(row)),
    timestamp = row.createdAt ?? row.updatedAt,
    date = timestamp && Number.isFinite(Date.parse(timestamp)) ? new Date(timestamp) : null;
  const [detail, setDetail] = useState<InboxDetail | null>(null),
    [loading, setLoading] = useState(false), [error, setError] = useState(""), [body, setBody] = useState(""), [notice, setNotice] = useState("");
  const edit = useProjectEdit(ask), generation = useRef(0), reader = useRef(readAccess);
  reader.current = readAccess;
  const enabled = discussion && !!readAccess;
  const load = async (append = false) => {
    if (!reader.current || !enabled) return;
    const request = ++generation.current;
    setLoading(true); setError("");
    let access: HubAccess | undefined;
    try {
      access = await reader.current();
      const context = projectConversationContext(access, row), result = await inboxDetail(context.access, context.item, append ? (detail?.page ?? 0) + 1 : 1);
      ensureHubCurrent(context.access);
      if (request !== generation.current) return;
      setDetail((previous) => append && previous ? { ...result, comments: [...previous.comments, ...result.comments.filter((comment) => !previous.comments.some((value) => value.id === comment.id))] } : result);
    } catch (failure) {
      if (request === generation.current) setError(hubError(failure, access?.token));
    } finally { if (request === generation.current) setLoading(false); }
  };
  useEffect(() => {
    if (enabled) void load();
    return () => { generation.current++; };
  }, [row.id, row.url, enabled]);
  const post = async () => {
    if (!enabled || locked || edit.busy || !body.trim()) return;
    const text = body.trim(), item = row;
    setNotice("");
    if (await edit.run(t("Comment"), text, async (access) => {
      const context = projectConversationContext(access, item);
      try {
        await postInboxComment(context.access, context.item, text);
        ensureHubCurrent(context.access);
      } catch (failure) {
        if (failure instanceof HostingError && failure.status >= 400 && failure.status < 500 && failure.status !== 408) throw failure;
        throw new HubUncertainWriteError(`${t("The comment may have been posted. Refresh the conversation before trying again.")}\n\n${hubError(failure, access.token)}`);
      }
    })) { setBody(""); setNotice(t("Comment posted")); await load(); }
  };
  const commentHeader = (author: string, time: Date | null, label?: string) => <header>
    {author ? <><span className="project-avatar">{author.slice(0, 1).toUpperCase()}</span><strong>@{author}</strong></> : <strong>{t(discussion ? "Description" : "Notes")}</strong>}
    {time && <time dateTime={time.toISOString()} title={time.toLocaleString(language)}>{label ? t(label, time.toLocaleDateString(language, { month: "short", day: "numeric" })) : time.toLocaleString(language, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}</time>}
  </header>;
  return (
    <section className={`project-task-conversation ${discussion ? "remote" : "local"}`} aria-label={t(discussion ? "Conversation" : "Notes")}>
      <div className="project-conversation-heading"><MessageSquareText size={14} /><strong>{t(discussion ? "Conversation" : "Notes")}</strong>
        {enabled && <Button size="small" tip={t("Refresh comments")} aria-label={t("Refresh comments")} disabled={loading || edit.busy} onClick={() => void load()}><RefreshCw size={12} /></Button>}
      </div>
      <article className="project-conversation-entry">
        {commentHeader(localProject ? "" : row.author ?? "", date, row.createdAt ? "Created {0}" : "Updated {0}")}
        {(detail?.item.body ?? row.body) ? <Markdown text={detail?.item.body ?? row.body} canLoadImage={() => false} className="project-task-markdown" /> : <p className="hint">{t("No description yet.")}</p>}
      </article>
      {detail?.comments.map((comment) => <article className="project-conversation-entry project-comment" key={comment.id}>
        {commentHeader(comment.author, comment.date !== null && Number.isFinite(comment.date) ? new Date(comment.date * 1000) : null)}
        <Markdown text={comment.body} canLoadImage={() => false} className="project-task-markdown" />
      </article>)}
      {error && <p className="error-text" role="alert">{error}<Button size="small" disabled={loading} onClick={() => void load()}>{t("Retry")}</Button></p>}
      {loading && <div className="project-comments-loading"><Spinner /></div>}
      {detail?.more && <Button size="small" disabled={loading || edit.busy} onClick={() => void load(true)}>{t("Load more comments")}</Button>}
      {enabled && <div className="project-comment-editor">
        <textarea className="textarea" rows={3} aria-label={t("Write a comment…")} placeholder={t("Write a comment…")} value={body} disabled={locked || edit.busy}
          onChange={(event) => { setBody(event.target.value); setNotice(""); }} onKeyDown={(event) => { if ((event.metaKey || event.ctrlKey) && event.key === "Enter") { event.preventDefault(); void post(); } }} />
        {notice && <p className="project-comment-notice" role="status">{notice}</p>}
        {edit.error && <p className="error-text" role="alert">{edit.error}</p>}
        <Button size="small" kind="primary" disabled={locked || edit.busy || !body.trim()} onClick={() => void post()}>{edit.busy ? <Spinner /> : <MessageSquareText size={12} />}{t("Comment")}</Button>
      </div>}
      {discussion && safe(row.url) && <Button size="small" onClick={() => open(row.url)}><ExternalLink size={12} />{t("Open conversation")}</Button>}
    </section>
  );
}
